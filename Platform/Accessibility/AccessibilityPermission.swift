@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics

enum AccessibilityPermission {
    static var canReadAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var canPostEvents: Bool {
        CGPreflightPostEventAccess()
    }

    static var canReadAndPostEvents: Bool {
        canReadAccessibility && canPostEvents
    }

    static var canListenToKeyboard: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestReadAndPostEvents() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestPostEventAccess()
    }

    static func requestKeyboardListening() {
        guard !CGRequestListenEventAccess() else { return }
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        ) else { return }
        _ = NSWorkspace.shared.open(settingsURL)
    }
}
