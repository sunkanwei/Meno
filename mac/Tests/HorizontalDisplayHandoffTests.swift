import CoreGraphics
import XCTest

final class HorizontalDisplayHandoffTests: XCTestCase {
    func testAutomaticAndLocalHandoffInputPolicy() {
        XCTAssertTrue(allowsAutomaticDisplayHandoff(type: .mouseMoved, localButtons: 0))
        XCTAssertFalse(allowsAutomaticDisplayHandoff(type: .mouseMoved, localButtons: 1))
        XCTAssertFalse(allowsAutomaticDisplayHandoff(type: .leftMouseDragged, localButtons: 1))
        XCTAssertTrue(allowsLocalDisplayHandoff(type: .mouseMoved, localButtons: 0))
        XCTAssertTrue(allowsLocalDisplayHandoff(type: .leftMouseDragged, localButtons: 1))
        XCTAssertFalse(allowsLocalDisplayHandoff(type: .leftMouseDragged, localButtons: 3))
        XCTAssertFalse(allowsLocalDisplayHandoff(type: .rightMouseDragged, localButtons: 2))
        XCTAssertTrue(handlesLocalDisplayBoundary(type: .rightMouseDragged, localButtons: 2))
        XCTAssertTrue(handlesLocalDisplayBoundary(type: .otherMouseDragged, localButtons: 4))
    }

    func testBuildsNativeAdjacentDisplayGeometryInVerifiedRoutingOrder() throws {
        let geometry = try makeNativeDisplayHandoffFixtureGeometry()

        XCTAssertEqual(geometry.displays.map(\.id), ["left", "internal", "right"])
        XCTAssertEqual(
            geometry.seams.map { "\($0.leftDisplay.id)->\($0.rightDisplay.id)" },
            ["left->internal", "internal->right"]
        )
        XCTAssertNil(HorizontalDisplayHandoffGeometry.resolve(
            displays: geometry.displays,
            routingOrderIDs: ["right", "internal", "left"]
        ))
    }

    func testBuildsRemainingNativeSeamAfterSharedDisplayDisconnects() throws {
        let internalDisplay = makeDisplayHandoffTestDisplay(
            "internal", x: 0, width: 1_496, height: 967,
            physicalHeightMM: 223.3, isMain: true
        )
        let rightDisplay = makeDisplayHandoffTestDisplay(
            "right", x: 1_496, y: -185, width: 2_048, height: 1_152,
            physicalHeightMM: 335.7
        )
        let geometry = try XCTUnwrap(HorizontalDisplayHandoffGeometry.resolve(
            displays: [rightDisplay, internalDisplay],
            routingOrderIDs: ["internal", "right"]
        ))

        XCTAssertEqual(geometry.displays.map(\.id), ["internal", "right"])
        XCTAssertEqual(geometry.seams.map(\.rightDisplay.id), ["right"])
    }

    func testRejectsCornerOnlyGapAndInvalidDisplayIdentity() {
        let main = makeDisplayHandoffTestDisplay(
            "main", x: 0, width: 100, height: 100,
            physicalHeightMM: 200, isMain: true
        )
        let validRight = makeDisplayHandoffTestDisplay(
            "right", x: 100, width: 100, height: 100,
            physicalHeightMM: 200
        )
        XCTAssertNotNil(HorizontalDisplayHandoffGeometry.resolve(
            displays: [main, validRight],
            routingOrderIDs: ["main", "right"]
        ))

        for invalidRight in [
            makeDisplayHandoffTestDisplay(
                "right", x: 100, y: 100, width: 100, height: 100,
                physicalHeightMM: 200
            ),
            makeDisplayHandoffTestDisplay(
                "right", x: 103, width: 100, height: 100,
                physicalHeightMM: 200
            ),
            makeDisplayHandoffTestDisplay(
                "right", x: 100, width: 100, height: 100,
                physicalHeightMM: 200, rotationDegrees: 90
            ),
            makeDisplayHandoffTestDisplay(
                "right", x: 100, width: 100, height: 100,
                physicalHeightMM: 200, isMirrored: true
            ),
        ] {
            XCTAssertNil(HorizontalDisplayHandoffGeometry.resolve(
                displays: [main, invalidRight],
                routingOrderIDs: ["main", "right"]
            ))
        }
        XCTAssertNil(HorizontalDisplayHandoffGeometry.resolve(
            displays: [main, validRight],
            routingOrderIDs: ["main", "main"]
        ))
        XCTAssertNil(HorizontalDisplayHandoffGeometry.resolve(
            displays: [main, makeDisplayHandoffTestDisplay(
                "main", x: 100, width: 100, height: 100,
                physicalHeightMM: 200
            )],
            routingOrderIDs: ["main", "right"]
        ))
    }

    func testBottomAlignmentPreservesPhysicalHeightAndRoundTrips() throws {
        let geometry = try makeNativeDisplayHandoffFixtureGeometry()
        let seam = geometry.seams[0]
        let source = seam.rightDisplay
        let sourceHeightMM = try XCTUnwrap(source.physicalHeightMM)
        let sourceY = source.frame.maxY - 100 / sourceHeightMM * source.frame.height

        let left = try XCTUnwrap(geometry.handoff(
            sourceY: sourceY,
            seam: seam,
            direction: .left,
            alignment: .bottom
        ))
        XCTAssertEqual(left.sourceDisplayID, "internal")
        XCTAssertEqual(left.destinationDisplayID, "left")
        XCTAssertEqual(left.targetPoint.x, -12)
        XCTAssertEqual(
            try physicalHeightAboveBottomMM(left.targetPoint.y, on: seam.leftDisplay),
            100,
            accuracy: 0.01
        )

        let right = try XCTUnwrap(geometry.handoff(
            sourceY: left.targetPoint.y,
            seam: seam,
            direction: .right,
            alignment: .bottom
        ))
        XCTAssertEqual(right.targetPoint.x, 12)
        XCTAssertEqual(right.targetPoint.y, sourceY, accuracy: 1)
    }

    func testTopAlignmentUsesEachDisplayGlobalOrigin() throws {
        let geometry = try makeNativeDisplayHandoffFixtureGeometry()
        let seam = geometry.seams[0]
        let sourceHeightMM = try XCTUnwrap(seam.rightDisplay.physicalHeightMM)
        let sourceY = seam.rightDisplay.frame.minY
            + 100 / sourceHeightMM * seam.rightDisplay.frame.height

        let handoff = try XCTUnwrap(geometry.handoff(
            sourceY: sourceY,
            seam: seam,
            direction: .left,
            alignment: .top
        ))

        XCTAssertEqual(
            try physicalDistanceBelowTopMM(handoff.targetPoint.y, on: seam.leftDisplay),
            100,
            accuracy: 0.01
        )
    }

    func testEqualPhysicalHeightKeepsDisplaysLevel() throws {
        let left = makeDisplayHandoffTestDisplay(
            "left", x: 0, width: 100, height: 100, physicalHeightMM: 200,
            isMain: true
        )
        let right = makeDisplayHandoffTestDisplay(
            "right", x: 100, width: 120, height: 120, physicalHeightMM: 200
        )
        let geometry = try XCTUnwrap(HorizontalDisplayHandoffGeometry.resolve(
            displays: [left, right],
            routingOrderIDs: ["left", "right"]
        ))
        for alignment in DisplayHandoffAlignment.allCases {
            let sourceY: CGFloat = alignment == .top ? 25 : 75
            let handoff = try XCTUnwrap(geometry.handoff(
                sourceY: sourceY,
                seam: geometry.seams[0],
                direction: .right,
                alignment: alignment
            ))
            let sourceOffset = alignment == .top
                ? try physicalDistanceBelowTopMM(sourceY, on: left)
                : try physicalHeightAboveBottomMM(sourceY, on: left)
            let destinationOffset = alignment == .top
                ? try physicalDistanceBelowTopMM(handoff.targetPoint.y, on: right)
                : try physicalHeightAboveBottomMM(handoff.targetPoint.y, on: right)
            XCTAssertEqual(destinationOffset, sourceOffset, accuracy: 0.01)
        }
    }

    func testPhysicalAreaOutsideShorterDestinationBecomesWall() throws {
        let geometry = try makeNativeDisplayHandoffFixtureGeometry()
        let seam = geometry.seams[0]
        let sourceHeightMM = try XCTUnwrap(seam.leftDisplay.physicalHeightMM)
        let destinationHeightMM = try XCTUnwrap(seam.rightDisplay.physicalHeightMM)
        let sourceY = seam.leftDisplay.frame.maxY
            - (destinationHeightMM + 10) / sourceHeightMM * seam.leftDisplay.frame.height

        XCTAssertNil(geometry.handoff(
            sourceY: sourceY,
            seam: seam,
            direction: .right,
            alignment: .bottom
        ))
    }

    func testMissingPhysicalHeightDisablesOnlyMapping() throws {
        let left = makeDisplayHandoffTestDisplay(
            "left", x: 0, width: 100, height: 100,
            physicalHeightMM: nil, isMain: true
        )
        let right = makeDisplayHandoffTestDisplay(
            "right", x: 100, width: 100, height: 100,
            physicalHeightMM: 200
        )
        let geometry = try XCTUnwrap(HorizontalDisplayHandoffGeometry.resolve(
            displays: [left, right],
            routingOrderIDs: ["left", "right"]
        ))

        XCTAssertNil(geometry.handoff(
            sourceY: 50,
            seam: geometry.seams[0],
            direction: .right,
            alignment: .bottom
        ))
    }
}
