import CoreGraphics
import XCTest

final class FinderDesktopCoordinateSpaceTests: XCTestCase {
    private let primaryScreen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    func testConvertsPointsAcrossMultipleScreenArrangements() throws {
        let screens = [
            primaryScreen,
            CGRect(x: 1_920, y: 0, width: 1_280, height: 1_024),
            CGRect(x: 0, y: 1_080, width: 1_280, height: 800),
            CGRect(x: -1_280, y: 0, width: 1_280, height: 1_024),
            CGRect(x: 0, y: -900, width: 1_440, height: 900)
        ]
        let cases = [
            (screenPoint: CGPoint(x: 400, y: 300), finderPosition: CGPoint(x: 400, y: 780)),
            (screenPoint: CGPoint(x: 2_400, y: 500), finderPosition: CGPoint(x: 2_400, y: 580)),
            (screenPoint: CGPoint(x: 600, y: 1_400), finderPosition: CGPoint(x: 600, y: -320)),
            (screenPoint: CGPoint(x: -600, y: 500), finderPosition: CGPoint(x: -600, y: 580)),
            (screenPoint: CGPoint(x: 500, y: -400), finderPosition: CGPoint(x: 500, y: 1_480))
        ]

        for testCase in cases {
            let finderPosition = try XCTUnwrap(
                FinderDesktopCoordinateSpace.finderPosition(
                    for: testCase.screenPoint,
                    primaryScreenFrame: primaryScreen,
                    screenFrames: screens
                )
            )
            XCTAssertEqual(finderPosition, testCase.finderPosition)
            XCTAssertTrue(
                FinderDesktopCoordinateSpace.containsFinderPosition(
                    finderPosition,
                    primaryScreenFrame: primaryScreen,
                    screenFrames: screens
                )
            )
        }
    }

    func testRejectsNonfiniteAndOffscreenCoordinates() {
        let screens = [primaryScreen]

        XCTAssertNil(
            FinderDesktopCoordinateSpace.finderPosition(
                for: CGPoint(x: CGFloat.infinity, y: 100),
                primaryScreenFrame: primaryScreen,
                screenFrames: screens
            )
        )
        XCTAssertNil(
            FinderDesktopCoordinateSpace.finderPosition(
                for: CGPoint(x: 3_000, y: 3_000),
                primaryScreenFrame: primaryScreen,
                screenFrames: screens
            )
        )
        XCTAssertFalse(
            FinderDesktopCoordinateSpace.containsFinderPosition(
                CGPoint(x: 3_000, y: 3_000),
                primaryScreenFrame: primaryScreen,
                screenFrames: screens
            )
        )
        XCTAssertFalse(
            FinderDesktopCoordinateSpace.containsFinderPosition(
                CGPoint(x: CGFloat.infinity, y: 100),
                primaryScreenFrame: primaryScreen,
                screenFrames: screens
            )
        )
        XCTAssertFalse(
            FinderDesktopCoordinateSpace.containsFinderPosition(
                CGPoint(x: primaryScreen.maxX, y: 100),
                primaryScreenFrame: primaryScreen,
                screenFrames: screens
            )
        )
    }
}
