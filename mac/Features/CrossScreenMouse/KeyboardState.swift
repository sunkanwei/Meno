import Foundation

struct KeyboardReport: Equatable, Sendable {
    static let maximumUsages = 6
    static let released = KeyboardReport(modifiers: 0, usages: [])

    let modifiers: UInt8
    let usages: [UInt8]
    let overflowed: Bool

    init<S: Sequence>(modifiers: UInt8, usages: S) where S.Element == UInt8 {
        self.init(modifiers: modifiers, usages: usages, prioritizing: nil)
    }

    private init<S: Sequence>(
        modifiers: UInt8,
        usages: S,
        prioritizing prioritizedUsage: UInt8?
    ) where S.Element == UInt8 {
        let normalized = Array(Set(usages.filter { $0 >= 0x04 && $0 < 0xE0 })).sorted()
        self.modifiers = modifiers
        overflowed = normalized.count > Self.maximumUsages
        var selected = Array(normalized.prefix(Self.maximumUsages))
        if overflowed, let prioritizedUsage,
           normalized.contains(prioritizedUsage),
           !selected.contains(prioritizedUsage) {
            selected[selected.count - 1] = prioritizedUsage
            selected.sort()
        }
        self.usages = selected
    }

    private init(modifiers: UInt8, usages: [UInt8], overflowed: Bool) {
        self.modifiers = modifiers
        self.usages = usages
        self.overflowed = overflowed
    }

    func insertingModifiers(_ additionalModifiers: UInt8) -> KeyboardReport {
        KeyboardReport(
            modifiers: modifiers | additionalModifiers,
            usages: usages,
            overflowed: overflowed
        )
    }

    func insertingPrioritizedUsage(_ usage: UInt8) -> KeyboardReport {
        let updated = KeyboardReport(
            modifiers: modifiers,
            usages: usages + [usage],
            prioritizing: usage
        )
        guard overflowed, !updated.overflowed else { return updated }
        return KeyboardReport(
            modifiers: updated.modifiers,
            usages: updated.usages,
            overflowed: true
        )
    }

    var isReleased: Bool {
        modifiers == 0 && usages.isEmpty
    }

    var payload: Data {
        var data = Data(capacity: 8)
        data.append(modifiers)
        data.append(UInt8(usages.count))
        data.append(contentsOf: usages)
        data.append(contentsOf: repeatElement(0, count: Self.maximumUsages - usages.count))
        return data
    }
}

struct HIDKeyboardState: Equatable, Sendable {
    private(set) var modifiers: UInt8 = 0
    private(set) var usages: Set<UInt8> = []

    var report: KeyboardReport {
        KeyboardReport(modifiers: modifiers, usages: usages)
    }

    @discardableResult
    mutating func setModifiers(_ value: UInt8) -> Bool {
        guard modifiers != value else { return false }
        modifiers = value
        return true
    }

    @discardableResult
    mutating func setUsage(_ usage: UInt8, pressed: Bool) -> Bool {
        guard usage >= 0x04 && usage < 0xE0 else { return false }
        if pressed {
            return usages.insert(usage).inserted
        }
        return usages.remove(usage) != nil
    }

    func capsLockReports() -> [KeyboardReport] {
        var pressed = usages
        pressed.insert(MacKeyboardMapping.capsLockUsage)
        return [
            KeyboardReport(modifiers: modifiers, usages: pressed),
            report,
        ]
    }

    @discardableResult
    mutating func releaseAll() -> Bool {
        let changed = modifiers != 0 || !usages.isEmpty
        modifiers = 0
        usages.removeAll(keepingCapacity: true)
        return changed
    }
}

enum MacKeyboardMapping {
    static let capsLockKeyCode: UInt16 = 57
    static let capsLockUsage: UInt8 = 0x39

    static func usage(forKeyCode keyCode: UInt16) -> UInt8? {
        switch keyCode {
        case 0: return 0x04 // A
        case 11: return 0x05 // B
        case 8: return 0x06 // C
        case 2: return 0x07 // D
        case 14: return 0x08 // E
        case 3: return 0x09 // F
        case 5: return 0x0A // G
        case 4: return 0x0B // H
        case 34: return 0x0C // I
        case 38: return 0x0D // J
        case 40: return 0x0E // K
        case 37: return 0x0F // L
        case 46: return 0x10 // M
        case 45: return 0x11 // N
        case 31: return 0x12 // O
        case 35: return 0x13 // P
        case 12: return 0x14 // Q
        case 15: return 0x15 // R
        case 1: return 0x16 // S
        case 17: return 0x17 // T
        case 32: return 0x18 // U
        case 9: return 0x19 // V
        case 13: return 0x1A // W
        case 7: return 0x1B // X
        case 16: return 0x1C // Y
        case 6: return 0x1D // Z
        case 18: return 0x1E // 1
        case 19: return 0x1F // 2
        case 20: return 0x20 // 3
        case 21: return 0x21 // 4
        case 23: return 0x22 // 5
        case 22: return 0x23 // 6
        case 26: return 0x24 // 7
        case 28: return 0x25 // 8
        case 25: return 0x26 // 9
        case 29: return 0x27 // 0
        case 36: return 0x28 // Return
        case 53: return 0x29 // Escape
        case 51: return 0x2A // Backspace
        case 48: return 0x2B // Tab
        case 49: return 0x2C // Space
        case 27: return 0x2D // Minus
        case 24: return 0x2E // Equal
        case 33: return 0x2F // Left bracket
        case 30: return 0x30 // Right bracket
        case 42: return 0x31 // Backslash
        case 41: return 0x33 // Semicolon
        case 39: return 0x34 // Quote
        case 50: return 0x35 // Grave accent
        case 43: return 0x36 // Comma
        case 47: return 0x37 // Period
        case 44: return 0x38 // Slash
        case 10: return 0x64 // Non-US backslash
        case 122: return 0x3A // F1
        case 120: return 0x3B // F2
        case 99: return 0x3C // F3
        case 118: return 0x3D // F4
        case 96: return 0x3E // F5
        case 97: return 0x3F // F6
        case 98: return 0x40 // F7
        case 100: return 0x41 // F8
        case 101: return 0x42 // F9
        case 109: return 0x43 // F10
        case 103: return 0x44 // F11
        case 111: return 0x45 // F12
        case 105: return 0x68 // F13
        case 107: return 0x69 // F14
        case 113: return 0x6A // F15
        case 106: return 0x6B // F16
        case 64: return 0x6C // F17
        case 79: return 0x6D // F18
        case 80: return 0x6E // F19
        case 90: return 0x6F // F20
        case 114: return 0x49 // Help / Insert
        case 115: return 0x4A // Home
        case 116: return 0x4B // Page Up
        case 117: return 0x4C // Forward Delete
        case 119: return 0x4D // End
        case 121: return 0x4E // Page Down
        case 124: return 0x4F // Right arrow
        case 123: return 0x50 // Left arrow
        case 125: return 0x51 // Down arrow
        case 126: return 0x52 // Up arrow
        case 71: return 0x53 // Keypad Clear / Num Lock
        case 75: return 0x54 // Keypad Divide
        case 67: return 0x55 // Keypad Multiply
        case 78: return 0x56 // Keypad Minus
        case 69: return 0x57 // Keypad Plus
        case 76: return 0x58 // Keypad Enter
        case 83: return 0x59 // Keypad 1
        case 84: return 0x5A // Keypad 2
        case 85: return 0x5B // Keypad 3
        case 86: return 0x5C // Keypad 4
        case 87: return 0x5D // Keypad 5
        case 88: return 0x5E // Keypad 6
        case 89: return 0x5F // Keypad 7
        case 91: return 0x60 // Keypad 8
        case 92: return 0x61 // Keypad 9
        case 82: return 0x62 // Keypad 0
        case 65: return 0x63 // Keypad Decimal
        case 81: return 0x67 // Keypad Equal
        default: return nil
        }
    }

    static func usage(forSpecialFunctionKey scalar: UInt32?) -> UInt8? {
        switch scalar {
        case 0xF718: return 0x70 // F21
        case 0xF719: return 0x71 // F22
        case 0xF71A: return 0x72 // F23
        case 0xF71B: return 0x73 // F24
        default: return nil
        }
    }

    static func windowsModifiers(
        previous: UInt8,
        changedKeyCode: UInt16?,
        eventFlags: UInt64
    ) -> UInt8 {
        var result = previous
        updateModifierFamily(
            result: &result,
            eventFlags: eventFlags,
            changedKeyCode: changedKeyCode,
            macFlag: 0x0010_0000,
            leftDeviceFlag: 0x0000_0008,
            rightDeviceFlag: 0x0000_0010,
            leftKeyCode: 55,
            rightKeyCode: 54,
            leftWindowsBit: 0,
            rightWindowsBit: 4
        )
        updateModifierFamily(
            result: &result,
            eventFlags: eventFlags,
            changedKeyCode: changedKeyCode,
            macFlag: 0x0002_0000,
            leftDeviceFlag: 0x0000_0002,
            rightDeviceFlag: 0x0000_0004,
            leftKeyCode: 56,
            rightKeyCode: 60,
            leftWindowsBit: 1,
            rightWindowsBit: 5
        )
        updateModifierFamily(
            result: &result,
            eventFlags: eventFlags,
            changedKeyCode: changedKeyCode,
            macFlag: 0x0008_0000,
            leftDeviceFlag: 0x0000_0020,
            rightDeviceFlag: 0x0000_0040,
            leftKeyCode: 58,
            rightKeyCode: 61,
            leftWindowsBit: 2,
            rightWindowsBit: 6
        )
        updateModifierFamily(
            result: &result,
            eventFlags: eventFlags,
            changedKeyCode: changedKeyCode,
            macFlag: 0x0004_0000,
            leftDeviceFlag: 0x0000_0001,
            rightDeviceFlag: 0x0000_2000,
            leftKeyCode: 59,
            rightKeyCode: 62,
            leftWindowsBit: 3,
            rightWindowsBit: 7
        )
        return result
    }

    private static func updateModifierFamily(
        result: inout UInt8,
        eventFlags: UInt64,
        changedKeyCode: UInt16?,
        macFlag: UInt64,
        leftDeviceFlag: UInt64,
        rightDeviceFlag: UInt64,
        leftKeyCode: UInt16,
        rightKeyCode: UInt16,
        leftWindowsBit: UInt8,
        rightWindowsBit: UInt8
    ) {
        let leftMask = UInt8(1 << leftWindowsBit)
        let rightMask = UInt8(1 << rightWindowsBit)
        let familyMask = leftMask | rightMask
        let deviceFlags = eventFlags & (leftDeviceFlag | rightDeviceFlag)
        if deviceFlags != 0 {
            result &= ~familyMask
            if deviceFlags & leftDeviceFlag != 0 { result |= leftMask }
            if deviceFlags & rightDeviceFlag != 0 { result |= rightMask }
            return
        }
        guard eventFlags & macFlag != 0 else {
            result &= ~familyMask
            return
        }
        let changedMask: UInt8?
        if changedKeyCode == leftKeyCode {
            changedMask = leftMask
        } else if changedKeyCode == rightKeyCode {
            changedMask = rightMask
        } else {
            changedMask = nil
        }
        if let changedMask {
            result ^= changedMask
        } else if result & familyMask == 0 {
            result |= leftMask
        }
    }
}
