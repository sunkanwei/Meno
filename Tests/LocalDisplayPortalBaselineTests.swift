import CoreGraphics
import Foundation
import XCTest

final class LocalDisplayPortalBaselineTests: XCTestCase {
    func testCapturesVerifiedNativeBaselineAndRoundTripsThroughStorage() throws {
        let displays = makeNativeDisplays()

        let baseline = try XCTUnwrap(
            LocalDisplayPortalBaseline.resolveNative(displays: displays)
        )
        let decoded = try JSONDecoder().decode(
            LocalDisplayPortalBaseline.self,
            from: JSONEncoder().encode(baseline)
        )

        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded, baseline)
        XCTAssertEqual(decoded.routingOrderIDs, [
            FixedDisplayConfiguration.philipsUUID,
            "internal",
            FixedDisplayConfiguration.viewSonicUUID,
        ])
    }

    func testSavedBaselineBuildsTwoScreenPortalWithoutInferringMissingDisplay() throws {
        let baseline = try XCTUnwrap(
            LocalDisplayPortalBaseline.resolveNative(displays: makeNativeDisplays())
        )
        let activeDisplays = Array(makeNativeDisplays().dropFirst())

        XCTAssertEqual(
            baseline.activeRoutingOrderIDs(for: activeDisplays),
            ["internal", FixedDisplayConfiguration.viewSonicUUID]
        )
        let placement = try XCTUnwrap(
            baseline.technicalPlacements(for: activeDisplays)?.only
        )
        XCTAssertEqual(placement.displayID, FixedDisplayConfiguration.viewSonicUUID)
        XCTAssertEqual(placement.runtimeID, 13)
        XCTAssertEqual(placement.x, 1_496)
        XCTAssertEqual(placement.y, -1_152)
    }

    func testTechnicalPlacementsBuildFullUShapedPortal() throws {
        let displays = makeNativeDisplays()
        let baseline = try XCTUnwrap(
            LocalDisplayPortalBaseline.resolveNative(displays: displays)
        )
        let placements = try XCTUnwrap(baseline.technicalPlacements(for: displays))
        let placementsByID = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.displayID, $0)
        })

        let left = try XCTUnwrap(
            placementsByID[FixedDisplayConfiguration.philipsUUID]
        )
        XCTAssertEqual(left.x, -2_048)
        XCTAssertEqual(left.y, -1_152)

        let right = try XCTUnwrap(
            placementsByID[FixedDisplayConfiguration.viewSonicUUID]
        )
        XCTAssertEqual(right.x, 1_496)
        XCTAssertEqual(right.y, -1_152)
    }

    func testSavedBaselineRestoresOnlyCurrentlyVisibleRegisteredDisplays() throws {
        let baseline = try XCTUnwrap(
            LocalDisplayPortalBaseline.resolveNative(displays: makeNativeDisplays())
        )
        let activeDisplays = Array(makeNativeDisplays().dropFirst()) + [
            display(id: "temporary", runtimeID: 99, x: 3_544, y: 0, width: 800, height: 600),
        ]

        let placement = try XCTUnwrap(
            baseline.originalPlacements(for: activeDisplays)?.only
        )

        XCTAssertEqual(placement.displayID, FixedDisplayConfiguration.viewSonicUUID)
        XCTAssertEqual(placement.x, 1_496)
        XCTAssertEqual(placement.y, -185)
    }

    func testPermanentRestoreRequiresVerifiedCompleteNativeLayout() throws {
        let nativeDisplays = makeNativeDisplays()
        let baseline = try XCTUnwrap(
            LocalDisplayPortalBaseline.resolveNative(displays: nativeDisplays)
        )
        let uShapedDisplays = nativeDisplays.map { display in
            guard !display.isMain else { return display }
            return self.display(
                id: display.id,
                runtimeID: display.runtimeID,
                x: display.frame.minX,
                y: -1_152,
                width: display.frame.width,
                height: display.frame.height
            )
        }

        let placements = try XCTUnwrap(
            baseline.permanentOriginalPlacements(for: uShapedDisplays)
        )

        XCTAssertEqual(placements.count, 2)
        XCTAssertNotNil(baseline.verifiedOriginalPlacements(
            for: Array(uShapedDisplays.dropFirst())
        ))
        XCTAssertNil(baseline.permanentOriginalPlacements(
            for: Array(uShapedDisplays.dropFirst())
        ))
        XCTAssertNil(baseline.permanentOriginalPlacements(
            for: uShapedDisplays + [
                display(
                    id: "temporary",
                    runtimeID: 99,
                    x: 3_544,
                    y: 0,
                    width: 800,
                    height: 600
                ),
            ]
        ))
    }

    func testPermanentRestoreRejectsCorruptedSavedGeometry() {
        let corrupted = LocalDisplayPortalBaseline(
            schemaVersion: 1,
            mainDisplayID: "internal",
            routingOrderIDs: [
                FixedDisplayConfiguration.philipsUUID,
                "internal",
                FixedDisplayConfiguration.viewSonicUUID,
            ],
            originalOrigins: [
                .init(
                    displayID: FixedDisplayConfiguration.philipsUUID,
                    x: -2_048,
                    y: -100
                ),
                .init(
                    displayID: FixedDisplayConfiguration.viewSonicUUID,
                    x: 1_496,
                    y: -185
                ),
            ]
        )

        XCTAssertTrue(corrupted.isValid)
        XCTAssertNil(corrupted.verifiedOriginalPlacements(
            for: makeNativeDisplays()
        ))
        XCTAssertNil(corrupted.permanentOriginalPlacements(
            for: makeNativeDisplays()
        ))
    }

    func testRejectsIncompleteOrNonBottomAlignedNativeLayout() {
        XCTAssertNil(LocalDisplayPortalBaseline.resolveNative(
            displays: Array(makeNativeDisplays().dropLast())
        ))
        var misaligned = makeNativeDisplays()
        misaligned[0] = display(
            id: FixedDisplayConfiguration.philipsUUID,
            runtimeID: 11,
            x: -2_048,
            y: -100,
            width: 2_048,
            height: 1_152
        )
        XCTAssertNil(LocalDisplayPortalBaseline.resolveNative(displays: misaligned))
    }

    func testRejectsStoredBaselineWithUnknownSchemaOrIdentity() {
        let invalidSchema = LocalDisplayPortalBaseline(
            schemaVersion: 2,
            mainDisplayID: "internal",
            routingOrderIDs: [
                FixedDisplayConfiguration.philipsUUID,
                "internal",
                FixedDisplayConfiguration.viewSonicUUID,
            ],
            originalOrigins: []
        )
        let invalidIdentity = LocalDisplayPortalBaseline(
            schemaVersion: 1,
            mainDisplayID: "internal",
            routingOrderIDs: ["left", "internal", "right"],
            originalOrigins: [
                .init(displayID: "left", x: -100, y: 0),
                .init(displayID: "right", x: 100, y: 0),
            ]
        )

        XCTAssertFalse(invalidSchema.isValid)
        XCTAssertFalse(invalidIdentity.isValid)
    }

    private func makeNativeDisplays() -> [CrossScreenDisplay] {
        [
            display(
                id: FixedDisplayConfiguration.philipsUUID,
                runtimeID: 11,
                x: -2_048,
                y: -185,
                width: 2_048,
                height: 1_152
            ),
            display(
                id: "internal",
                runtimeID: 12,
                x: 0,
                y: 0,
                width: 1_496,
                height: 967,
                isMain: true
            ),
            display(
                id: FixedDisplayConfiguration.viewSonicUUID,
                runtimeID: 13,
                x: 1_496,
                y: -185,
                width: 2_048,
                height: 1_152
            ),
        ]
    }

    private func display(
        id: String,
        runtimeID: CGDirectDisplayID,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        isMain: Bool = false
    ) -> CrossScreenDisplay {
        CrossScreenDisplay(
            id: id,
            runtimeID: runtimeID,
            name: id,
            frame: CGRect(x: x, y: y, width: width, height: height),
            physicalHeightMM: 300,
            isMain: isMain
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
