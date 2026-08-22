import AppKit
import Foundation
import OSLog

final class CrossScreenMouseController: @unchecked Sendable {
    private struct MicrophoneReleaseTailContext {
        let generation: UInt64
        let connection: MouseConnection
        let controlID: UInt64
    }

    typealias StatusHandler = @MainActor (CrossScreenMouseStatus) -> Void
    typealias SoftKVMToggleHandler = @MainActor @Sendable () -> Void
    typealias MicrophoneActivationHandler = @MainActor @Sendable (Bool) -> Void

    static let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "CrossScreenMouse"
    )
    let runtimeLock = NSLock()
    private let onStatusChanged: StatusHandler
    private let onSoftKVMToggle: SoftKVMToggleHandler
    private let onMicrophoneActivationChanged: MicrophoneActivationHandler
    let localDisplayRoutingTopology: LocalDisplayRoutingTopology
    var state = CrossScreenMouseState()
    private var lastPublishedStatus: CrossScreenMouseStatus?
    let sharedDisplayID: String?
    private var screenObserver: NSObjectProtocol?
    private var inputTapRestartWorkItem: DispatchWorkItem?
    private var inputTapRestartGeneration: UInt64 = 0
    private let microphoneReleaseTailLock = NSLock()
    private var microphoneReleaseTailGate = MicrophoneReleaseTailGate()
    private var microphoneReleaseTailContext: MicrophoneReleaseTailContext?
    var controlTimeoutWorkItem: DispatchWorkItem?
    var lastKeyboardOverflowLog: ContinuousClock.Instant?

    private static let microphoneReleaseTailMilliseconds = 200

    lazy var hidInputTap = makeInputTap(kind: .hidInput)
    lazy var sessionKeyboardInputTap = makeInputTap(kind: .sessionKeyboard)

    @MainActor
    var inputTapsAreRunning: Bool {
        hidInputTap.isRunning && sessionKeyboardInputTap.isRunning
    }

    private func makeInputTap(kind: CrossScreenInputTapKind) -> InputEventTap {
        InputEventTap(
            tapLocation: kind.tapLocation,
            threadName: kind.threadName,
            listenerName: kind.listenerName,
            eventHandler: { [weak self] type, event in
                self?.handle(type: type, event: event) ?? false
            },
            stateHandler: { [weak self] tapState in
                self?.inputTapChanged(tapState, kind: kind)
            }
        )
    }

    @MainActor
    init(
        sharedDisplayID: String?,
        onStatusChanged: @escaping StatusHandler,
        onSoftKVMToggle: @escaping SoftKVMToggleHandler,
        onMicrophoneActivationChanged: @escaping MicrophoneActivationHandler
    ) {
        self.sharedDisplayID = sharedDisplayID
        localDisplayRoutingTopology = LocalDisplayRoutingTopology()
        self.onStatusChanged = onStatusChanged
        self.onSoftKVMToggle = onSoftKVMToggle
        self.onMicrophoneActivationChanged = onMicrophoneActivationChanged
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDisplaysAndGeometry()
            }
        }
        refreshDisplaysAndGeometry()
    }

    func requestSoftKVMToggle() {
        Task { @MainActor [onSoftKVMToggle] in
            onSoftKVMToggle()
        }
    }

    func requestMicrophoneActivationUpdate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let held = runtimeLock.withCriticalSection {
                state.microphoneActivationHeld
            }
            publishMicrophoneActivation(held)
        }
    }

    @MainActor
    func publishMicrophoneActivation(_ held: Bool) {
        if !held { cancelPendingMicrophoneReleaseTail() }
        onMicrophoneActivationChanged(held)
    }

    func beginMicrophoneReleaseTail(
        preserving networkAction: CrossScreenMouseNetworkAction,
        connection: MouseConnection,
        controlID: UInt64
    ) {
        let activationKey = runtimeLock.withCriticalSection {
            state.microphoneActivationKey
        }
        let generation = microphoneReleaseTailLock.withCriticalSection {
            let generation = microphoneReleaseTailGate.begin(activationKey: activationKey)
            microphoneReleaseTailContext = MicrophoneReleaseTailContext(
                generation: generation,
                connection: connection,
                controlID: controlID
            )
            return generation
        }
        sendNetworkAction(networkAction)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .milliseconds(Self.microphoneReleaseTailMilliseconds)
        ) { [weak self] in
            guard let self else { return }
            finishMicrophoneReleaseTail(generation: generation)
        }
    }

    @discardableResult
    func cancelPendingMicrophoneReleaseTail(controlID: UInt64? = nil) -> Bool {
        microphoneReleaseTailLock.withCriticalSection { () -> Bool in
            guard let context = microphoneReleaseTailContext,
                  controlID == nil || context.controlID == controlID else {
                return false
            }
            microphoneReleaseTailGate.cancel()
            microphoneReleaseTailContext = nil
            return true
        }
    }

    func microphoneReleaseTailActivationKey() -> MicrophoneActivationKey? {
        microphoneReleaseTailLock.withCriticalSection {
            microphoneReleaseTailGate.activationKey
        }
    }

    @discardableResult
    private func finishPendingMicrophoneReleaseTailImmediately() -> Bool {
        let pending: (MicrophoneReleaseTailContext, KeyboardReport)? =
            runtimeLock.withCriticalSection {
                guard let context = microphoneReleaseTailLock.withCriticalSection({
                    () -> MicrophoneReleaseTailContext? in
                    guard let context = microphoneReleaseTailContext else { return nil }
                    microphoneReleaseTailGate.cancel()
                    microphoneReleaseTailContext = nil
                    return context
                }) else { return nil }
                return (context, state.keyboard.report)
            }
        guard let (context, report) = pending else { return false }
        context.connection.sendKeyboardState(controlID: context.controlID, report)
        return true
    }

    private func finishMicrophoneReleaseTail(generation: UInt64) {
        let pending: (MicrophoneReleaseTailContext, KeyboardReport)? =
            runtimeLock.withCriticalSection {
                guard let context = microphoneReleaseTailLock.withCriticalSection({
                    () -> MicrophoneReleaseTailContext? in
                    guard let context = microphoneReleaseTailContext,
                          context.generation == generation,
                          microphoneReleaseTailGate.complete(generation: generation) else {
                        return nil
                    }
                    microphoneReleaseTailContext = nil
                    return context
                }) else { return nil }
                return (context, state.keyboard.report)
            }
        guard let (context, report) = pending else { return }
        context.connection.sendKeyboardState(controlID: context.controlID, report)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let held = runtimeLock.withCriticalSection {
                state.microphoneActivationHeld
            }
            if !held { publishMicrophoneActivation(false) }
        }
    }

    @MainActor
    func setMicrophoneActivationKey(_ activationKey: MicrophoneActivationKey) {
        guard activationKey.isValid else { return }
        let tailFinished = finishPendingMicrophoneReleaseTailImmediately()
        let released = runtimeLock.withCriticalSection {
            let released = state.releaseMicrophoneActivation()
            state.microphoneActivationKey = activationKey
            return released
        }
        if tailFinished || released {
            publishMicrophoneActivation(false)
        }
    }

    @MainActor
    func releaseMicrophoneActivationIfNeeded() {
        let tailFinished = finishPendingMicrophoneReleaseTailImmediately()
        let released = runtimeLock.withCriticalSection {
            state.releaseMicrophoneActivation()
        }
        if tailFinished || released {
            publishMicrophoneActivation(false)
        }
    }

    @MainActor
    func setConnection(
        _ connection: MouseConnection?,
        peer: MousePeer? = nil,
        runtimeFailure: String? = nil
    ) {
        let shouldRelease = runtimeLock.withCriticalSection {
            state.connection != nil && state.connection?.id != connection?.id
        }
        if shouldRelease {
            recoverLocalImmediately(
                sendRelease: false,
                reason: "connection changed",
                forceStopMicrophone: true
            )
        }
        runtimeLock.withCriticalSection {
            state.updateConnection(
                connection,
                peer: peer
            )
            if shouldRelease || connection == nil {
                state.disableWindowsRoute()
            }
            if connection != nil { state.runtimeFailure = runtimeFailure }
        }
        if connection == nil {
            stopTapIfUnneededAndLocal()
            publishStatus()
        } else {
            startTapIfNeeded()
        }
        refreshDisplaysAndGeometry()
    }

    @MainActor
    func driverDidBecomeUnavailable(_ message: String) {
        runtimeLock.withCriticalSection {
            state.disableWindowsRoute()
            state.keyboardSupported = false
            state.runtimeFailure = message
        }
        recoverLocalImmediately(
            sendRelease: false,
            reason: "driver unavailable",
            forceStopMicrophone: true
        )
        publishStatus()
    }

    @MainActor
    func setRuntimeFailure(_ message: String?) {
        runtimeLock.withCriticalSection {
            state.runtimeFailure = message
            if message != nil {
                state.disableWindowsRoute()
            }
        }
        publishStatus()
    }

    @MainActor
    func startTapIfNeeded() {
        let shouldStart = runtimeLock.withCriticalSection {
            state.enabled
        }
        guard shouldStart else {
            stopTapIfUnneededAndLocal()
            publishStatus()
            return
        }
        guard !inputTapsAreRunning else {
            publishStatus()
            return
        }
        _ = startInputTaps()
    }

    @MainActor
    @discardableResult
    private func startInputTaps() -> Bool {
        if !hidInputTap.isRunning,
           !hidInputTap.start(mask: CrossScreenInputTapKind.hidInput.eventMask) {
            handleInputTapStartFailure(kind: .hidInput)
            return false
        }
        if !sessionKeyboardInputTap.isRunning,
           !sessionKeyboardInputTap.start(
               mask: CrossScreenInputTapKind.sessionKeyboard.eventMask
           ) {
            handleInputTapStartFailure(kind: .sessionKeyboard)
            return false
        }
        synchronizeInputTapState()
        return true
    }

    @MainActor
    func prioritizeInputTapsForRemoteRoute() -> Bool {
        cancelInputTapRestart()
        stopInputTaps()
        guard startInputTaps() else { return false }
        return true
    }

    @MainActor
    private func synchronizeInputTapState() {
        cancelInputTapRestart()
        let localButtons = currentMouseButtonMask()
        let pointerLocation = MacCursorOwnership.currentLocation()
        runtimeLock.withCriticalSection {
            state.tapFailure = nil
            state.localButtons = localButtons
            state.displayHandoff.resetTracking(
                at: state.ownership.capturesInput ? nil : pointerLocation
            )
        }
        publishStatus()
    }

    @MainActor
    private func handleInputTapStartFailure(kind: CrossScreenInputTapKind) {
        runtimeLock.withCriticalSection {
            state.disableWindowsRoute()
            state.tapFailure = kind.startupFailureMessage
            state.softKVMShortcutCapture.reset()
        }
        recoverLocalImmediately(
            sendRelease: true,
            reason: kind.startupFailureReason,
            forceStopMicrophone: true
        )
        stopInputTaps()
        publishStatus()
    }

    @MainActor
    func stopInputTaps() {
        hidInputTap.stop()
        sessionKeyboardInputTap.stop()
    }

    @MainActor
    func cancelInputTapRestart() {
        inputTapRestartGeneration &+= 1
        inputTapRestartWorkItem?.cancel()
        inputTapRestartWorkItem = nil
    }

    @MainActor
    func setLocalKeyboardCaptureRequired(_ required: Bool) {
        let changed = runtimeLock.withCriticalSection {
            let changed = state.localKeyboardCaptureRequired != required
            state.localKeyboardCaptureRequired = required
            return changed
        }
        guard changed else { return }
        startTapIfNeeded()
    }

    @MainActor
    private func inputTapChanged(
        _ tapState: InputEventTapState,
        kind: CrossScreenInputTapKind
    ) {
        let pointerLocation = MacCursorOwnership.currentLocation()
        runtimeLock.withCriticalSection {
            state.displayHandoff.resetTracking(
                at: state.ownership.capturesInput ? nil : pointerLocation
            )
        }
        switch tapState {
        case .disabled:
            disableRouteAndResetShortcutCapture()
            releaseRemote(
                sendRelease: true,
                normalizedY: nil,
                reason: "event tap disabled",
                restoreImmediately: true,
                forceStopMicrophone: true
            )
        case let .needsRestart(reason):
            disableRouteAndResetShortcutCapture()
            releaseRemote(
                sendRelease: true,
                normalizedY: nil,
                reason: "event tap restart",
                restoreImmediately: true,
                forceStopMicrophone: true
            )
            runtimeLock.withCriticalSection {
                state.tapFailure = "跨屏\(kind.logName)监听已失效，正在尝试恢复：\(reason)"
            }
            publishStatus()
            cancelInputTapRestart()
            let restartGeneration = inputTapRestartGeneration
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.inputTapRestartGeneration == restartGeneration else { return }
                    self.inputTapRestartWorkItem = nil
                    self.stopInputTaps()
                    self.startTapIfNeeded()
                }
            }
            inputTapRestartWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
            Self.logger.error(
                "跨屏\(kind.logName, privacy: .public)监听失效：\(reason, privacy: .public)"
            )
        }
    }

    @MainActor
    func stopTapIfUnneededAndLocal() {
        let shouldStop = runtimeLock.withCriticalSection {
            !state.ownership.capturesInput && !state.enabled
        }
        if shouldStop {
            cancelInputTapRestart()
            stopInputTaps()
        }
    }

    @MainActor
    func publishStatus() {
        let status = runtimeLock.withCriticalSection { state.status }
        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        onStatusChanged(status)
    }
}
