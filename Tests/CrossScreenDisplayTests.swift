import XCTest

final class CrossScreenDisplayTests: XCTestCase {
    func testUsesCalibratedActiveHeightForViewSonicVP2768a() {
        XCTAssertEqual(
            CrossScreenDisplayCalibration.physicalHeightMM(
                reportedHeightMM: 350.4,
                displayBoundsHeight: 2_160,
                vendorID: 0x5a63,
                modelID: 0xae3b
            ),
            335.664
        )
    }

    func testUsesCalibratedActiveHeightForPhilips27E1N5800E() {
        XCTAssertEqual(
            CrossScreenDisplayCalibration.physicalHeightMM(
                reportedHeightMM: 340,
                displayBoundsHeight: 2_160,
                vendorID: FixedDisplayConfiguration.philipsVendorID,
                modelID: FixedDisplayConfiguration.philipsModelID
            ),
            FixedDisplayConfiguration.philipsActiveHeightMM
        )
    }

    func testUsesValidSystemReportedHeightForOtherDisplays() {
        XCTAssertEqual(
            CrossScreenDisplayCalibration.physicalHeightMM(
                reportedHeightMM: 222.5,
                displayBoundsHeight: 2_234,
                vendorID: 0x610,
                modelID: 0xa0
            ),
            222.5
        )
    }

    func testRejectsInvalidSystemReportedHeight() {
        for invalidHeight in [CGFloat(0), -1, .infinity, .nan] {
            XCTAssertNil(CrossScreenDisplayCalibration.physicalHeightMM(
                reportedHeightMM: invalidHeight,
                displayBoundsHeight: 1_000,
                vendorID: 0,
                modelID: 0
            ))
        }
    }

    func testRejectsImplausibleAndLikely72DPIFallbackHeights() {
        XCTAssertNil(CrossScreenDisplayCalibration.physicalHeightMM(
            reportedHeightMM: 20,
            displayBoundsHeight: 1_000,
            vendorID: 0,
            modelID: 0
        ))
        let displayBoundsHeight: CGFloat = 2_160
        XCTAssertNil(CrossScreenDisplayCalibration.physicalHeightMM(
            reportedHeightMM: displayBoundsHeight * 25.4 / 72,
            displayBoundsHeight: displayBoundsHeight,
            vendorID: 0,
            modelID: 0
        ))
    }
}
