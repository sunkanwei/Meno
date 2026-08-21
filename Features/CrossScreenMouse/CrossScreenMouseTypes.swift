import AppKit
@preconcurrency import CoreGraphics
import Foundation

enum CrossScreenMouseStatus: Equatable {
    case off
    case needsArrangement
    case waiting
    case standby(name: String, entryInstruction: String)
    case connected(name: String, entryInstruction: String)
    case controlling(name: String, entryInstruction: String)
    case failed(String)

    var detail: String {
        switch self {
        case .off: "不会拦截任何 Mac 屏幕边缘。"
        case .needsArrangement: "只支持三块已登记屏幕横向相邻、Mac 主屏居中且 Philips 位于左侧或右侧。"
        case .waiting: "屏幕接缝已经配置，正在等待 Windows EXE。"
        case let .standby(_, instruction):
            "Windows 输入通道在线。切换到 Windows 后，\(instruction)"
        case let .connected(_, instruction): instruction
        case let .controlling(_, instruction):
            "鼠标事件正在发送到 Windows。\(instruction)"
        case let .failed(message): message
        }
    }
}

enum CrossScreenMouseMode {
    case local
    case acquiring(UInt64)
    case remote(UInt64)
    case releasing(UInt64, UInt16)

    var controlID: UInt64? {
        switch self {
        case .local: nil
        case let .acquiring(controlID), let .remote(controlID),
             let .releasing(controlID, _): controlID
        }
    }

    var capturesInput: Bool {
        if case .local = self { return false }
        return true
    }
}

struct CrossScreenMouseState {
    var enabled = false
    var windowsRouteEnabled = false
    var softKVMTopologyPlan: SoftKVMTopologyPlan?
    var windowsGeometry: WindowsDisplayHandoffGeometry?
    var displayHandoff = HorizontalDisplayHandoffState()
    var windowsSession: WindowsDisplayHandoffSession?
    var connection: MouseConnection?
    var remoteName: String?
    var keyboardSupported = false
    var remoteShutdownSupported = false
    var directionalHandoffSupported = false
    var remoteScreenMetrics: MouseScreenMetrics?
    var mode = CrossScreenMouseMode.local
    var localButtons: UInt8 = 0
    var keyboard = HIDKeyboardState()
    var entryGate = CrossScreenEntryGate()
    var movementScaler = MouseMovementScaler(scaleX: 1, scaleY: 1)
    var lastWindowsNormalizedY: UInt16 = UInt16.max / 2
    private var cursorCapture: MacCursorOwnership.CaptureToken?
    var controlStartedAt: ContinuousClock.Instant?
    var tapFailure: String?
    var runtimeFailure: String?
    var softKVMShortcut = SoftKVMShortcut.defaultValue
    var softKVMShortcutCapture = SoftKVMShortcutCapture()
    var softKVMShortcutCaptureEnabled = true
    var localKeyboardCaptureRequired = false
    var microphoneActivationKey = MicrophoneActivationKey.defaultValue
    var microphonePushToTalkState = MicrophonePushToTalkState.idle

    var microphoneActivationHeld: Bool {
        microphonePushToTalkState.isHeld
    }

    var status: CrossScreenMouseStatus {
        guard enabled else { return .off }
        guard windowsGeometry != nil else { return .needsArrangement }
        if let tapFailure { return .failed(tapFailure) }
        if let runtimeFailure { return .failed(runtimeFailure) }
        guard let remoteName, connection != nil else { return .waiting }
        guard directionalHandoffSupported else {
            return .failed("Windows 输入程序不支持左右穿屏，请更新 Windows 端。")
        }
        let instruction = windowsGeometry?.entryInstruction ?? "穿屏入口正在重新计算。"
        if mode.capturesInput {
            return .controlling(name: remoteName, entryInstruction: instruction)
        }
        return windowsRouteEnabled
            ? .connected(name: remoteName, entryInstruction: instruction)
            : .standby(name: remoteName, entryInstruction: instruction)
    }

    mutating func updateLocalButtons(type: CGEventType, event: CGEvent) {
        guard let change = mouseButtonChange(type: type, event: event) else { return }
        if change.isPressed {
            localButtons |= change.localMask
        } else {
            localButtons &= ~change.localMask
        }
    }

    mutating func displayHandoffDecision(
        type: CGEventType,
        location: CGPoint,
        movementDeltaX: CGFloat
    ) -> HorizontalDisplayHandoffDecision {
        let allowsHandoff = allowsLocalDisplayHandoff(
            type: type,
            localButtons: localButtons
        )
        guard handlesLocalDisplayBoundary(
            type: type,
            localButtons: localButtons
        ) else {
            if reportsPointerLocation(type) {
                displayHandoff.observe(location: location)
            }
            return .none
        }
        return displayHandoff.decision(
            location: location,
            movementDeltaX: movementDeltaX,
            allowsHandoff: allowsHandoff
        )
    }

    mutating func refreshMovementScale() {
        guard let sourceDisplay = windowsGeometry?.macDisplay,
              let remoteScreenMetrics else {
            movementScaler = MouseMovementScaler(scaleX: 1, scaleY: 1)
            return
        }
        let sourceSize = sourceDisplay.frame.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            movementScaler = MouseMovementScaler(scaleX: 1, scaleY: 1)
            return
        }
        movementScaler = MouseMovementScaler(
            sourceWidth: Double(sourceSize.width),
            sourceHeight: Double(sourceSize.height),
            sourceHeightMM: sourceDisplay.physicalHeightMM.map(Double.init),
            destination: remoteScreenMetrics,
            destinationHeightMM: Double(FixedDisplayConfiguration.philipsActiveHeightMM)
        )
    }

    mutating func didCaptureCursor(_ capture: MacCursorOwnership.CaptureToken) {
        cursorCapture = capture
    }

    mutating func takeCursorCaptureForRestore() -> MacCursorOwnership.CaptureToken? {
        let capture = cursorCapture
        cursorCapture = nil
        return capture
    }

    mutating func updateDisplayGeometries(
        windows windowsGeometry: WindowsDisplayHandoffGeometry?,
        displayHandoff displayHandoffGeometry: HorizontalDisplayHandoffGeometry?,
        pointerLocation: CGPoint? = nil
    ) {
        self.windowsGeometry = windowsGeometry
        self.displayHandoff.updateGeometry(
            displayHandoffGeometry,
            pointerLocation: pointerLocation
        )
        refreshMovementScale()
    }

    mutating func updateConnection(
        _ connection: MouseConnection?,
        peer: MousePeer?
    ) {
        self.connection = connection
        remoteName = connection == nil ? nil : peer?.name
        keyboardSupported = connection != nil && peer?.keyboardSupported == true
        remoteShutdownSupported = connection != nil && peer?.remoteShutdownSupported == true
        directionalHandoffSupported = connection != nil
            && peer?.directionalHandoffSupported == true
        remoteScreenMetrics = connection == nil ? nil : peer?.screenMetrics
        if connection == nil { windowsSession = nil }
        refreshMovementScale()
    }

    mutating func updateMicrophoneActivation() -> Bool {
        microphonePushToTalkState.updateRemoteKey(
            isPressed: microphoneActivationKey.isPressed(in: keyboard)
        )
    }

    mutating func activateMicrophoneIfPhysicalKeyHeld() -> KeyboardReport? {
        guard microphonePushToTalkState == .idle,
              microphoneActivationKey.isPhysicallyPressed() else {
            return nil
        }
        _ = microphoneActivationKey.setPressed(true, in: &keyboard)
        guard microphonePushToTalkState.updateRemoteKey(isPressed: true) else {
            return nil
        }
        return microphoneActivationKey.preservingPressed(in: keyboard.report)
    }

    mutating func preserveMicrophoneActivationWhileReturningToMac() -> Bool {
        microphonePushToTalkState.preserveWhileReturningToMac(
            physicalKeyIsPressed: microphoneActivationKey.isPhysicallyPressed()
        )
    }

    mutating func observePendingMicrophonePhysicalRelease() -> Bool {
        guard microphonePushToTalkState == .awaitingPhysicalRelease else {
            return false
        }
        return microphonePushToTalkState.observePhysicalRelease(
            physicalKeyIsPressed: microphoneActivationKey.isPhysicallyPressed()
        )
    }

    mutating func releaseMicrophoneActivation() -> Bool {
        microphonePushToTalkState.forceStop()
    }
}

enum CrossScreenMouseNetworkAction {
    case enter(
        connection: MouseConnection,
        controlID: UInt64,
        normalizedY: UInt16,
        residualX: Int32,
        entryEdge: HorizontalDisplaySide,
        returnOpeningY: ClosedRange<Int32>
    )
    case move(
        connection: MouseConnection,
        controlID: UInt64,
        deltaX: Int32,
        deltaY: Int32
    )
    case button(
        connection: MouseConnection,
        controlID: UInt64,
        button: UInt8,
        isPressed: Bool
    )
    case wheel(
        connection: MouseConnection,
        controlID: UInt64,
        inputLines: Double
    )
    case keyboard(
        connection: MouseConnection,
        controlID: UInt64,
        reports: [KeyboardReport],
        overflowed: Bool
    )
}

enum CrossScreenMouseAction {
    case none
    case displayHandoff(HorizontalDisplayHandoff)
    case stabilizeDisplayHandoff(CGPoint)
    case displayHandoffWall(HorizontalDisplayHandoffWall)
    case send(CrossScreenMouseNetworkAction)
    case sendAndActivateMicrophone(CrossScreenMouseNetworkAction)
    case sendAndBeginMicrophoneReleaseTail(
        CrossScreenMouseNetworkAction,
        MouseConnection,
        UInt64
    )
    case swallow
    case emergencyRelease
    case toggleSoftKVM
}

func isMovement(_ type: CGEventType) -> Bool {
    type == .mouseMoved || type == .leftMouseDragged
        || type == .rightMouseDragged || type == .otherMouseDragged
}

func reportsPointerLocation(_ type: CGEventType) -> Bool {
    isMovement(type)
        || type == .leftMouseDown || type == .leftMouseUp
        || type == .rightMouseDown || type == .rightMouseUp
        || type == .otherMouseDown || type == .otherMouseUp
}

func isKeyboardEvent(_ type: CGEventType) -> Bool {
    type == .keyDown || type == .keyUp || type == .flagsChanged
}

func specialFunctionKeyScalar(_ event: CGEvent) -> UInt32? {
    NSEvent(cgEvent: event)?.specialKey?.unicodeScalar.value
}

func movementDeltaX(_ event: CGEvent) -> CGFloat {
    CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
}

func movementDeltaY(_ event: CGEvent) -> CGFloat {
    CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
}

func wheelInputLines(_ event: CGEvent) -> Double {
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    let delta = isContinuous
        ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        : Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    return MouseWheelInput.normalized(
        delta,
        isContinuous: isContinuous,
        directionInvertedFromDevice: NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice
            == true
    )
}

struct MouseButtonChange {
    let button: UInt8
    let isPressed: Bool
    let localMask: UInt8
}

func mouseButtonChange(
    type: CGEventType,
    event: CGEvent
) -> MouseButtonChange? {
    switch type {
    case .leftMouseDown: MouseButtonChange(button: 1, isPressed: true, localMask: 1)
    case .leftMouseUp: MouseButtonChange(button: 1, isPressed: false, localMask: 1)
    case .rightMouseDown: MouseButtonChange(button: 2, isPressed: true, localMask: 2)
    case .rightMouseUp: MouseButtonChange(button: 2, isPressed: false, localMask: 2)
    case .otherMouseDown, .otherMouseUp:
        event.getIntegerValueField(.mouseEventButtonNumber) == 2
            ? MouseButtonChange(
                button: 3,
                isPressed: type == .otherMouseDown,
                localMask: 4
            )
            : nil
    default: nil
    }
}

func currentMouseButtonMask() -> UInt8 {
    var mask: UInt8 = 0
    if CGEventSource.buttonState(.combinedSessionState, button: .left) { mask |= 1 }
    if CGEventSource.buttonState(.combinedSessionState, button: .right) { mask |= 2 }
    if CGEventSource.buttonState(.combinedSessionState, button: .center) { mask |= 4 }
    return mask
}

extension Duration {
    var crossScreenTimeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
