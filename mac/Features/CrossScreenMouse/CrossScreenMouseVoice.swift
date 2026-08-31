import CoreGraphics

extension CrossScreenMouseController {
    @MainActor
    func setMouseVoiceShortcutEnabled(_ enabled: Bool) {
        let permitted = AccessibilityPermission.canReadAndPostEvents
            && AccessibilityPermission.canListenToKeyboard
        runtimeLock.withCriticalSection {
            mouseVoiceShortcutRequested = enabled
            if enabled && permitted && !state.mouseVoiceShortcut.enabled {
                synchronizeMouseVoiceInputLocked()
            }
            if !enabled || !permitted { cancelMouseVoiceShortcutLocked() }
            state.mouseVoiceShortcut.enabled = enabled && permitted
        }
        startTapIfNeeded()
    }

    @MainActor
    func setMouseVoiceSystemAvailable(_ available: Bool) {
        runtimeLock.withCriticalSection {
            if let isDown = state.mouseVoiceShortcut.setSystemAvailable(available) {
                postMouseVoiceKeyLocked(isDown: isDown)
            }
            if available { synchronizeMouseVoiceInputLocked() }
        }
        publishMouseVoiceShortcutStatus()
    }

    func synchronizeMouseVoiceInputLocked() {
        state.mouseVoiceShortcut.observePhysicalModifiers(
            type: .mouseMoved,
            keyCode: 0,
            flags: CGEventSource.flagsState(.hidSystemState)
        )
        state.mouseVoiceShortcut.synchronizeButton(isDown: CGEventSource.buttonState(
            .hidSystemState,
            button: CGMouseButton(rawValue: UInt32(MouseVoiceShortcut.buttonNumber))!
        ))
    }

    // Called with runtimeLock held; state transitions and event posting stay ordered.
    func handleMouseVoiceShortcutLocked(type: CGEventType, event: CGEvent) -> Bool {
        state.mouseVoiceShortcut.observePhysicalModifiers(
            type: type,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags
        )
        let isLocal: Bool
        if case .local = state.ownership.phase { isLocal = true } else { isLocal = false }
        if !isLocal { cancelMouseVoiceShortcutLocked() }
        let result = state.mouseVoiceShortcut.handle(
            type: type,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            isLocal: isLocal
        )
        if let isDown = result.keyDown { postMouseVoiceKeyLocked(isDown: isDown) }
        if result.consume, !state.mouseVoiceShortcut.requiresInputTap {
            Task { @MainActor [weak self] in
                self?.stopTapIfUnneededAndLocal()
            }
        }
        if state.mouseVoiceShortcut.active {
            // A physical modifier release must not release the mouse-held right Alt.
            event.flags = MouseVoiceShortcut.flags(event.flags, rightAltDown: true)
        }
        return result.consume
    }

    func cancelMouseVoiceShortcut() {
        runtimeLock.withCriticalSection { cancelMouseVoiceShortcutLocked() }
    }

    func cancelMouseVoiceShortcutLocked() {
        if let isDown = state.mouseVoiceShortcut.cancel() {
            postMouseVoiceKeyLocked(isDown: isDown)
        }
    }

    private func postMouseVoiceKeyLocked(isDown: Bool) {
        guard let event = MouseVoiceShortcut.makeKeyEvent(
            isDown: isDown,
            physicalFlags: CGEventSource.flagsState(.hidSystemState)
        ) else {
            _ = state.mouseVoiceShortcut.cancel()
            return
        }
        // Reach input-method HID listeners; the marker excludes our own two taps.
        event.post(tap: .cghidEventTap)
    }

    @MainActor
    func publishMouseVoiceShortcutStatus() {
        let configuration = runtimeLock.withCriticalSection {
            (mouseVoiceShortcutRequested, state.mouseVoiceShortcut.enabled, state.mouseVoiceShortcut.systemAvailable)
        }
        let status: MouseVoiceShortcutStatus = !configuration.0 ? .off
            : !configuration.1 ? .waitingForPermissions
            : !configuration.2 ? .suspended
            : inputTapsAreRunning ? .ready : .failed
        onMouseVoiceStatusChanged(status)
    }
}
