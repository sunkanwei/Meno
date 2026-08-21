import AppKit
import Foundation
import OSLog

@MainActor
final class SoftKVMCoordinator {
    typealias StatusHandler = (SoftKVMStatus) -> Void
    typealias MouseServiceHandler = (Bool) -> Void
    typealias EnabledStateHandler = (Bool) -> Void

    private enum Event {
        case start(enabled: Bool, shortcut: SoftKVMShortcut)
        case setEnabled(Bool)
        case setShortcut(SoftKVMShortcut)
        case readinessChanged(WindowsMouseReadiness?)
        case mouseAvailabilityChanged(SoftKVMMouseAvailability)
        case toggleRequested
        case forceShutdownRequested(onFailure: (String) -> Void)
        case stopRequested
        case systemSuspended(systemSleeping: Bool, sessionInactive: Bool)
        case systemResumed(systemWoke: Bool, sessionBecameActive: Bool)
        case screenParametersChanged
        case delayedRefresh(generation: UInt64)
    }

    static let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "SoftKVM")

    let displaySwitch: FullSwitchController
    let crossScreenMouse: CrossScreenMouseController
    let setMouseServiceEnabled: MouseServiceHandler
    private let onStatusChanged: StatusHandler
    let onEnabledStateChanged: EnabledStateHandler
    private let eventQueue = RunToCompletionEventQueue<Event>()
    var stateMachine = SoftKVMStateMachine()
    var readiness: WindowsMouseReadiness?
    var shortcut = SoftKVMShortcut.defaultValue
    var operationTask: Task<Void, Never>?
    var nextOperationID: UInt64 = 0
    private var delayedRefreshTask: Task<Void, Never>?
    private var delayedRefreshGeneration: UInt64 = 0
    var remoteShutdownInProgress = false
    private var observers: [NSObjectProtocol] = []
    var preparedState = false

    var status: SoftKVMStatus {
        stateMachine.status
    }

    init(
        displaySwitch: FullSwitchController,
        crossScreenMouse: CrossScreenMouseController,
        setMouseServiceEnabled: @escaping MouseServiceHandler,
        onStatusChanged: @escaping StatusHandler,
        onEnabledStateChanged: @escaping EnabledStateHandler
    ) {
        self.displaySwitch = displaySwitch
        self.crossScreenMouse = crossScreenMouse
        self.setMouseServiceEnabled = setMouseServiceEnabled
        self.onStatusChanged = onStatusChanged
        self.onEnabledStateChanged = onEnabledStateChanged
        observeSystemState()
    }

    func start(enabled: Bool, shortcut: SoftKVMShortcut) {
        send(.start(enabled: enabled, shortcut: shortcut))
    }

    func setEnabled(_ enabled: Bool) {
        send(.setEnabled(enabled))
    }

    func setShortcut(_ shortcut: SoftKVMShortcut) {
        send(.setShortcut(shortcut))
    }

    func updateReadiness(_ readiness: WindowsMouseReadiness?) {
        send(.readinessChanged(readiness))
    }

    func updateMouseStatus(_ mouseStatus: CrossScreenMouseStatus) {
        send(.mouseAvailabilityChanged(mouseStatus.softKVMAvailability))
    }

    func toggle() {
        send(.toggleRequested)
    }

    var canForceShutdownWindows: Bool {
        stateMachine.enabled
            && !stateMachine.operationInProgress
            && crossScreenMouse.remoteShutdownAvailable
    }

    var remoteShutdownActionTitle: String {
        remoteShutdownInProgress ? "正在关闭 Windows…" : "远程关闭 Windows"
    }

    func forceShutdownWindows(onFailure: @escaping (String) -> Void) {
        send(.forceShutdownRequested(onFailure: onFailure))
    }

    func stopForApplicationExit() {
        send(.stopRequested)
    }

    private func send(_ event: Event) {
        eventQueue.send(event) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case let .start(enabled, shortcut):
            self.shortcut = shortcut
            updateState { $0.start(enabled: enabled) }
            crossScreenMouse.setSoftKVMShortcut(shortcut)
            onEnabledStateChanged(enabled)
            setMouseServiceEnabled(enabled)
            if enabled {
                refresh(allowAutomaticRecovery: true)
            } else {
                applyRouteEnabled(false)
            }

        case let .setEnabled(enabled):
            guard enabled != stateMachine.enabled else { return }
            if enabled {
                guard updateState({ $0.enable() }) else { return }
                onEnabledStateChanged(true)
                setMouseServiceEnabled(true)
                refresh(allowAutomaticRecovery: true)
            } else {
                beginDisable()
            }

        case let .setShortcut(shortcut):
            guard shortcut.isValid else { return }
            self.shortcut = shortcut
            crossScreenMouse.setSoftKVMShortcut(shortcut)

        case let .readinessChanged(readiness):
            guard readiness != self.readiness else { return }
            self.readiness = readiness
            let actions = updateState {
                $0.updateReadiness(isAvailable: readiness != nil)
            }
            execute(actions)

        case let .mouseAvailabilityChanged(availability):
            let actions = updateState {
                $0.updateMouseAvailability(availability)
            }
            execute(actions)

        case .toggleRequested:
            guard stateMachine.enabled,
                  stateMachine.routeMayBeEnabled,
                  !stateMachine.operationInProgress else { return }
            switch status {
            case .macReady:
                switchToWindows()
            case .windowsReady, .windowsWaiting:
                switchToMac()
            case .recoveryNeeded:
                recoverToMac()
            case .disabled, .checking, .macWaiting, .switchingToWindows, .switchingToMac:
                break
            }

        case let .forceShutdownRequested(onFailure):
            beginForceShutdown(onFailure: onFailure)

        case .stopRequested:
            delayedRefreshGeneration &+= 1
            delayedRefreshTask?.cancel()
            delayedRefreshTask = nil
            operationTask?.cancel()
            operationTask = nil
            remoteShutdownInProgress = false
            updateState { $0.stop() }
            applyRouteEnabled(false)

        case let .systemSuspended(systemSleeping, sessionInactive):
            delayedRefreshGeneration &+= 1
            delayedRefreshTask?.cancel()
            delayedRefreshTask = nil
            operationTask?.cancel()
            operationTask = nil
            updateState {
                $0.suspend(
                    systemSleeping: systemSleeping,
                    sessionInactive: sessionInactive
                )
            }
            applyRouteEnabled(false)
            crossScreenMouse.prepareForSystemTransition(forceStopMicrophone: true)

        case let .systemResumed(systemWoke, sessionBecameActive):
            updateState {
                $0.resume(
                    systemWoke: systemWoke,
                    sessionBecameActive: sessionBecameActive
                )
            }
            scheduleRouteRefresh(after: .seconds(1))

        case .screenParametersChanged:
            scheduleRouteRefresh(after: .milliseconds(400))

        case let .delayedRefresh(generation):
            guard generation == delayedRefreshGeneration else { return }
            delayedRefreshTask = nil
            guard stateMachine.canStartAutomaticRefresh else { return }
            refresh(allowAutomaticRecovery: false)
        }

        enforceSafetyInvariants()
    }

    @discardableResult
    func updateState<T>(_ update: (inout SoftKVMStateMachine) -> T) -> T {
        let previousStatus = stateMachine.status
        let result = update(&stateMachine)
        if stateMachine.status != previousStatus {
            onStatusChanged(stateMachine.status)
        }
        return result
    }

    private func execute(_ actions: [SoftKVMStateAction]) {
        for action in actions {
            switch action {
            case .disableRoute:
                applyRouteEnabled(false)
            case .refresh:
                refresh(allowAutomaticRecovery: false)
            }
        }
    }

    @discardableResult
    func applyRouteEnabled(_ enabled: Bool) -> Bool {
        updateState { $0.setDesiredRouteEnabled(enabled) }
        guard stateMachine.invariantViolation == nil else {
            enforceSafetyInvariants()
            return false
        }
        let succeeded = crossScreenMouse.setRouteEnabled(enabled)
        if enabled, !succeeded {
            updateState { $0.setDesiredRouteEnabled(false) }
        }
        return succeeded
    }

    private func enforceSafetyInvariants() {
        guard let violation = stateMachine.invariantViolation else { return }
        Self.logger.fault("Soft KVM invariant failed: \(violation, privacy: .public)")
        operationTask?.cancel()
        operationTask = nil
        remoteShutdownInProgress = false
        updateState {
            $0.forceSafeRecovery(reason: "检测到不一致状态，已关闭穿屏路由并恢复到安全状态。")
        }
        _ = crossScreenMouse.setRouteEnabled(false)
        crossScreenMouse.prepareForSystemTransition(forceStopMicrophone: true)
    }

    private func observeSystemState() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(.systemSuspended(systemSleeping: true, sessionInactive: false))
            }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(.systemSuspended(systemSleeping: false, sessionInactive: true))
            }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(.systemResumed(systemWoke: true, sessionBecameActive: false))
            }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(.systemResumed(systemWoke: false, sessionBecameActive: true))
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(.screenParametersChanged)
            }
        })
    }

    private func scheduleRouteRefresh(after delay: Duration) {
        guard stateMachine.canStartAutomaticRefresh else { return }
        delayedRefreshGeneration &+= 1
        let generation = delayedRefreshGeneration
        delayedRefreshTask?.cancel()
        delayedRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            send(.delayedRefresh(generation: generation))
        }
    }
}

private extension CrossScreenMouseStatus {
    var softKVMAvailability: SoftKVMMouseAvailability {
        switch self {
        case .off: .off
        case .needsArrangement: .needsArrangement
        case .waiting: .waiting
        case .standby: .standby
        case .connected: .connected
        case .controlling: .controlling
        case let .failed(reason): .failed(reason)
        }
    }
}
