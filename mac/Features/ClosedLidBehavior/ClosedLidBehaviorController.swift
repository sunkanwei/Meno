import AppKit
import OSLog

@MainActor
final class ClosedLidBehaviorController {
    private static let reconcileDelay: TimeInterval = 0.75
    private static let systemSleepDelay: TimeInterval = 0.1

    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "ClosedLidBehavior"
    )
    private let onStatusChanged: (ClosedLidBehaviorStatus) -> Void
    private let shutdownHelperIsReady: () -> Bool
    private let idleSleepAssertion = IdleSleepAssertion()
    private let displaySleepRequester = DisplaySleepRequester()
    private let systemSleepRequester = SystemSleepRequester()
    private var mode = ClosedLidMode.followSystem
    private var pendingReconcile = PendingClosedLidReconcile()
    private var reconcileWorkItem: DispatchWorkItem?
    private var requestGeneration: UInt64 = 0
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private lazy var lidStateMonitor = LidStateMonitor { [weak self] in
        Task { @MainActor [weak self] in
            self?.scheduleReconcileForCurrentMode(reason: .lidStateChanged)
        }
    }

    init(
        shutdownHelperIsReady: @escaping () -> Bool,
        onStatusChanged: @escaping (ClosedLidBehaviorStatus) -> Void
    ) {
        self.shutdownHelperIsReady = shutdownHelperIsReady
        self.onStatusChanged = onStatusChanged
    }

    func setMode(_ mode: ClosedLidMode) {
        if self.mode == mode {
            if mode == .shutdown || (mode != .followSystem && !lidStateMonitor.isRunning) {
                start()
            }
            return
        }

        self.mode = mode
        if mode == .followSystem {
            stop(status: .followingSystem)
        } else {
            start()
        }
    }

    func stopForApplicationExit() {
        mode = .followSystem
        stop(status: .followingSystem)
    }

    private func start() {
        stopRuntime()

        guard ClosedLidShutdownContract.isSupportedOperatingSystem else {
            onStatusChanged(.failed("当前 macOS 版本尚未完成兼容性验证，功能已停用。"))
            return
        }
        if mode == .shutdown {
            guard shutdownHelperIsReady() else {
                onStatusChanged(.failed("系统关机助手尚未安装，合盖自动关机暂未生效。"))
                return
            }
            onStatusChanged(.monitoring(.shutdown))
            return
        }
        guard lidStateMonitor.start() else {
            onStatusChanged(.failed("无法读取 MacBook 的开合状态，功能已停用。"))
            return
        }

        observeSystemChanges()
        reconcile(
            ClosedLidReconcileRequest(
                reason: .initialization,
                requestsDisplaySleep: mode == .keepRunning,
                requestsSystemSleep: mode == .sleep
            )
        )
    }

    private func stop(status: ClosedLidBehaviorStatus) {
        stopRuntime()
        onStatusChanged(status)
    }

    private func stopRuntime() {
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
        pendingReconcile.reset()
        requestGeneration &+= 1
        idleSleepAssertion.release()
        lidStateMonitor.stop()

        let applicationCenter = NotificationCenter.default
        applicationObservers.forEach(applicationCenter.removeObserver)
        applicationObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func scheduleReconcile(
        reason: ClosedLidReconcileReason,
        requestDisplaySleep: Bool,
        requestSystemSleep: Bool,
        delay: TimeInterval
    ) {
        guard mode != .followSystem, lidStateMonitor.isRunning else { return }
        pendingReconcile.merge(
            reason: reason,
            requestDisplaySleep: requestDisplaySleep,
            requestSystemSleep: requestSystemSleep
        )
        reconcileWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  let request = self.pendingReconcile.consume() else {
                return
            }
            self.reconcileWorkItem = nil
            self.reconcile(request)
        }
        reconcileWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func scheduleReconcileForCurrentMode(reason: ClosedLidReconcileReason) {
        scheduleReconcile(
            reason: reason,
            requestDisplaySleep: mode == .keepRunning,
            requestSystemSleep: mode == .sleep,
            delay: mode == .sleep ? Self.systemSleepDelay : Self.reconcileDelay
        )
    }

    private func reconcile(_ request: ClosedLidReconcileRequest) {
        requestGeneration &+= 1
        let generation = requestGeneration
        let action = ClosedLidBehaviorPolicy.action(
            for: lidStateMonitor.currentState(),
            mode: mode,
            requestDisplaySleep: request.requestsDisplaySleep,
            requestSystemSleep: request.requestsSystemSleep
        )

        switch action {
        case .followSystem:
            stop(status: .followingSystem)

        case let .monitor(mode):
            idleSleepAssertion.release()
            onStatusChanged(.monitoring(mode))
            logger.info("Closed-lid mode inactive: \(request.reason.rawValue, privacy: .public)")

        case let .keepRunning(requestDisplaySleep):
            guard idleSleepAssertion.acquire() else {
                failSafe("无法让电脑在合盖后继续运行，已恢复系统默认行为。")
                return
            }
            onStatusChanged(.keepingRunning)
            if requestDisplaySleep {
                requestDisplaySleepNow(generation: generation)
            }
            logger.info("Closed-lid mode active: \(request.reason.rawValue, privacy: .public)")

        case let .sleep(requestSystemSleep):
            idleSleepAssertion.release()
            onStatusChanged(.sleepRequested)
            if requestSystemSleep {
                requestSystemSleepNow(generation: generation)
            }
            logger.info("Closed-lid system sleep active: \(request.reason.rawValue, privacy: .public)")

        case .failSafe:
            failSafe("无法确认 MacBook 的开合状态，已恢复系统默认行为。")
        }
    }

    private func requestDisplaySleepNow(generation: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await displaySleepRequester.request()
            guard mode == .keepRunning, generation == requestGeneration else { return }
            guard succeeded else {
                failSafe("系统未能关闭显示器，功能已停用并恢复系统默认行为。")
                return
            }
            logger.info("Display sleep requested")
        }
    }

    private func requestSystemSleepNow(generation: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await systemSleepRequester.request()
            guard mode == .sleep, generation == requestGeneration else { return }
            guard succeeded else {
                failSafe("系统未能进入睡眠，已恢复系统默认行为。")
                return
            }
            logger.info("System sleep requested")
        }
    }

    private func failSafe(_ message: String) {
        stopRuntime()
        onStatusChanged(.failed(message))
        logger.error("\(message, privacy: .public)")
    }
}

private extension ClosedLidBehaviorController {
    private func observeSystemChanges() {
        let applicationCenter = NotificationCenter.default
        applicationObservers.append(
            applicationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleReconcile(
                        reason: .displayConfigurationChanged,
                        requestDisplaySleep: self?.mode == .keepRunning,
                        requestSystemSleep: self?.mode == .sleep,
                        delay: self?.mode == .sleep
                            ? Self.systemSleepDelay
                            : Self.reconcileDelay
                    )
                }
            }
        )

        observeWorkspaceEvent(
            NSWorkspace.screensDidWakeNotification,
            reason: .displaysWoke
        )
        observeWorkspaceEvent(
            NSWorkspace.didWakeNotification,
            reason: .systemWoke
        )
        workspaceObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.reconcileWorkItem?.cancel()
                    self.reconcileWorkItem = nil
                    self.pendingReconcile.reset()
                    self.reconcile(
                        ClosedLidReconcileRequest(
                            reason: .systemWillSleep,
                            requestsDisplaySleep: false,
                            requestsSystemSleep: false
                        )
                    )
                }
            }
        )
    }

    private func observeWorkspaceEvent(
        _ name: NSNotification.Name,
        reason: ClosedLidReconcileReason
    ) {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleReconcileForCurrentMode(reason: reason)
            }
        }
        workspaceObservers.append(observer)
    }
}
