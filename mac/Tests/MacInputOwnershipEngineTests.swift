import XCTest

final class MacInputOwnershipEngineTests: XCTestCase {
    func testHappyPathHasExplicitCaptureAndReleasePhases() {
        var engine = MacInputOwnershipEngine()
        let identity = makeIdentity()

        XCTAssertTrue(engine.apply(.requestCapture(identity)))
        XCTAssertEqual(engine.phase, .capturing(identity))
        XCTAssertTrue(engine.apply(.captureSucceeded(identity)))
        XCTAssertEqual(engine.phase, .acquiring(identity))
        XCTAssertTrue(engine.apply(.remoteAcquired(identity)))
        XCTAssertEqual(engine.phase, .remote(identity))
        XCTAssertTrue(engine.apply(.requestRelease(identity, returnY: 123)))
        XCTAssertEqual(engine.phase, .releasing(identity, returnY: 123))
        XCTAssertTrue(engine.apply(.completed(identity)))
        XCTAssertEqual(engine.phase, .local)
    }

    func testCaptureFailureReturnsDirectlyToLocal() {
        var engine = MacInputOwnershipEngine()
        let identity = makeIdentity()

        XCTAssertTrue(engine.apply(.requestCapture(identity)))
        XCTAssertTrue(engine.apply(.captureFailed(identity)))
        XCTAssertEqual(engine.phase, .local)
    }

    func testStaleConnectionControlAndRouteEventsAreRejected() {
        var engine = MacInputOwnershipEngine()
        let current = makeIdentity()
        let staleConnection = MouseControlIdentity(
            connectionID: UUID(),
            controlID: current.controlID,
            routeID: current.routeID
        )
        let staleControl = MouseControlIdentity(
            connectionID: current.connectionID,
            controlID: current.controlID + 1,
            routeID: current.routeID
        )
        let staleRoute = MouseControlIdentity(
            connectionID: current.connectionID,
            controlID: current.controlID,
            routeID: current.routeID + 1
        )

        XCTAssertTrue(engine.apply(.requestCapture(current)))
        XCTAssertFalse(engine.apply(.captureSucceeded(staleConnection)))
        XCTAssertFalse(engine.apply(.captureSucceeded(staleControl)))
        XCTAssertFalse(engine.apply(.captureSucceeded(staleRoute)))
        XCTAssertEqual(engine.phase, .capturing(current))
    }

    func testImmediateRecoveryIsExplicitAndIdempotentAgainstLateAcks() {
        var engine = MacInputOwnershipEngine()
        let identity = makeIdentity()
        _ = engine.apply(.requestCapture(identity))
        _ = engine.apply(.captureSucceeded(identity))

        XCTAssertTrue(engine.apply(.requestRecovery(identity, returnY: 456)))
        XCTAssertEqual(engine.phase, .recovering(identity, returnY: 456))
        XCTAssertFalse(engine.apply(.remoteAcquired(identity)))
        XCTAssertTrue(engine.apply(.completed(identity)))
        XCTAssertFalse(engine.apply(.completed(identity)))
        XCTAssertEqual(engine.phase, .local)
    }

    private func makeIdentity() -> MouseControlIdentity {
        MouseControlIdentity(
            connectionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            controlID: 7,
            routeID: 9
        )
    }
}
