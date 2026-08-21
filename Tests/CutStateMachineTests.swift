import XCTest

final class CutStateMachineTests: XCTestCase {
    private struct HealthFailureCase {
        let name: String
        let health: CutHealthSnapshot
        let evaluationDate: Date
    }

    private let sourceA = URL(fileURLWithPath: "/Volumes/Test/source-a")
    private let sourceB = URL(fileURLWithPath: "/Volumes/Test/source-b")

    func testCopyArmsOnlyAfterMatchingPasteboardConfirmation() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var machine = CutStateMachine()
        let attempt = try XCTUnwrap(
            machine.beginCopy(
                finderPID: 42,
                baselinePasteboardChangeCount: 7,
                sourceURLs: [sourceB, sourceA],
                now: now
            )
        )

        XCTAssertTrue(
            machine.confirmCopy(
                token: attempt.token,
                finderPID: 42,
                pasteboardChangeCount: 8,
                copiedURLs: [sourceA, sourceB],
                sourcesExist: true,
                now: now.addingTimeInterval(0.1)
            )
        )
        XCTAssertTrue(machine.hasArmedSession)
    }

    func testMismatchedOrStaleCopyNeverArms() throws {
        let now = Date(timeIntervalSinceReferenceDate: 200)
        var machine = CutStateMachine()
        let attempt = try XCTUnwrap(
            machine.beginCopy(
                finderPID: 42,
                baselinePasteboardChangeCount: 7,
                sourceURLs: [sourceA],
                now: now
            )
        )

        XCTAssertFalse(
            machine.confirmCopy(
                token: attempt.token,
                finderPID: 42,
                pasteboardChangeCount: 8,
                copiedURLs: [sourceB],
                sourcesExist: true,
                now: now.addingTimeInterval(0.1)
            )
        )
        XCTAssertEqual(machine.phase, .idle)
    }

    func testEveryHealthInvariantCancelsArmedSessionWhenBroken() throws {
        let now = Date(timeIntervalSinceReferenceDate: 300)
        let validHealth = healthSnapshot(checkedAt: now.addingTimeInterval(0.2))
        let cases = [
            HealthFailureCase(
                name: "Finder process changed",
                health: healthSnapshot(finderPID: 43, checkedAt: validHealth.checkedAt),
                evaluationDate: validHealth.checkedAt
            ),
            HealthFailureCase(
                name: "Pasteboard changed",
                health: healthSnapshot(pasteboardChangeCount: 9, checkedAt: validHealth.checkedAt),
                evaluationDate: validHealth.checkedAt
            ),
            HealthFailureCase(
                name: "Source disappeared",
                health: healthSnapshot(sourcesExist: false, checkedAt: validHealth.checkedAt),
                evaluationDate: validHealth.checkedAt
            ),
            HealthFailureCase(
                name: "Health snapshot expired",
                health: healthSnapshot(checkedAt: now),
                evaluationDate: now.addingTimeInterval(CutStateMachine.maximumHealthAge + 0.1)
            ),
            HealthFailureCase(
                name: "Cut session expired",
                health: healthSnapshot(
                    checkedAt: now.addingTimeInterval(CutStateMachine.sessionTimeout + 0.2)
                ),
                evaluationDate: now.addingTimeInterval(CutStateMachine.sessionTimeout + 0.2)
            )
        ]

        for testCase in cases {
            var machine = try armedMachine(now: now)
            XCTAssertTrue(
                machine.invalidateIfNeeded(
                    health: testCase.health,
                    now: testCase.evaluationDate
                ),
                testCase.name
            )
            XCTAssertEqual(machine.phase, .idle, testCase.name)
        }
    }

    func testMoveConsumesOnlyFreshValidSession() throws {
        let now = Date(timeIntervalSinceReferenceDate: 400)
        var machine = try armedMachine(now: now)
        let health = CutHealthSnapshot(
            finderPID: 42,
            pasteboardChangeCount: 8,
            sourcesExist: true,
            checkedAt: now.addingTimeInterval(0.2)
        )

        XCTAssertNotNil(machine.consumeForMove(health: health, now: now.addingTimeInterval(0.2)))
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.consumeForMove(health: health, now: now.addingTimeInterval(0.3)))
    }

    func testOldCopyConfirmationCannotReviveCancelledState() throws {
        let now = Date(timeIntervalSinceReferenceDate: 500)
        var machine = CutStateMachine()
        let attempt = try XCTUnwrap(
            machine.beginCopy(
                finderPID: 42,
                baselinePasteboardChangeCount: 7,
                sourceURLs: [sourceA],
                now: now
            )
        )
        machine.cancel()

        XCTAssertFalse(
            machine.confirmCopy(
                token: attempt.token,
                finderPID: 42,
                pasteboardChangeCount: 8,
                copiedURLs: [sourceA],
                sourcesExist: true,
                now: now.addingTimeInterval(0.1)
            )
        )
        XCTAssertEqual(machine.phase, .idle)
    }

    private func armedMachine(now: Date) throws -> CutStateMachine {
        var machine = CutStateMachine()
        let attempt = try XCTUnwrap(
            machine.beginCopy(
                finderPID: 42,
                baselinePasteboardChangeCount: 7,
                sourceURLs: [sourceA],
                now: now
            )
        )
        XCTAssertTrue(
            machine.confirmCopy(
                token: attempt.token,
                finderPID: 42,
                pasteboardChangeCount: 8,
                copiedURLs: [sourceA],
                sourcesExist: true,
                now: now.addingTimeInterval(0.1)
            )
        )
        return machine
    }

    private func healthSnapshot(
        finderPID: Int32? = 42,
        pasteboardChangeCount: Int = 8,
        sourcesExist: Bool = true,
        checkedAt: Date
    ) -> CutHealthSnapshot {
        CutHealthSnapshot(
            finderPID: finderPID,
            pasteboardChangeCount: pasteboardChangeCount,
            sourcesExist: sourcesExist,
            checkedAt: checkedAt
        )
    }
}
