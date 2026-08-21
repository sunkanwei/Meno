import AppKit
@preconcurrency import CoreGraphics
import Foundation

struct SoftKVMModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let shift = Self(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(eventFlags: CGEventFlags) {
        var value: Self = []
        if eventFlags.contains(.maskCommand) { value.insert(.command) }
        if eventFlags.contains(.maskControl) { value.insert(.control) }
        if eventFlags.contains(.maskAlternate) { value.insert(.option) }
        if eventFlags.contains(.maskShift) { value.insert(.shift) }
        self = value
    }

    var titleParts: [String] {
        var values: [String] = []
        if contains(.command) { values.append("WIN") }
        if contains(.control) { values.append("Ctrl") }
        if contains(.option) { values.append("Alt") }
        if contains(.shift) { values.append("Shift") }
        return values
    }
}

struct SoftKVMShortcut: Codable, Equatable, Sendable {
    private static let f12KeyCode: UInt16 = 0x6F

    static let defaultValue = Self(
        keyCode: f12KeyCode,
        modifiers: [.shift],
        keyLabel: "F12"
    )

    private static let supersededDefaultValues = [
        Self(
            keyCode: 40,
            modifiers: [.command, .option, .shift],
            keyLabel: "K"
        ),
        Self(
            keyCode: 40,
            modifiers: [.control, .option, .shift],
            keyLabel: "K"
        )
    ]

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    let keyCode: UInt16
    let modifiers: SoftKVMModifiers
    let keyLabel: String

    var title: String {
        (modifiers.titleParts + [keyLabel]).joined(separator: " + ")
    }

    var isValid: Bool {
        let hasSafeModifiers = modifiers.rawValue.nonzeroBitCount >= 2
            || (keyCode == Self.f12KeyCode && modifiers == [.shift])
        return hasSafeModifiers
            && keyCode != 53
            && !Self.modifierKeyCodes.contains(keyCode)
            && !keyLabel.isEmpty
    }

    static func replacingSupersededDefault(_ storedValue: Self) -> Self {
        supersededDefaultValues.contains(storedValue) ? defaultValue : storedValue
    }

    func matches(type: CGEventType, event: CGEvent) -> Bool {
        type == .keyDown
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)) == keyCode
            && SoftKVMModifiers(eventFlags: event.flags) == modifiers
    }

    static func make(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, label: String?) -> Self? {
        var mapped: SoftKVMModifiers = []
        if modifiers.contains(.command) { mapped.insert(.command) }
        if modifiers.contains(.control) { mapped.insert(.control) }
        if modifiers.contains(.option) { mapped.insert(.option) }
        if modifiers.contains(.shift) { mapped.insert(.shift) }
        let shortcut = Self(
            keyCode: keyCode,
            modifiers: mapped,
            keyLabel: normalizedLabel(label, keyCode: keyCode)
        )
        return shortcut.isValid ? shortcut : nil
    }

    private static func normalizedLabel(_ value: String?, keyCode: UInt16) -> String {
        if keyCode == f12KeyCode { return "F12" }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return String(trimmed.prefix(1)).uppercased()
        }
        return "键码 \(keyCode)"
    }
}

enum SoftKVMShortcutEvent: Equatable {
    case none
    case trigger
    case swallow
}

struct SoftKVMShortcutCapture: Sendable {
    private var active = false
    private var triggerKeyDown = false

    mutating func handle(
        type: CGEventType,
        event: CGEvent,
        shortcut: SoftKVMShortcut
    ) -> SoftKVMShortcutEvent {
        guard Self.isKeyboardEvent(type) else { return .none }

        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        if active {
            if type == .keyUp, keyCode == shortcut.keyCode {
                triggerKeyDown = false
            }
            let relevantModifiers = SoftKVMModifiers(eventFlags: event.flags).intersection(
                shortcut.modifiers
            )
            if !triggerKeyDown, relevantModifiers.isEmpty {
                active = false
            }
            return .swallow
        }

        guard shortcut.matches(type: type, event: event) else { return .none }
        active = true
        triggerKeyDown = true
        return .trigger
    }

    mutating func reset() {
        active = false
        triggerKeyDown = false
    }

    private static func isKeyboardEvent(_ type: CGEventType) -> Bool {
        type == .keyDown || type == .keyUp || type == .flagsChanged
    }
}

enum SoftKVMInputQuiescence {
    static func wait(
        for shortcut: SoftKVMShortcut,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            let flags = SoftKVMModifiers(
                eventFlags: CGEventSource.flagsState(.combinedSessionState)
            )
            let keyDown = CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(shortcut.keyCode)
            )
            if flags.isEmpty, !keyDown, currentMouseButtonMask() == 0 {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return false
    }

    private static func currentMouseButtonMask() -> UInt64 {
        var mask: UInt64 = 0
        for button in 0..<32 {
            guard let mouseButton = CGMouseButton(rawValue: UInt32(button)) else { continue }
            if CGEventSource.buttonState(.combinedSessionState, button: mouseButton) {
                mask |= 1 << UInt64(button)
            }
        }
        return mask
    }
}
