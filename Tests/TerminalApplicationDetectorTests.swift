import AppKit
import XCTest

final class TerminalApplicationDetectorTests: XCTestCase {
    func testDetectsSystemTerminalAsFirstChoice() {
        let terminals = TerminalApplicationDetector.detect()

        XCTAssertEqual(
            terminals.first?.bundleIdentifier,
            FinderContextMenuPreferences.systemTerminalBundleIdentifier
        )
    }

    func testDetectsInstalledITerm() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil else {
            throw XCTSkip("iTerm is not installed")
        }

        XCTAssertTrue(
            TerminalApplicationDetector.detect().contains {
                $0.bundleIdentifier == "com.googlecode.iterm2"
            }
        )
    }
}
