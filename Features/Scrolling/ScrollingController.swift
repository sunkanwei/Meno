import AppKit
import CoreGraphics
import OSLog

@MainActor
final class ScrollingController {
    private let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "Scrolling")
    private let onStatusChanged: (ScrollingStatus) -> Void
    private var enabled = false
    private var wakeObserver: NSObjectProtocol?
    private var resolver: HIDScrollEventResolver?
    private var eventTap: ScrollEventTap?
    private var eventTapGeneration = 0

    init(onStatusChanged: @escaping (ScrollingStatus) -> Void) {
        self.onStatusChanged = onStatusChanged
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refresh()
    }

    func refresh() {
        guard enabled else {
            stopRuntime()
            onStatusChanged(.off)
            return
        }

        guard ScrollDirectionCompatibility.supports(
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ) else {
            failSafe("当前 macOS 大版本尚未完成滚动设备兼容性验证。")
            return
        }

        guard AccessibilityPermission.canReadAccessibility,
              AccessibilityPermission.canListenToKeyboard else {
            stopRuntime()
            onStatusChanged(.waitingForPermissions)
            return
        }

        if eventTap?.isRunning == true {
            onStatusChanged(.running)
            return
        }

        eventTap?.stop()
        eventTap = nil
        resolver?.stop()
        resolver = nil

        let resolver = HIDScrollEventResolver()
        guard resolver.isAvailable else {
            failSafe("当前系统缺少所需的滚动设备识别接口。")
            return
        }
        let processor = ScrollEventProcessor(resolver: resolver)
        eventTapGeneration &+= 1
        let generation = eventTapGeneration
        let eventTap = ScrollEventTap(
            eventHandler: { event in
                processor.handle(event)
            },
            stateHandler: { [weak self] state in
                self?.eventTapStateChanged(state, generation: generation)
            }
        )
        guard eventTap.start() else {
            resolver.stop()
            failSafe("无法建立系统滚轮监听，已保留原有滚动行为。")
            return
        }
        self.resolver = resolver
        self.eventTap = eventTap
        observeWake()
        onStatusChanged(.running)
        logger.info("Per-device scrolling is running")
    }

    func stopForApplicationExit() {
        stopRuntime()
    }

    private func eventTapStateChanged(
        _ state: ScrollEventTapState,
        generation: Int
    ) {
        guard generation == eventTapGeneration, enabled else { return }
        switch state {
        case let .recovered(reason):
            onStatusChanged(.running)
            logger.info("\(reason, privacy: .public)，滚轮功能继续运行")
        case let .needsRestart(reason):
            guard enabled else { return }
            logger.error("\(reason, privacy: .public)，正在重建滚轮监听")
            stopRuntime()
            refresh()
        }
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                stopRuntime()
                refresh()
            }
        }
    }

    private func failSafe(_ message: String) {
        stopRuntime()
        onStatusChanged(.failed(message))
        logger.error("\(message, privacy: .public)")
    }

    private func stopRuntime() {
        eventTapGeneration &+= 1
        eventTap?.stop()
        eventTap = nil
        resolver?.stop()
        resolver = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}

private final class ScrollEventProcessor: @unchecked Sendable {
    private let resolver: HIDScrollEventResolver

    init(resolver: HIDScrollEventResolver) {
        self.resolver = resolver
    }

    func handle(_ event: CGEvent) {
        guard let context = resolver.context(for: event),
              ScrollDirectionPolicy.action(for: context.source) == .reverseVertical else {
            return
        }

        let lineDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixedDelta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let embeddedDelta = resolver.embeddedVertical(in: context)

        if lineDelta != Int64.min {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineDelta)
        }
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedDelta)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -pointDelta)
        resolver.setEmbeddedVertical(-embeddedDelta, in: context)
    }
}
