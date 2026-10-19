import CoreGraphics
import Foundation
import XCTest

final class LocalDisplayRoutingBaselineTests: XCTestCase {
    func testCapturesPhilipsViewSonicMacBookOrderWithRightmostMain() throws {
        let displays = [
            display(id: FixedDisplayConfiguration.philipsUUID, runtimeID: 4,
                    x: -4096, y: -185, width: 2048, height: 1152),
            display(id: FixedDisplayConfiguration.viewSonicUUID, runtimeID: 2,
                    x: -2048, y: -185, width: 2048, height: 1152),
            display(id: "internal", runtimeID: 1,
                    x: 0, y: 0, width: 1496, height: 967, isMain: true),
        ]
        let baseline = try XCTUnwrap(LocalDisplayRoutingBaseline.resolveNative(displays: displays))
        let restored = try JSONDecoder().decode(
            LocalDisplayRoutingBaseline.self, from: JSONEncoder().encode(baseline)
        )
        XCTAssertTrue(restored.isValid)
        XCTAssertEqual(restored.mainDisplayID, "internal")
        XCTAssertEqual(restored.routingOrderIDs, displays.map(\.id))
        XCTAssertEqual(restored.activeRoutingOrderIDs(for: Array(displays.dropFirst())), [
            FixedDisplayConfiguration.viewSonicUUID, "internal",
        ])
        XCTAssertNil(restored.activeRoutingOrderIDs(for: [displays[0], displays[2]]))
    }

    func testSupportsViewSonicMainWithoutTreatingItAsBuiltIn() throws {
        let displays = [
            display(id: FixedDisplayConfiguration.philipsUUID, runtimeID: 4,
                    x: -2048, y: 0, width: 2048, height: 1152),
            display(id: FixedDisplayConfiguration.viewSonicUUID, runtimeID: 2,
                    x: 0, y: 0, width: 2048, height: 1152, isMain: true),
            display(id: "internal", runtimeID: 1,
                    x: 2048, y: 185, width: 1496, height: 967),
        ]
        let baseline = try XCTUnwrap(LocalDisplayRoutingBaseline.resolveNative(displays: displays))
        XCTAssertTrue(baseline.isValid)
    }

    func testCapturesVerifiedNativeRoutingAndRoundTripsThroughStorage() throws {
        let displays = makeNativeDisplays()

        let baseline = try XCTUnwrap(
            LocalDisplayRoutingBaseline.resolveNative(displays: displays)
        )
        let decoded = try JSONDecoder().decode(
            LocalDisplayRoutingBaseline.self,
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

    func testSavedRoutingFiltersMissingSharedDisplayWithoutUsingTwoScreenCoordinates() throws {
        let baseline = try XCTUnwrap(
            LocalDisplayRoutingBaseline.resolveNative(displays: makeNativeDisplays())
        )
        let activeDisplays = Array(makeNativeDisplays().dropFirst()).map { display in
            CrossScreenDisplay(
                id: display.id,
                runtimeID: display.runtimeID,
                name: display.name,
                frame: display.frame.offsetBy(dx: -600, dy: 300),
                physicalHeightMM: display.physicalHeightMM,
                isMain: display.isMain
            )
        }

        XCTAssertEqual(
            baseline.activeRoutingOrderIDs(for: activeDisplays),
            ["internal", FixedDisplayConfiguration.viewSonicUUID]
        )
    }

    func testRejectsIncompleteOrNonBottomAlignedNativeLayout() {
        XCTAssertNil(LocalDisplayRoutingBaseline.resolveNative(
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
        XCTAssertNil(LocalDisplayRoutingBaseline.resolveNative(displays: misaligned))
    }

    func testRejectsUnknownActiveDisplayAndMissingMainDisplay() throws {
        let nativeDisplays = makeNativeDisplays()
        let baseline = try XCTUnwrap(
            LocalDisplayRoutingBaseline.resolveNative(displays: nativeDisplays)
        )
        XCTAssertNil(baseline.activeRoutingOrderIDs(for: [
            nativeDisplays[1],
            display(
                id: "temporary",
                runtimeID: 99,
                x: 1_496,
                y: 0,
                width: 800,
                height: 600
            ),
        ]))
        XCTAssertNil(baseline.activeRoutingOrderIDs(
            for: [nativeDisplays[0], nativeDisplays[2]]
        ))
    }

    func testRejectsStoredBaselineWithUnknownSchemaOrIdentity() {
        let invalidSchema = LocalDisplayRoutingBaseline(
            schemaVersion: 2,
            mainDisplayID: "internal",
            routingOrderIDs: [
                FixedDisplayConfiguration.philipsUUID,
                "internal",
                FixedDisplayConfiguration.viewSonicUUID,
            ],
            originalOrigins: []
        )
        let invalidIdentity = LocalDisplayRoutingBaseline(
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
