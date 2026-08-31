import CoreGraphics
import XCTest

final class MouseVoiceShortcutTests: XCTestCase {
    private func observeRightAlt(_ state: inout MouseVoiceShortcut, pressed: Bool) {
        state.observePhysicalModifiers(
            type: .flagsChanged,
            keyCode: Int64(MouseVoiceShortcut.rightAltKeyCode),
            flags: pressed ? [.maskAlternate, MouseVoiceShortcut.rightAltFlag] : []
        )
    }

    private func press(
        _ state: inout MouseVoiceShortcut,
        local: Bool = true,
        physicalAlt: Bool = false,
        button: Int64 = 3
    ) -> MouseVoiceShortcut.Result {
        observeRightAlt(&state, pressed: physicalAlt)
        return state.handle(
            type: .otherMouseDown, buttonNumber: button,
            isLocal: local
        )
    }

    private func release(
        _ state: inout MouseVoiceShortcut,
        local: Bool = true,
        physicalAlt: Bool = false
    ) -> MouseVoiceShortcut.Result {
        observeRightAlt(&state, pressed: physicalAlt)
        return state.handle(
            type: .otherMouseUp, buttonNumber: 3,
            isLocal: local
        )
    }

    func testHoldProducesOnePressAndOneReleaseWithoutRepeating() {
        var state = MouseVoiceShortcut(enabled: true)
        XCTAssertEqual(press(&state), .init(consume: true, keyDown: true))
        XCTAssertEqual(press(&state), .init(consume: true))
        XCTAssertEqual(state.handle(
            type: .mouseMoved, buttonNumber: 0, isLocal: true
        ), .init())
        XCTAssertTrue(state.active)
        XCTAssertEqual(release(&state), .init(consume: true, keyDown: false))
        XCTAssertFalse(state.active)
        XCTAssertEqual(release(&state), .init())
    }

    func testDisabledRemoteAndOtherButtonPassThrough() {
        var state = MouseVoiceShortcut()
        XCTAssertEqual(press(&state), .init())
        state.enabled = true
        XCTAssertEqual(press(&state, local: false), .init())
        XCTAssertEqual(release(&state), .init())
        XCTAssertEqual(press(&state, button: 4), .init())
        XCTAssertFalse(state.active)
    }

    func testCancellationReleasesOnceAndSwallowsThePendingMouseUp() {
        var state = MouseVoiceShortcut(enabled: true)
        _ = press(&state)
        XCTAssertEqual(state.cancel(), false)
        XCTAssertNil(state.cancel())
        state.enabled = false
        XCTAssertTrue(state.requiresInputTap)
        XCTAssertEqual(press(&state), .init(consume: true))
        XCTAssertEqual(release(&state, local: false), .init(consume: true))
        XCTAssertFalse(state.requiresInputTap)
        state.enabled = true
        XCTAssertEqual(press(&state), .init(consume: true, keyDown: true))
    }

    func testPhysicalRightAltCanOutliveMouseAndMouseCanOutlivePhysicalAlt() {
        var state = MouseVoiceShortcut(enabled: true)
        _ = press(&state)
        XCTAssertEqual(release(&state, physicalAlt: true), .init(consume: true))
        XCTAssertEqual(press(&state, physicalAlt: true), .init(consume: true))
        XCTAssertEqual(release(&state, physicalAlt: false), .init(consume: true, keyDown: false))
    }

    func testTapRestartDoesNotRetriggerAHeldButtonOrKeepAStalePress() {
        var state = MouseVoiceShortcut(enabled: true)
        _ = press(&state)
        _ = state.cancel()
        state.synchronizeButton(isDown: false)
        XCTAssertEqual(press(&state), .init(consume: true, keyDown: true))
        _ = state.cancel()
        state.synchronizeButton(isDown: true)
        XCTAssertEqual(press(&state), .init(consume: true))
        XCTAssertEqual(release(&state), .init(consume: true))
    }

    func testStartupSynchronizationDoesNotLoseANewlyAcceptedPress() {
        var state = MouseVoiceShortcut(enabled: true)
        _ = press(&state)
        state.synchronizeButton(isDown: false)
        XCTAssertTrue(state.active)
        XCTAssertEqual(release(&state), .init(consume: true, keyDown: false))
        state.synchronizeButton(isDown: true)
        XCTAssertEqual(release(&state), .init())
    }

    func testIdleEventsRepairPhysicalAltStateMissedDuringListenerInterruption() {
        var state = MouseVoiceShortcut(enabled: true)
        observeRightAlt(&state, pressed: true)
        // The physical release happened while the listener was unavailable.
        state.observePhysicalModifiers(type: .otherMouseDown, keyCode: 0, flags: [])
        XCTAssertFalse(state.physicalRightAltDown)
        XCTAssertEqual(state.handle(type: .otherMouseDown, buttonNumber: 3, isLocal: true),
                       .init(consume: true, keyDown: true))
        XCTAssertEqual(state.handle(type: .otherMouseUp, buttonNumber: 3, isLocal: true),
                       .init(consume: true, keyDown: false))

        // The reverse gap must not release a physically held key.
        state.observePhysicalModifiers(type: .otherMouseDown, keyCode: 0,
                                       flags: [.maskAlternate, MouseVoiceShortcut.rightAltFlag])
        XCTAssertEqual(state.handle(type: .otherMouseDown, buttonNumber: 3, isLocal: true),
                       .init(consume: true))
        XCTAssertNil(state.cancel())
    }

    func testMouseHeldFlagsDoNotBecomePhysicalAltOwnership() {
        var state = MouseVoiceShortcut(enabled: true)
        _ = press(&state)
        state.observePhysicalModifiers(type: .mouseMoved, keyCode: 0,
                                       flags: [.maskAlternate, MouseVoiceShortcut.rightAltFlag])
        XCTAssertFalse(state.physicalRightAltDown)
        observeRightAlt(&state, pressed: true)
        state.observePhysicalModifiers(type: .flagsChanged, keyCode: 56, flags: [.maskShift])
        XCTAssertTrue(state.physicalRightAltDown)
        observeRightAlt(&state, pressed: false)
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.cancel(), false)
    }

    func testSuspensionCancelsAndBlocksNewPressesUntilSessionResumes() {
        var state = MouseVoiceShortcut(enabled: true)
        _ = press(&state)
        XCTAssertEqual(state.setSystemAvailable(false), false)
        XCTAssertNil(state.setSystemAvailable(false))
        XCTAssertEqual(release(&state), .init(consume: true))
        XCTAssertEqual(press(&state), .init())
        state.enabled = false
        state.enabled = true
        XCTAssertEqual(press(&state), .init())
        XCTAssertNil(state.setSystemAvailable(true))
        // Do not claim a release whose press occurred during suspension.
        XCTAssertEqual(release(&state), .init())
        XCTAssertEqual(press(&state), .init(consume: true, keyDown: true))
        XCTAssertEqual(state.setSystemAvailable(false), false)
        XCTAssertNil(state.setSystemAvailable(true))
        state.synchronizeButton(isDown: false)
        XCTAssertEqual(press(&state), .init(consume: true, keyDown: true))
    }

    func testEventsDistinguishRightAltAndPreserveOtherPhysicalModifiers() throws {
        let physical: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, MouseVoiceShortcut.leftAltFlag]
        let down = try XCTUnwrap(MouseVoiceShortcut.makeKeyEvent(isDown: true, physicalFlags: physical))
        XCTAssertEqual(down.type, .flagsChanged)
        XCTAssertEqual(down.getIntegerValueField(.keyboardEventKeycode), 61)
        XCTAssertEqual(down.getIntegerValueField(.eventSourceUserData), MouseVoiceShortcut.eventMarker)
        XCTAssertTrue(down.flags.contains(MouseVoiceShortcut.rightAltFlag))
        XCTAssertTrue(down.flags.isSuperset(of: physical))
        let up = try XCTUnwrap(MouseVoiceShortcut.makeKeyEvent(isDown: false, physicalFlags: physical))
        XCTAssertEqual(up.type, .flagsChanged)
        XCTAssertEqual(up.flags, physical)
        XCTAssertEqual(MouseVoiceShortcut.flags([.maskAlternate, MouseVoiceShortcut.rightAltFlag], rightAltDown: false), [])
        XCTAssertTrue(MouseVoiceShortcut.flags([], rightAltDown: true).contains(.maskAlternate))
    }
}
