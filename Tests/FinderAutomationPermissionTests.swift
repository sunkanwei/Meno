import CoreServices
import XCTest

final class FinderAutomationPermissionTests: XCTestCase {
    func testMapsAppleEventPermissionResults() {
        XCTAssertEqual(FinderAutomationPermission.status(for: noErr), .allowed)
        XCTAssertEqual(
            FinderAutomationPermission.status(for: OSStatus(errAEEventWouldRequireUserConsent)),
            .notDetermined
        )
        XCTAssertEqual(
            FinderAutomationPermission.status(for: OSStatus(errAEEventNotPermitted)),
            .denied
        )
        XCTAssertEqual(
            FinderAutomationPermission.status(for: OSStatus(procNotFound)),
            .finderUnavailable
        )
        XCTAssertEqual(
            FinderAutomationPermission.status(for: OSStatus.max),
            .unavailable
        )
    }
}
