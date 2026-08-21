import Carbon.HIToolbox
import OSLog

@MainActor
final class SoftKVMHotKeyController {
    typealias PressHandler = () -> Void

    private static let hotKeyID = EventHotKeyID(signature: 0x4D4B564D, id: 1)
    private static let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "SoftKVM"
    )

    private let onPressed: PressHandler
    private var shortcut = SoftKVMShortcut.defaultValue
    private var enabled = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var keyboardFallbackReported = false

    /// Reports whether the global hotkey is unavailable while it should be
    /// active, so the event tap can keep its keyboard subscription as fallback.
    var onKeyboardFallbackNeededChanged: ((Bool) -> Void)?

    init(onPressed: @escaping PressHandler) {
        self.onPressed = onPressed
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        refreshRegistration()
    }

    func setShortcut(_ shortcut: SoftKVMShortcut) {
        guard shortcut.isValid, shortcut != self.shortcut else { return }
        self.shortcut = shortcut
        if enabled { refreshRegistration() }
    }

    func stopForApplicationExit() {
        enabled = false
        stopRegistration()
    }

    private func refreshRegistration() {
        stopRegistration()
        guard enabled else {
            reportKeyboardFallbackNeeded(false)
            return
        }
        guard installEventHandler() else {
            reportKeyboardFallbackNeeded(true)
            return
        }

        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers,
            Self.hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &registeredHotKey
        )
        guard status == noErr, let registeredHotKey else {
            Self.logger.error(
                "Soft KVM global hotkey registration failed status=\(status, privacy: .public)"
            )
            stopRegistration()
            reportKeyboardFallbackNeeded(true)
            return
        }
        hotKeyRef = registeredHotKey
        reportKeyboardFallbackNeeded(false)
        Self.logger.info("Soft KVM global hotkey registered")
    }

    private func reportKeyboardFallbackNeeded(_ needed: Bool) {
        guard keyboardFallbackReported != needed else { return }
        keyboardFallbackReported = needed
        onKeyboardFallbackNeededChanged?(needed)
    }

    private func installEventHandler() -> Bool {
        if eventHandlerRef != nil { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            userData,
            &installedHandler
        )
        guard status == noErr, let installedHandler else {
            Self.logger.error(
                "Soft KVM hotkey event handler installation failed status=\(status, privacy: .public)"
            )
            return false
        }
        eventHandlerRef = installedHandler
        return true
    }

    private func stopRegistration() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
    }

    private var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if shortcut.modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if shortcut.modifiers.contains(.control) { value |= UInt32(controlKey) }
        if shortcut.modifiers.contains(.option) { value |= UInt32(optionKey) }
        if shortcut.modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    private func handleHotKey(signature: OSType, id: UInt32) -> OSStatus {
        guard enabled,
              signature == Self.hotKeyID.signature,
              id == Self.hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }
        Self.logger.info("Soft KVM global hotkey received")
        onPressed()
        return noErr
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }

        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr else { return OSStatus(eventNotHandledErr) }

        let owner = Unmanaged<SoftKVMHotKeyController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        let signature = receivedID.signature
        let id = receivedID.id
        return MainActor.assumeIsolated {
            owner.handleHotKey(signature: signature, id: id)
        }
    }
}
