import CoreGraphics

enum FinderCommandSender {
    static let generatedEventMarker: Int64 = 0x4D_45_4E_4F

    private static let cKeyCode: CGKeyCode = 0x08

    static func postCopy(to finderPID: Int32) -> Bool {
        guard CGPreflightPostEventAccess(),
              let keyDown = keyboardEvent(
                  keyCode: cKeyCode,
                  isDown: true,
                  flags: [.maskCommand]
              ),
              let keyUp = keyboardEvent(
                  keyCode: cKeyCode,
                  isDown: false,
                  flags: [.maskCommand]
              ) else {
            return false
        }

        keyDown.postToPid(finderPID)
        keyUp.postToPid(finderPID)
        return true
    }

    static func replace(
        _ event: CGEvent,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> CGEvent {
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        event.flags = flags
        return event
    }

    private static func keyboardEvent(
        keyCode: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags
    ) -> CGEvent? {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
            return nil
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: generatedEventMarker)
        return event
    }
}
