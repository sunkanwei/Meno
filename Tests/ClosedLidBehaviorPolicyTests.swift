import XCTest

final class ClosedLidBehaviorPolicyTests: XCTestCase {
    func testFollowSystemDoesNotDependOnLidState() {
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .unavailable,
                mode: .followSystem,
                requestDisplaySleep: true,
                requestSystemSleep: true
            ),
            .followSystem
        )
    }

    func testOpenLidMonitorsSelectedMode() {
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .open,
                mode: .keepRunning,
                requestDisplaySleep: true,
                requestSystemSleep: false
            ),
            .monitor(.keepRunning)
        )
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .open,
                mode: .sleep,
                requestDisplaySleep: false,
                requestSystemSleep: true
            ),
            .monitor(.sleep)
        )
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .open,
                mode: .shutdown,
                requestDisplaySleep: false,
                requestSystemSleep: false
            ),
            .monitor(.shutdown)
        )
    }

    func testClosedLidPreservesDisplaySleepIntent() {
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .closed,
                mode: .keepRunning,
                requestDisplaySleep: true,
                requestSystemSleep: false
            ),
            .keepRunning(requestDisplaySleep: true)
        )
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .closed,
                mode: .keepRunning,
                requestDisplaySleep: false,
                requestSystemSleep: true
            ),
            .keepRunning(requestDisplaySleep: false)
        )
    }

    func testClosedLidPreservesSystemSleepIntent() {
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .closed,
                mode: .sleep,
                requestDisplaySleep: true,
                requestSystemSleep: true
            ),
            .sleep(requestSystemSleep: true)
        )
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .closed,
                mode: .sleep,
                requestDisplaySleep: false,
                requestSystemSleep: false
            ),
            .sleep(requestSystemSleep: false)
        )
    }

    func testUnavailableLidStateAlwaysFailsSafe() {
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .unavailable,
                mode: .keepRunning,
                requestDisplaySleep: true,
                requestSystemSleep: false
            ),
            .failSafe
        )
    }

    func testClosedLidLeavesShutdownToPrivilegedHelper() {
        XCTAssertEqual(
            ClosedLidBehaviorPolicy.action(
                for: .closed,
                mode: .shutdown,
                requestDisplaySleep: false,
                requestSystemSleep: false
            ),
            .monitor(.shutdown)
        )
    }

    func testPendingEventsKeepLatestReasonAndAnyDisplaySleepRequest() {
        var pending = PendingClosedLidReconcile()
        pending.merge(
            reason: .displayConfigurationChanged,
            requestDisplaySleep: true,
            requestSystemSleep: false
        )
        pending.merge(
            reason: .systemWillSleep,
            requestDisplaySleep: false,
            requestSystemSleep: true
        )

        XCTAssertEqual(
            pending.consume(),
            ClosedLidReconcileRequest(
                reason: .systemWillSleep,
                requestsDisplaySleep: true,
                requestsSystemSleep: true
            )
        )
        XCTAssertNil(pending.consume())
    }

    func testPendingRequestCanBeReset() {
        var pending = PendingClosedLidReconcile()
        pending.merge(
            reason: .systemWoke,
            requestDisplaySleep: true,
            requestSystemSleep: true
        )
        pending.reset()

        XCTAssertNil(pending.consume())
    }
}
