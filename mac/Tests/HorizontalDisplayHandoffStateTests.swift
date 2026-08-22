import CoreGraphics
import XCTest

final class HorizontalDisplayHandoffStateTests: XCTestCase {
    func testDefaultsToEnabledBottomAlignment() {
        XCTAssertEqual(HorizontalDisplayHandoffState().configuration, .defaultValue)
    }

    func testDisabledConfigurationDoesNotIntervene() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry(),
            configuration: DisplayHandoffConfiguration(enabled: false, alignment: .bottom)
        )
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
    }

    func testFirstObservationNeverHandsOffPrematurely() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        XCTAssertEqual(
            state.decision(location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5),
            .none
        )
    }

    func testHandsOffBeforeWindowServerCrossesAndStabilizesStaleEvents() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
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

    func testTakesOwnershipWhenWindowServerAlreadyReportsDestination() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_497, y: 500),
            movementDeltaX: 8
        ))

        XCTAssertEqual(handoff.sourceDisplayID, "internal")
        XCTAssertEqual(handoff.destinationDisplayID, "right")
        XCTAssertEqual(handoff.targetPoint.x, 1_508)
    }

    func testObservedDisplayTransitionOverridesContradictoryRawDelta() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_497, y: 500),
            movementDeltaX: -8
        ))

        XCTAssertEqual(handoff.direction, .right)
        XCTAssertEqual(handoff.destinationDisplayID, "right")
    }

    func testImmediateReverseMovementCancelsStabilizationAndHandsBack() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        _ = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5
        ))

        let reverse = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: -5
        ))

        XCTAssertEqual(reverse.sourceDisplayID, "right")
        XCTAssertEqual(reverse.destinationDisplayID, "internal")
        XCTAssertEqual(reverse.direction, .left)
    }

    func testStabilizationIsBoundedToFourQueuedEvents() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
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

    func testPhysicalAreaWithoutDestinationBecomesStableWall() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_500, y: -100))

        guard case let .wall(first) = state.decision(
            location: CGPoint(x: 1_497, y: -100), movementDeltaX: -4
        ) else { return XCTFail("Expected a wall outside the internal display") }
        guard case let .wall(second) = state.decision(
            location: first.retainedPoint, movementDeltaX: -4
        ) else { return XCTFail("Expected repeated movement to stay on the same wall") }

        XCTAssertEqual(second, first)
        XCTAssertEqual(first.retainedPoint, CGPoint(x: 1_498, y: -100))
    }

    func testDisallowedDragRemainsBehindBoundary() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        guard case let .wall(wall) = state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 5,
            allowsHandoff: false
        ) else { return XCTFail("Expected the disallowed drag to remain local") }

        XCTAssertEqual(wall.sourceDisplayID, "internal")
        XCTAssertEqual(wall.destinationDisplayID, "right")
        XCTAssertEqual(wall.retainedPoint, CGPoint(x: 1_494, y: 500))
    }

    func testWallRetainsVerticalDeltaWhileBlockingHorizontalMovement() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_500, y: -100))
        guard case let .wall(wall) = state.decision(
            location: CGPoint(x: 1_497, y: -90),
            movementDeltaX: -4
        ) else { return XCTFail("Expected a wall outside the internal display") }
        let source = CGEventSource(stateID: .hidSystemState)
        let event = try XCTUnwrap(CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: wall.retainedPoint,
            mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: -4)
        event.setDoubleValueField(.mouseEventDeltaY, value: 10)

        wall.apply(to: event)

        XCTAssertEqual(event.location, CGPoint(x: 1_498, y: -90))
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaX), 0)
        XCTAssertEqual(event.getDoubleValueField(.mouseEventDeltaY), 10)
    }

    func testFallsBackToObservedMovementWhenRawDeltaIsZero() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500),
            movementDeltaX: 0
        ))

        XCTAssertEqual(handoff.direction, .right)
    }

    func testApplyingHandoffRetargetsCurrentEventAndClearsMovementDelta() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
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

    func testGeometryUpdateCanSeedCurrentPointer() throws {
        var state = HorizontalDisplayHandoffState()
        state.updateGeometry(
            try makeNativeDisplayHandoffFixtureGeometry(),
            pointerLocation: CGPoint(x: 1_490, y: 500)
        )

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
        ))
        XCTAssertEqual(handoff.direction, .right)
    }

    func testGeometryUpdateRequiresFreshObservationAndNilGeometryDisablesHandoff() throws {
        let geometry = try makeNativeDisplayHandoffFixtureGeometry()
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

    func testConfigurationChangeResetsObservationAndUsesNewAlignment() throws {
        let geometry = try makeNativeDisplayHandoffFixtureGeometry()
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
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.alignment, .top)
    }

    func testReapplyingSameConfigurationPreservesObservation() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))

        XCTAssertFalse(state.updateConfiguration(.defaultValue))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.direction, .right)
    }

    func testResetTrackingClearsPendingHandoff() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        _ = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
        ))

        state.resetTracking(at: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 5
        ))

        XCTAssertEqual(handoff.sourceDisplayID, "internal")
        XCTAssertEqual(handoff.destinationDisplayID, "right")
    }

    func testCanTraverseBothNativeSeamsWithoutConfusingOwnership() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 5, y: 500))
        let toLeft = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1, y: 500), movementDeltaX: -4
        ))
        XCTAssertEqual(state.decision(location: toLeft.targetPoint, movementDeltaX: 0), .none)
        let toInternal = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: -1, y: toLeft.targetPoint.y), movementDeltaX: 5
        ))
        XCTAssertEqual(
            state.decision(location: toInternal.targetPoint, movementDeltaX: 0),
            .none
        )
        state.observe(location: CGPoint(x: 1_490, y: toInternal.targetPoint.y))
        let toRight = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: toInternal.targetPoint.y), movementDeltaX: 5
        ))

        XCTAssertEqual(toLeft.destinationDisplayID, "left")
        XCTAssertEqual(toInternal.destinationDisplayID, "internal")
        XCTAssertEqual(toRight.destinationDisplayID, "right")
    }

    func testOneLargeEventTargetsOnlyAdjacentDisplay() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: 1_490, y: 500))
        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_495, y: 500), movementDeltaX: 3_000
        ))

        XCTAssertEqual(handoff.sourceDisplayID, "internal")
        XCTAssertEqual(handoff.destinationDisplayID, "right")
    }

    func testOneLargeAlreadyCrossedEventStillTargetsOnlyAdjacentDisplay() throws {
        var state = HorizontalDisplayHandoffState(
            geometry: try makeNativeDisplayHandoffFixtureGeometry()
        )
        state.observe(location: CGPoint(x: -10, y: 500))

        let handoff = try requireDisplayHandoff(from: state.decision(
            location: CGPoint(x: 1_500, y: 500),
            movementDeltaX: 3_000
        ))

        XCTAssertEqual(handoff.sourceDisplayID, "left")
        XCTAssertEqual(handoff.destinationDisplayID, "internal")
    }
}
