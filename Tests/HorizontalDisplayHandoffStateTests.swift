import CoreGraphics
import XCTest

final class HorizontalDisplayHandoffStateTests: XCTestCase {
    func testDefaultsToEnabledBottomAlignment() {
        XCTAssertEqual(HorizontalDisplayHandoffState().configuration, .defaultValue)
    }

    func testDisabledConfigurationDoesNotIntervene() throws {
        let geometry = try makePortalDisplayHandoffFixtureGeometry()
        var state = HorizontalDisplayHandoffState(
            geometry: geometry,
            configuration: DisplayHandoffConfiguration(enabled: false, alignment: .bottom)
        )

        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_490, y: 500), movementDeltaX: 5),
            .none
        )
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
    }

    func testFirstObservationNeverHandsOffPrematurely() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )

        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
    }

    func testPortalHandsOffAtWallAndStabilizesUntilDestinationArrives() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )

        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_490, y: 500), movementDeltaX: 5),
            .none
        )
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))
        XCTAssertEqual(handoff.sourceDisplayID, "internal")
        XCTAssertEqual(handoff.destinationDisplayID, "right")
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .stabilize(handoff.targetPoint)
        )
        XCTAssertEqual(
            state.decision(location: handoff.targetPoint, movementDeltaX: 0),
            .none
        )
    }

    func testPortalStabilizationIsBoundedToFourQueuedEvents() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))

        for _ in 0..<4 {
            XCTAssertEqual(
                state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
                .stabilize(handoff.targetPoint)
            )
        }
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
    }

    func testPortalUsesRawMovementWhileSlidingFromWallIntoOpening() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        let edgePoint = CGPoint(x: 1_497, y: 1_000)
        state.observe(location: edgePoint)

        guard case let .wall(wall) = state.decision(
            location: edgePoint,
            movementDeltaX: -4
        ) else {
            return XCTFail("Expected the external display top to remain a wall")
        }
        XCTAssertEqual(wall.sourceDisplayID, "right")
        XCTAssertEqual(wall.destinationDisplayID, "internal")
        XCTAssertEqual(wall.retainedPoint, CGPoint(x: 1_498, y: 1_000))
        XCTAssertTrue(wall.beginsContact)

        guard case let .wall(continuedWall) = state.decision(
            location: edgePoint,
            movementDeltaX: -4
        ) else {
            return XCTFail("Expected continued outward movement to remain blocked")
        }
        XCTAssertFalse(continuedWall.beginsContact)

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: edgePoint.x, y: 1_800),
            movementDeltaX: -4
        ))
        XCTAssertEqual(handoff.sourceDisplayID, "right")
        XCTAssertEqual(handoff.destinationDisplayID, "internal")
    }

    func testPortalFallsBackToObservedMovementWhenRawDeltaIsZero() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 0
        ))

        XCTAssertEqual(handoff.direction, .right)
    }

    func testPortalWallRetainsVerticalMovementWhileBlockingHorizontalCrossing() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_497, y: 1_000))
        guard case let .wall(wall) = state.decision(
            location: CGPoint(x: 1_497, y: 1_010),
            movementDeltaX: -4
        ) else {
            return XCTFail("Expected the external display top to remain a wall")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: wall.crossingPoint,
            mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: -4)
        event.setDoubleValueField(.mouseEventDeltaY, value: 10)

        wall.apply(to: event)

        XCTAssertEqual(event.location, CGPoint(x: 1_498, y: 1_010))
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaY), 10)
    }

    func testPortalAnticipatesNativeCornerBeforeItCanOwnTheCursor() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_520, y: 970))

        guard case let .wall(wall) = state.decision(
            location: CGPoint(x: 1_505, y: 970),
            movementDeltaX: -15
        ) else {
            return XCTFail("Expected the external display top to be blocked before the corner")
        }

        XCTAssertEqual(wall.sourceDisplayID, "right")
        XCTAssertEqual(wall.destinationDisplayID, "internal")
        XCTAssertEqual(wall.retainedPoint, CGPoint(x: 1_498, y: 970))
    }

    func testUShapedPortalAnticipatesBothDirectionsAtRightSeamCorner() throws {
        let displays = [
            makeDisplayHandoffTestDisplay(
                "left", x: -2_048, y: -1_152, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ),
            makeDisplayHandoffTestDisplay(
                "internal", x: 0, y: 0, width: 1_496, height: 967,
                physicalHeightMM: 222.5, isMain: true
            ),
            makeDisplayHandoffTestDisplay(
                "right", x: 1_496, y: -1_152, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ),
        ]
        let geometry = try XCTUnwrap(HorizontalDisplayHandoffGeometry.resolve(
            displays: displays,
            routingOrderIDs: ["left", "internal", "right"]
        ))

        var fromRight = HorizontalDisplayHandoffState(geometry: geometry)
        fromRight.observe(location: CGPoint(x: 1_520, y: -3))
        let toInternal = try requireDisplayHandoff(from: fromRight.decision(
            location: CGPoint(x: 1_505, y: -3),
            movementDeltaX: -15
        ))
        XCTAssertEqual(toInternal.sourceDisplayID, "right")
        XCTAssertEqual(toInternal.destinationDisplayID, "internal")

        var fromInternal = HorizontalDisplayHandoffState(geometry: geometry)
        fromInternal.observe(location: CGPoint(x: 1_475, y: 3))
        let toRight = try requireDisplayHandoff(from: fromInternal.decision(
            location: CGPoint(x: 1_487, y: 3),
            movementDeltaX: 12
        ))
        XCTAssertEqual(toRight.sourceDisplayID, "internal")
        XCTAssertEqual(toRight.destinationDisplayID, "right")
    }

    func testPortalWallBlocksOpeningWhenHandoffIsNotAllowed() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        guard case let .wall(wall) = state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5,
            allowsHandoff: false
        ) else {
            return XCTFail("Expected a disallowed drag to remain behind the portal wall")
        }

        XCTAssertEqual(wall.sourceDisplayID, "internal")
        XCTAssertEqual(wall.destinationDisplayID, "right")
        XCTAssertEqual(wall.retainedPoint, CGPoint(x: 1_494, y: 500))
    }

    func testApplyingHandoffRetargetsCurrentEventAndClearsMovementDelta() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))
        let source = CGEventSource(stateID: .hidSystemState)
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 1_495, y: 500),
            mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: 5)
        event.setDoubleValueField(.mouseEventDeltaY, value: 20)

        handoff.apply(to: event)

        XCTAssertEqual(event.location, handoff.targetPoint)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaY), 0)
    }

    func testUpdatingGeometryRequiresFreshObservation() throws {
        let geometry = try makePortalDisplayHandoffFixtureGeometry()
        var state = HorizontalDisplayHandoffState(geometry: geometry)
        state.observe(location: CGPoint(x: 1_490, y: 500))

        state.updateGeometry(geometry)
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
        XCTAssertNotEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )

        state.updateGeometry(nil)
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
    }

    func testUpdatingGeometryCanSeedCurrentPointer() throws {
        var state = HorizontalDisplayHandoffState()
        state.updateGeometry(
            try makePortalDisplayHandoffFixtureGeometry(),
            pointerLocation: CGPoint(x: 1_490, y: 500)
        )

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.direction, .right)
    }

    func testChangingConfigurationRequiresFreshObservationAndUsesNewAlignment() throws {
        let geometry = try makePortalDisplayHandoffFixtureGeometry()
        var state = HorizontalDisplayHandoffState(geometry: geometry)
        state.observe(location: CGPoint(x: 1_490, y: 500))

        XCTAssertTrue(state.updateConfiguration(
            DisplayHandoffConfiguration(enabled: true, alignment: .top)
        ))
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_490, y: 500), movementDeltaX: 0),
            .none
        )
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.alignment, .top)
    }

    func testReapplyingSameConfigurationPreservesObservation() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        XCTAssertFalse(state.updateConfiguration(.defaultValue))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.direction, .right)
    }

    func testResetAtRestoredPointerDiscardsStaleOwnership() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_498, y: 1_800))

        state.resetTracking(at: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.sourceDisplayID, "internal")
        XCTAssertEqual(handoff.destinationDisplayID, "right")
    }

    func testCanTraverseBothPortalSeamsWithoutConfusingOwnership() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 5, y: 500))
        let toLeft = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1, y: 500),
            movementDeltaX: -4
        ))
        XCTAssertEqual(
            state.decision(location: toLeft.targetPoint, movementDeltaX: 0),
            .none
        )
        let toInternal = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: -1, y: toLeft.targetPoint.y),
            movementDeltaX: 5
        ))
        XCTAssertEqual(
            state.decision(location: toInternal.targetPoint, movementDeltaX: 0),
            .none
        )
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_490, y: toInternal.targetPoint.y), movementDeltaX: 5),
            .none
        )
        let toRight = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: toInternal.targetPoint.y),
            movementDeltaX: 5
        ))

        XCTAssertEqual(toLeft.destinationDisplayID, "left")
        XCTAssertEqual(toInternal.destinationDisplayID, "internal")
        XCTAssertEqual(toRight.destinationDisplayID, "right")
    }

    func testOneOutwardEventTargetsOnlyAdjacentPortal() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makePortalDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 3_000
        ))

        XCTAssertEqual(handoff.sourceDisplayID, "internal")
        XCTAssertEqual(handoff.destinationDisplayID, "right")
    }
}
