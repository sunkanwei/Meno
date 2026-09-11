import Carbon.HIToolbox

@MainActor
final class LidFoldEscape {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onEscape: () -> Void
    private static let signature: OSType = 0x4D464C44

    init(onEscape: @escaping () -> Void) { self.onEscape = onEscape }

    func register() -> Bool {
        if hotKey != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4D464C44, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                Unmanaged<LidFoldEscape>.fromOpaque(context).takeUnretainedValue().onEscape()
            }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        guard RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(),
                                  OptionBits(kEventHotKeyExclusive), &hotKey) == noErr else {
            stop(); return false
        }
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }
}
