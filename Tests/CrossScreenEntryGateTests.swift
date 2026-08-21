import CoreGraphics
import XCTest

final class CrossScreenEntryGateTests: XCTestCase {
    func testGateStartsArmed() {
        var gate = CrossScreenEntryGate()

        XCTAssertTrue(gate.isArmed)
        XCTAssertEqual(gate.decision(), .ready)
    }

    func testReturnGateBlocksEntryDuringSettlement() {
        var gate = CrossScreenEntryGate()
        let returnTime = ContinuousClock.now
        gate.disarm(at: returnTime)

        XCTAssertEqual(
            gate.decision(now: returnTime.advanced(by: .milliseconds(49))),
            .hold(nil)
        )
        XCTAssertFalse(gate.isArmed)
    }

    func testGateRearmsOnFirstMovementAfterSettlement() {
        var gate = CrossScreenEntryGate()
        let returnTime = ContinuousClock.now
        gate.disarm(at: returnTime)

        XCTAssertEqual(
            gate.decision(now: returnTime.advanced(by: .milliseconds(50))),
            .ready
        )
        XCTAssertTrue(gate.isArmed)
        XCTAssertEqual(
            gate.decision(now: returnTime.advanced(by: .milliseconds(50))),
            .ready
        )
    }

    func testRepeatedMovementCannotBypassSettlement() {
        var gate = CrossScreenEntryGate()
        let returnTime = ContinuousClock.now
        let unsettledTime = returnTime.advanced(by: .milliseconds(49))
        gate.disarm(at: returnTime)

        XCTAssertEqual(gate.decision(now: unsettledTime), .hold(nil))
        XCTAssertEqual(gate.decision(now: unsettledTime), .hold(nil))
        XCTAssertEqual(gate.decision(now: unsettledTime), .hold(nil))
        XCTAssertFalse(gate.isArmed)
    }

    func testReturnGateKeepsTheRestoredPointDuringSettlement() {
        var gate = CrossScreenEntryGate()
        let returnTime = ContinuousClock.now
        let restoredPoint = CGPoint(x: 1, y: 480)
        gate.disarm(
            at: returnTime,
            stabilizationPoint: restoredPoint
        )

        XCTAssertEqual(
            gate.decision(now: returnTime.advanced(by: .milliseconds(49))),
            .hold(restoredPoint)
        )
        XCTAssertEqual(
            gate.decision(now: returnTime.advanced(by: .milliseconds(50))),
            .ready
        )
    }

    func testExplicitArmClearsReturnGate() {
        var gate = CrossScreenEntryGate()
        gate.disarm(at: .now)

        gate.arm()

        XCTAssertTrue(gate.isArmed)
        XCTAssertEqual(gate.decision(), .ready)
    }
}
