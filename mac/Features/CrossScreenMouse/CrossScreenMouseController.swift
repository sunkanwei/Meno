import AppKit
import Foundation
import OSLog

final class CrossScreenMouseController: @unchecked Sendable {
    typealias StatusHandler = @MainActor (CrossScreenMouseStatus) -> Void
    typealias SoftKVMToggleHandler = @MainActor @Sendable () -> Void

    static let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "CrossScreenMouse"
    )
    let runtimeLock = NSLock()
    var mouseVoiceShortcutRequested = false
    let onMouseVoiceStatusChanged: @MainActor (MouseVoiceShortcutStatus) -> Void
    private let onStatusChanged: StatusHandler
    private let onSoftKVMToggle: SoftKVMToggleHandler
    let localDisplayRoutingTopology: LocalDisplayRoutingTopology
    var state = CrossScreenMouseState()
    private var lastPublishedStatus: CrossScreenMouseStatus?
    let sharedDisplayID: String?
    private var screenObserver: NSObjectProtocol?
    private var inputTapRestartWorkItem: DispatchWorkItem?
    private var inputTapRestartGeneration: UInt64 = 0
    var controlTimeoutWorkItem: DispatchWorkItem?
    var lastKeyboardOverflowLog: ContinuousClock.Instant?

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
                self?.handle(type: type, event: event, kind: kind) ?? false
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
        onMouseVoiceStatusChanged: @escaping @MainActor (MouseVoiceShortcutStatus) -> Void
    ) {
        self.sharedDisplayID = sharedDisplayID
        localDisplayRoutingTopology = LocalDisplayRoutingTopology()
        self.onStatusChanged = onStatusChanged
        self.onSoftKVMToggle = onSoftKVMToggle
        self.onMouseVoiceStatusChanged = onMouseVoiceStatusChanged
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
                reason: "connection changed"
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
            reason: "driver unavailable"
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
            state.enabled || state.mouseVoiceShortcut.requiresInputTap
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
            synchronizeMouseVoiceInputLocked()
            state.localButtons = localButtons
            state.displayHandoff.resetTracking(
                at: state.ownership.capturesInput ? nil : pointerLocation
            )
        }
        stopTapIfUnneededAndLocal()
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
            reason: kind.startupFailureReason
        )
        stopInputTaps()
        publishStatus()
    }

    @MainActor
    func stopInputTaps() {
        hidInputTap.stop()
        sessionKeyboardInputTap.stop()
        cancelMouseVoiceShortcut()
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
            cancelMouseVoiceShortcutLocked()
            synchronizeMouseVoiceInputLocked()
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
                restoreImmediately: true
            )
        case let .needsRestart(reason):
            disableRouteAndResetShortcutCapture()
            releaseRemote(
                sendRelease: true,
                normalizedY: nil,
                reason: "event tap restart",
                restoreImmediately: true
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
            !state.ownership.capturesInput && !state.enabled && !state.mouseVoiceShortcut.requiresInputTap
        }
        if shouldStop {
            cancelInputTapRestart()
            stopInputTaps()
        }
    }

    @MainActor
    func publishStatus() {
        publishMouseVoiceShortcutStatus()
        let status = runtimeLock.withCriticalSection { state.status }
        guard status != lastPublishedStatus else { return }
        lastPublishedStatus = status
        onStatusChanged(status)
    }
}
