@preconcurrency import CoreGraphics

enum CrossScreenInputTapKind: CaseIterable {
    case hidInput
    case sessionKeyboard

    var tapLocation: CGEventTapLocation {
        switch self {
        case .hidInput: .cghidEventTap
        case .sessionKeyboard: .cgSessionEventTap
        }
    }

    var eventMask: CGEventMask {
        switch self {
        case .hidInput: CrossScreenInputRouting.hidEventMask
        case .sessionKeyboard: CrossScreenInputRouting.keyboardEventMask
        }
    }

    var threadName: String {
        switch self {
        case .hidInput: "com.sunkanwei.Meno.cross-screen-hid-input-events"
        case .sessionKeyboard: "com.sunkanwei.Meno.cross-screen-session-keyboard-events"
        }
    }

    var listenerName: String {
        switch self {
        case .hidInput: "跨屏底层输入监听"
        case .sessionKeyboard: "跨屏会话键盘监听"
        }
    }

    var logName: String {
        switch self {
        case .hidInput: "底层输入"
        case .sessionKeyboard: "会话键盘"
        }
    }

    var startupFailureMessage: String {
        "无法建立\(listenerName)，请确认 Meno 的辅助功能和输入监听权限。"
    }

    var startupFailureReason: String {
        switch self {
        case .hidInput: "HID input listener startup failed"
        case .sessionKeyboard: "session keyboard listener startup failed"
        }
    }
}

enum CrossScreenInputRouting {
    private static let automationPointerEventMarker: Int64 = 0x54_48_41_57

    private static let mouseOnly: CGEventMask = [
        CGEventType.mouseMoved,
        .leftMouseDown,
        .leftMouseUp,
        .rightMouseDown,
        .rightMouseUp,
        .otherMouseDown,
        .otherMouseUp,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged,
    ].reduce(0) { mask, type in
        mask | CGEventMask(1 << type.rawValue)
    }

    static let keyboardEventMask: CGEventMask = [
        CGEventType.keyDown,
        .keyUp,
        .flagsChanged,
    ].reduce(0) { mask, type in
        mask | CGEventMask(1 << type.rawValue)
    }

    private static let wheel = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

    static let hidEventMask = mouseOnly | wheel | keyboardEventMask

    static func shouldHandleKeyboard(
        capturesInput: Bool,
        localKeyboardCaptureRequired: Bool
    ) -> Bool {
        capturesInput || localKeyboardCaptureRequired
    }

    static func isAutomationMarkedPointerEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        guard mouseOnly & CGEventMask(1 << type.rawValue) != 0 else {
            return false
        }
        return event.getIntegerValueField(.eventSourceUserData)
            == automationPointerEventMarker
    }

    static func isEmergencyRelease(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
            return false
        }
        return event.flags.contains(.maskCommand)
            && event.flags.contains(.maskAlternate)
    }
}
