import Foundation
import XCTest

final class CrossScreenKeyboardStateTests: XCTestCase {
    func testKeyboardReportUsesFixedEightBytePayload() {
        XCTAssertEqual(ClipboardMessageKind.keyboardState.rawValue, 14)
        XCTAssertEqual(
            [UInt8](KeyboardReport(modifiers: 1, usages: [0x04]).payload),
            [1, 1, 0x04, 0, 0, 0, 0, 0]
        )
    }

    func testMacKeyCodesMapToKeyboardUsages() {
        let expected: [UInt16: UInt8] = [
            0: 0x04, 6: 0x1D, 18: 0x1E, 29: 0x27,
            49: 0x2C, 36: 0x28, 48: 0x2B, 53: 0x29, 51: 0x2A,
            27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31,
            41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38,
            122: 0x3A, 103: 0x44, 111: 0x45, 105: 0x68, 90: 0x6F,
            114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C,
            119: 0x4D, 121: 0x4E, 123: 0x50, 124: 0x4F,
            125: 0x51, 126: 0x52,
            82: 0x62, 83: 0x59, 92: 0x61, 65: 0x63,
            67: 0x55, 69: 0x57, 75: 0x54, 76: 0x58, 78: 0x56,
        ]

        for (keyCode, usage) in expected {
            XCTAssertEqual(MacKeyboardMapping.usage(forKeyCode: keyCode), usage)
        }
        XCTAssertNil(MacKeyboardMapping.usage(forKeyCode: 63))
    }

    func testInjectedRightShiftF11ProducesStandardWindowsPayload() throws {
        let modifiers = MacKeyboardMapping.windowsModifiers(
            previous: 0,
            changedKeyCode: nil,
            eventFlags: 0x0000_0004
        )
        let usage = try XCTUnwrap(MacKeyboardMapping.usage(forKeyCode: 103))
        var state = HIDKeyboardState()

        XCTAssertEqual(modifiers, 1 << 5)
        XCTAssertEqual(usage, 0x44)
        XCTAssertTrue(state.setModifiers(modifiers))
        XCTAssertTrue(state.setUsage(usage, pressed: true))
        XCTAssertEqual(
            [UInt8](state.report.payload),
            [0x20, 1, 0x44, 0, 0, 0, 0, 0]
        )

        XCTAssertTrue(state.setUsage(usage, pressed: false))
        XCTAssertEqual(
            [UInt8](state.report.payload),
            [0x20, 0, 0, 0, 0, 0, 0, 0]
        )
        XCTAssertTrue(state.setModifiers(0))
        XCTAssertEqual(state.report, .released)
    }

    func testPhysicalRightAltProducesStandardPayloadAndReleasesImmediately() {
        let modifiers = MacKeyboardMapping.windowsModifiers(
            previous: 0,
            changedKeyCode: 61,
            eventFlags: 0x0008_0000 | 0x0000_0040
        )
        var state = HIDKeyboardState()

        XCTAssertEqual(modifiers, 1 << 6)
        XCTAssertTrue(state.setModifiers(modifiers))
        XCTAssertEqual(
            [UInt8](state.report.payload),
            [0x40, 0, 0, 0, 0, 0, 0, 0]
        )

        let releasedModifiers = MacKeyboardMapping.windowsModifiers(
            previous: modifiers,
            changedKeyCode: 61,
            eventFlags: 0
        )
        XCTAssertEqual(releasedModifiers, 0)
        XCTAssertTrue(state.setModifiers(releasedModifiers))
        XCTAssertEqual(state.report, .released)
    }

    func testF21ThroughF24SpecialKeysMapToKeyboardUsages() {
        XCTAssertEqual(MacKeyboardMapping.usage(forSpecialFunctionKey: 0xF718), 0x70)
        XCTAssertEqual(MacKeyboardMapping.usage(forSpecialFunctionKey: 0xF719), 0x71)
        XCTAssertEqual(MacKeyboardMapping.usage(forSpecialFunctionKey: 0xF71A), 0x72)
        XCTAssertEqual(MacKeyboardMapping.usage(forSpecialFunctionKey: 0xF71B), 0x73)
    }

    func testMacModifierSidesPreserveExternalKeyboardMeaningOnWindows() {
        let rawFlags: UInt64 = 0x0000_0008
            | 0x0000_0002
            | 0x0000_0020
            | 0x0000_0001
            | 0x0000_0010
            | 0x0000_0004
            | 0x0000_0040
            | 0x0000_2000

        XCTAssertEqual(
            MacKeyboardMapping.windowsModifiers(
                previous: 0,
                changedKeyCode: nil,
                eventFlags: rawFlags
            ),
            0xFF
        )
        XCTAssertEqual(
            MacKeyboardMapping.windowsModifiers(
                previous: 0,
                changedKeyCode: nil,
                eventFlags: 0x0000_0008
            ),
            1 << 0
        )
        XCTAssertEqual(
            MacKeyboardMapping.windowsModifiers(
                previous: 0,
                changedKeyCode: nil,
                eventFlags: 0x0000_0010
            ),
            1 << 4
        )
        XCTAssertEqual(
            MacKeyboardMapping.windowsModifiers(
                previous: 0,
                changedKeyCode: nil,
                eventFlags: 0x0000_0001
            ),
            1 << 3
        )
        XCTAssertEqual(
            MacKeyboardMapping.windowsModifiers(
                previous: 0,
                changedKeyCode: nil,
                eventFlags: 0x0000_2000
            ),
            1 << 7
        )

        let leftCommandDown = MacKeyboardMapping.windowsModifiers(
            previous: 0,
            changedKeyCode: 55,
            eventFlags: 0x0010_0000
        )
        let bothCommandsDown = MacKeyboardMapping.windowsModifiers(
            previous: leftCommandDown,
            changedKeyCode: 54,
            eventFlags: 0x0010_0000
        )
        let leftCommandUp = MacKeyboardMapping.windowsModifiers(
            previous: bothCommandsDown,
            changedKeyCode: 55,
            eventFlags: 0x0010_0000
        )

        XCTAssertEqual(leftCommandDown, 1 << 0)
        XCTAssertEqual(bothCommandsDown, (1 << 0) | (1 << 4))
        XCTAssertEqual(leftCommandUp, 1 << 4)

        let leftControlDown = MacKeyboardMapping.windowsModifiers(
            previous: 0,
            changedKeyCode: 59,
            eventFlags: 0x0004_0000
        )
        let bothControlsDown = MacKeyboardMapping.windowsModifiers(
            previous: leftControlDown,
            changedKeyCode: 62,
            eventFlags: 0x0004_0000
        )
        let leftControlUp = MacKeyboardMapping.windowsModifiers(
            previous: bothControlsDown,
            changedKeyCode: 59,
            eventFlags: 0x0004_0000
        )

        XCTAssertEqual(leftControlDown, 1 << 3)
        XCTAssertEqual(bothControlsDown, (1 << 3) | (1 << 7))
        XCTAssertEqual(leftControlUp, 1 << 7)
    }

    func testSystemSwappedExternalCtrlAndWinPreserveWindowsKeycapMeaning() {
        let ctrlModifiers = MacKeyboardMapping.windowsModifiers(
            previous: 0,
            changedKeyCode: nil,
            eventFlags: 0x0000_0008
        )
        let winModifiers = MacKeyboardMapping.windowsModifiers(
            previous: 0,
            changedKeyCode: nil,
            eventFlags: 0x0000_0001
        )

        XCTAssertEqual(
            [UInt8](KeyboardReport(modifiers: ctrlModifiers, usages: [0x06]).payload),
            [0x01, 1, 0x06, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(
            [UInt8](KeyboardReport(modifiers: winModifiers, usages: [0x06]).payload),
            [0x08, 1, 0x06, 0, 0, 0, 0, 0]
        )
    }

    func testPayloadIsEightBytesSortedDeduplicatedAndZeroFilled() {
        let report = KeyboardReport(
            modifiers: 0x12,
            usages: [0x1D, 0x04, 0x1D, 0x00, 0xE0, 0x06]
        )

        XCTAssertEqual(
            [UInt8](report.payload),
            [0x12, 3, 0x04, 0x06, 0x1D, 0, 0, 0]
        )
    }

    func testMoreThanSixKeysUsesStableFirstSixWithoutRollover() {
        let report = KeyboardReport(
            modifiers: 0,
            usages: [0x0A, 0x04, 0x09, 0x08, 0x07, 0x06, 0x05]
        )

        XCTAssertTrue(report.overflowed)
        XCTAssertEqual(report.usages, [0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        XCTAssertFalse(report.usages.contains(0x01))
    }

    func testReleaseAllClearsOrdinaryAndModifierState() {
        var state = HIDKeyboardState()
        XCTAssertTrue(state.setModifiers(0x81))
        XCTAssertTrue(state.setUsage(0x04, pressed: true))

        XCTAssertTrue(state.releaseAll())
        XCTAssertEqual(state.report, .released)
        XCTAssertEqual([UInt8](state.report.payload), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(state.releaseAll())
    }

    func testCapsLockProducesPressThenReleaseWithoutBeingRetained() {
        var state = HIDKeyboardState()
        _ = state.setUsage(0x04, pressed: true)

        let reports = state.capsLockReports()

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].usages, [0x04, 0x39])
        XCTAssertEqual(reports[1].usages, [0x04])
        XCTAssertEqual(state.report.usages, [0x04])
    }

}
