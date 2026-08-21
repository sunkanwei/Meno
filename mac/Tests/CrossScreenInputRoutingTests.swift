import CoreGraphics
import XCTest

final class CrossScreenInputRoutingTests: XCTestCase {
    private func bit(_ type: CGEventType) -> CGEventMask {
        CGEventMask(1 << type.rawValue)
    }

    private func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(0) { $0 | bit($1) }
    }

    func testInputTapKindsOwnTheirCompleteConfiguration() {
        XCTAssertEqual(CrossScreenInputTapKind.allCases.count, 2)
        XCTAssertEqual(CrossScreenInputTapKind.hidInput.tapLocation, .cghidEventTap)
        XCTAssertEqual(CrossScreenInputTapKind.sessionKeyboard.tapLocation, .cgSessionEventTap)
        XCTAssertFalse(CrossScreenInputTapKind.hidInput.threadName.isEmpty)
        XCTAssertFalse(CrossScreenInputTapKind.sessionKeyboard.threadName.isEmpty)
        XCTAssertNotEqual(
            CrossScreenInputTapKind.hidInput.threadName,
            CrossScreenInputTapKind.sessionKeyboard.threadName
        )
        XCTAssertFalse(CrossScreenInputTapKind.hidInput.listenerName.isEmpty)
        XCTAssertFalse(CrossScreenInputTapKind.sessionKeyboard.listenerName.isEmpty)
    }

    func testHIDListenerAlwaysSubscribesMouseWheelAndPhysicalKeyboard() {
        let expected = mask([
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ])

        XCTAssertEqual(CrossScreenInputTapKind.hidInput.eventMask, expected)
    }

    func testSessionListenerSubscribesKeyboardOnly() {
        XCTAssertEqual(
            CrossScreenInputTapKind.sessionKeyboard.eventMask,
            mask([.keyDown, .keyUp, .flagsChanged])
        )
    }

    func testKeyboardPassesLocallyAndIsHandledForRemoteOrFallbackInput() {
        XCTAssertFalse(
            CrossScreenInputRouting.shouldHandleKeyboard(
                capturesInput: false,
                localKeyboardCaptureRequired: false
            )
        )
        XCTAssertTrue(
            CrossScreenInputRouting.shouldHandleKeyboard(
                capturesInput: false,
                localKeyboardCaptureRequired: true
            )
        )
        XCTAssertTrue(
            CrossScreenInputRouting.shouldHandleKeyboard(
                capturesInput: true,
                localKeyboardCaptureRequired: false
            )
        )
        XCTAssertTrue(
            CrossScreenInputRouting.shouldHandleKeyboard(
                capturesInput: true,
                localKeyboardCaptureRequired: true
            )
        )
    }

    func testAutomationMarkedPointerEventsAreNotRouted() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))

        XCTAssertFalse(CrossScreenInputRouting.isAutomationMarkedPointerEvent(
            type: .mouseMoved,
            event: event
        ))

        event.setIntegerValueField(.eventSourceUserData, value: 0x54_48_41_57)

        for type in [
            CGEventType.mouseMoved,
            .leftMouseDown,
            .leftMouseUp,
            .leftMouseDragged,
        ] {
            XCTAssertTrue(CrossScreenInputRouting.isAutomationMarkedPointerEvent(
                type: type,
                event: event
            ))
        }
        XCTAssertFalse(CrossScreenInputRouting.isAutomationMarkedPointerEvent(
            type: .flagsChanged,
            event: event
        ))
        XCTAssertFalse(CrossScreenInputRouting.isAutomationMarkedPointerEvent(
            type: .scrollWheel,
            event: event
        ))

        let otherMarkedEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
        otherMarkedEvent.setIntegerValueField(.eventSourceUserData, value: 1)
        XCTAssertFalse(CrossScreenInputRouting.isAutomationMarkedPointerEvent(
            type: .mouseMoved,
            event: otherMarkedEvent
        ))
    }

    func testEmergencyReleaseUsesPhysicalCtrlAfterSystemModifierSwap() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: source,
            virtualKey: 53,
            keyDown: true
        ))

        event.flags = [.maskCommand, .maskAlternate]
        XCTAssertTrue(CrossScreenInputRouting.isEmergencyRelease(
            type: .keyDown,
            event: event
        ))

        event.flags = [.maskControl, .maskAlternate]
        XCTAssertFalse(CrossScreenInputRouting.isEmergencyRelease(
            type: .keyDown,
            event: event
        ))
        XCTAssertFalse(CrossScreenInputRouting.isEmergencyRelease(
            type: .keyUp,
            event: event
        ))
    }
}
