import CoreGraphics

enum MouseVoiceShortcutStatus: Equatable {
    case off
    case ready
    case waitingForPermissions
    case suspended
    case failed

    var title: String {
        switch self {
        case .off: "已关闭"
        case .ready: "已就绪"
        case .waitingForPermissions: "需要辅助功能和输入监听权限"
        case .suspended: "系统会话不可用，已暂停"
        case .failed: "输入监听不可用"
        }
    }
}

struct MouseVoiceShortcut {
    static let buttonNumber: Int64 = 3
    static let rightAltKeyCode: CGKeyCode = 61
    static let eventMarker: Int64 = 0x4D_56_4F_49_43_45
    static let rightAltFlag = CGEventFlags(rawValue: 0x40)
    static let leftAltFlag = CGEventFlags(rawValue: 0x20)

    struct Result: Equatable {
        var consume = false
        var keyDown: Bool?
    }

    var enabled = false
    private(set) var systemAvailable = true
    private(set) var physicalRightAltDown = false
    private(set) var buttonHeld = false
    private(set) var active = false

    var requiresInputTap: Bool { enabled || buttonHeld }

    mutating func handle(
        type: CGEventType,
        buttonNumber: Int64,
        isLocal: Bool
    ) -> Result {
        guard type == .otherMouseDown || type == .otherMouseUp,
              buttonNumber == Self.buttonNumber else { return Result() }

        if type == .otherMouseUp {
            guard buttonHeld else { return Result() }
            let release = cancel()
            buttonHeld = false
            return Result(consume: true, keyDown: release)
        }
        if buttonHeld { return Result(consume: true) }
        guard enabled, systemAvailable, isLocal else { return Result() }
        buttonHeld = true
        active = true
        return Result(consume: true, keyDown: physicalRightAltDown ? nil : true)
    }

    // Keep swallowing this press's eventual release after cancellation.
    mutating func cancel() -> Bool? {
        let release = active && !physicalRightAltDown
        active = false
        return release ? false : nil
    }

    mutating func setSystemAvailable(_ available: Bool) -> Bool? {
        systemAvailable = available
        return available ? nil : cancel()
    }

    mutating func observePhysicalModifiers(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        // Idle events repair state missed while the tap/session was unavailable.
        // During a hold, only the physical right Alt transition is authoritative.
        guard !active || (type == .flagsChanged && keyCode == Self.rightAltKeyCode) else { return }
        physicalRightAltDown = flags.contains(Self.rightAltFlag)
    }

    mutating func synchronizeButton(isDown: Bool) {
        guard !active else { return }
        buttonHeld = buttonHeld && isDown
    }

    static func flags(_ physicalFlags: CGEventFlags, rightAltDown: Bool) -> CGEventFlags {
        var flags = physicalFlags
        if rightAltDown {
            flags.formUnion([.maskAlternate, rightAltFlag])
        } else {
            flags.remove(rightAltFlag)
            if !flags.contains(leftAltFlag) { flags.remove(.maskAlternate) }
        }
        return flags
    }

    static func makeKeyEvent(isDown: Bool, physicalFlags: CGEventFlags) -> CGEvent? {
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: rightAltKeyCode,
                  keyDown: isDown
              ) else { return nil }
        event.type = .flagsChanged
        event.flags = flags(physicalFlags, rightAltDown: isDown)
        event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        return event
    }
}
