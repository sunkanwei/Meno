import XCTest

final class ScrollDirectionPolicyTests: XCTestCase {
    func testCompatibilityIsRestrictedToVerifiedMajorVersions() {
        XCTAssertTrue(ScrollDirectionCompatibility.supports(majorVersion: 26))
        XCTAssertTrue(ScrollDirectionCompatibility.supports(majorVersion: 27))
        XCTAssertFalse(ScrollDirectionCompatibility.supports(majorVersion: 25))
        XCTAssertFalse(ScrollDirectionCompatibility.supports(majorVersion: 28))
    }

    func testBuiltInTrackpadPreservesVerticalDirection() {
        XCTAssertEqual(
            ScrollDirectionPolicy.action(for: .builtInTrackpad),
            .preserve
        )
    }

    func testOtherDeviceReversesVerticalDirection() {
        XCTAssertEqual(
            ScrollDirectionPolicy.action(for: .otherDevice),
            .reverseVertical
        )
    }

    func testUnknownSourcePreservesSystemBehavior() {
        XCTAssertEqual(
            ScrollDirectionPolicy.action(for: .unknown),
            .preserve
        )
    }

    func testInternalTrackpadNameIsRecognizedWithoutVendorIdentifiers() {
        let source = ScrollInputSourceClassifier.classify(
            ScrollDeviceDescriptor(
                isBuiltIn: true,
                productName: "Apple Internal Keyboard / Trackpad"
            )
        )

        XCTAssertEqual(source, .builtInTrackpad)
    }

    func testExternalTrackpadCountsAsOtherDevice() {
        let source = ScrollInputSourceClassifier.classify(
            ScrollDeviceDescriptor(isBuiltIn: false, productName: "Magic Trackpad")
        )

        XCTAssertEqual(source, .otherDevice)
    }

    func testTrackpadWithoutBuiltInMetadataRemainsUnknown() {
        let source = ScrollInputSourceClassifier.classify(
            ScrollDeviceDescriptor(isBuiltIn: nil, productName: "Magic Trackpad")
        )

        XCTAssertEqual(source, .unknown)
    }

    func testResolvedMouseCountsAsOtherDevice() {
        let source = ScrollInputSourceClassifier.classify(
            ScrollDeviceDescriptor(isBuiltIn: false, productName: "USB Receiver")
        )

        XCTAssertEqual(source, .otherDevice)
    }

    func testMissingDevicePropertiesRemainUnknown() {
        let source = ScrollInputSourceClassifier.classify(
            ScrollDeviceDescriptor(isBuiltIn: nil, productName: nil)
        )

        XCTAssertEqual(source, .unknown)
    }

    func testBuiltInDeviceWithoutTrackpadIdentityRemainsUnknown() {
        let source = ScrollInputSourceClassifier.classify(
            ScrollDeviceDescriptor(isBuiltIn: true, productName: nil)
        )

        XCTAssertEqual(source, .unknown)
    }
}
