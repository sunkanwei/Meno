import AppKit
@preconcurrency import CoreGraphics

enum MicrophonePushToTalkState: Equatable, Sendable {
    case idle
    case remoteHeld
    case awaitingPhysicalRelease

    var isHeld: Bool {
        self != .idle
    }

    @discardableResult
    mutating func updateRemoteKey(isPressed: Bool) -> Bool {
        switch (self, isPressed) {
        case (.idle, true):
            self = .remoteHeld
            return true
        case (.remoteHeld, false):
            self = .idle
            return true
        case (.awaitingPhysicalRelease, _), (.idle, false), (.remoteHeld, true):
            return false
        }
    }

    @discardableResult
    mutating func preserveWhileReturningToMac(physicalKeyIsPressed: Bool) -> Bool {
        switch (self, physicalKeyIsPressed) {
        case (.remoteHeld, true):
            self = .awaitingPhysicalRelease
            return false
        case (.remoteHeld, false):
            self = .idle
            return true
        case (.idle, _), (.awaitingPhysicalRelease, _):
            return false
        }
    }

    @discardableResult
    mutating func observePhysicalRelease(physicalKeyIsPressed: Bool) -> Bool {
        guard self == .awaitingPhysicalRelease, !physicalKeyIsPressed else {
            return false
        }
        self = .idle
        return true
    }

    @discardableResult
    mutating func forceStop() -> Bool {
        guard self != .idle else { return false }
        self = .idle
        return true
    }
}

struct MicrophoneReleaseTailGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var activationKey: MicrophoneActivationKey?

    var isPending: Bool {
        activationKey != nil
    }

    mutating func begin(activationKey: MicrophoneActivationKey) -> UInt64 {
        advanceGeneration()
        self.activationKey = activationKey
        return generation
    }

    mutating func cancel() {
        guard isPending else { return }
        advanceGeneration()
        activationKey = nil
    }

    mutating func complete(generation: UInt64) -> Bool {
        guard isPending, self.generation == generation else { return false }
        activationKey = nil
        return true
    }

    private mutating func advanceGeneration() {
        generation &+= 1
        if generation == 0 { generation = 1 }
    }
}

struct MicrophoneActivationKey: Codable, Equatable, Sendable {
    static let defaultValue = Self(
        keyCode: 61,
        keyLabel: "右 Alt"
    )

    let keyCode: UInt16
    let keyLabel: String
    let hidUsage: UInt8?

    init(keyCode: UInt16, keyLabel: String, hidUsage: UInt8? = nil) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.hidUsage = hidUsage
    }

    var title: String {
        Self.standardLabel(for: keyCode, hidUsage: resolvedHIDUsage) ?? keyLabel
    }

    var isValid: Bool {
        keyCode != MacKeyboardMapping.capsLockKeyCode
            && (modifierMask != nil || resolvedHIDUsage != nil)
    }

    func isPressed(in keyboard: HIDKeyboardState) -> Bool {
        if let modifierMask {
            return keyboard.modifiers & modifierMask != 0
        }
        guard let usage = resolvedHIDUsage else { return false }
        return keyboard.usages.contains(usage)
    }

    func isPhysicallyPressed() -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }

    @discardableResult
    func setPressed(_ pressed: Bool, in keyboard: inout HIDKeyboardState) -> Bool {
        if let modifierMask {
            let modifiers = pressed
                ? keyboard.modifiers | modifierMask
                : keyboard.modifiers & ~modifierMask
            return keyboard.setModifiers(modifiers)
        }
        guard let usage = resolvedHIDUsage else { return false }
        return keyboard.setUsage(usage, pressed: pressed)
    }

    func preservingPressed(in report: KeyboardReport) -> KeyboardReport {
        if let modifierMask {
            return report.insertingModifiers(modifierMask)
        }
        guard let usage = resolvedHIDUsage else { return report }
        return report.insertingPrioritizedUsage(usage)
    }

    static func make(event: NSEvent) -> Self? {
        let keyCode = UInt16(event.keyCode)
        let specialFunctionKey = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
        let hidUsage = MacKeyboardMapping.usage(forKeyCode: keyCode)
            ?? MacKeyboardMapping.usage(forSpecialFunctionKey: specialFunctionKey)
        let key = Self(
            keyCode: keyCode,
            keyLabel: label(for: keyCode, hidUsage: hidUsage, event: event),
            hidUsage: hidUsage
        )
        return key.isValid ? key : nil
    }

    private var resolvedHIDUsage: UInt8? {
        if let hidUsage, hidUsage >= 0x04, hidUsage < 0xE0 {
            return hidUsage
        }
        return MacKeyboardMapping.usage(forKeyCode: keyCode)
    }

    private var modifierMask: UInt8? {
        switch keyCode {
        case 55: 1 << 0 // Left Command / Windows
        case 56: 1 << 1 // Left Shift
        case 58: 1 << 2 // Left Option / Alt
        case 59: 1 << 3 // Left Control
        case 54: 1 << 4 // Right Command / Windows
        case 60: 1 << 5 // Right Shift
        case 61: 1 << 6 // Right Option / Alt
        case 62: 1 << 7 // Right Control
        default: nil
        }
    }

    private static func label(for keyCode: UInt16, hidUsage: UInt8?, event: NSEvent) -> String {
        if let label = standardLabel(for: keyCode, hidUsage: hidUsage) {
            return label
        }
        let value = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let scalar = value.unicodeScalars.first,
              scalar.value < 0xF700,
              !CharacterSet.controlCharacters.contains(scalar) else {
            return "按键 \(keyCode)"
        }
        return String(value.prefix(1)).uppercased()
    }

    private static func standardLabel(for keyCode: UInt16, hidUsage: UInt8?) -> String? {
        if let hidUsage, (0x70...0x73).contains(hidUsage) {
            return "F\(Int(hidUsage - 0x70) + 21)"
        }
        switch keyCode {
        case 54: return "右 WIN"
        case 55: return "左 WIN"
        case 56: return "左 Shift"
        case 60: return "右 Shift"
        case 58: return "左 Alt"
        case 61: return "右 Alt"
        case 59: return "左 Ctrl"
        case 62: return "右 Ctrl"
        case 36: return "Enter"
        case 48: return "Tab"
        case 49: return "空格"
        case 51: return "Backspace"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Insert"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Delete"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "左方向键"
        case 124: return "右方向键"
        case 125: return "下方向键"
        case 126: return "上方向键"
        default: return nil
        }
    }
}
