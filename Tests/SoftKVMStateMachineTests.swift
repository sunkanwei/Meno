import XCTest

@MainActor
final class SoftKVMStateMachineTests: XCTestCase {
    func testWindowsFailureCommitsWaitingStateBeforeDisablingRoute() {
        var machine = readyWindowsMachine()

        let actions = machine.updateMouseAvailability(.failed("driver unavailable"))

        XCTAssertEqual(machine.status, .windowsWaiting(reason: "driver unavailable"))
        XCTAssertFalse(machine.desiredRouteEnabled)
        XCTAssertEqual(actions, [.disableRoute])
        XCTAssertNil(machine.invariantViolation)

        XCTAssertTrue(
            machine.updateMouseAvailability(.failed("driver unavailable")).isEmpty
        )
    }

    func testReadinessLossDisablesRouteAndSchedulesOneRefresh() {
        var machine = readyWindowsMachine()

        let actions = machine.updateReadiness(isAvailable: false)

        XCTAssertEqual(
            machine.status,
            .windowsWaiting(reason: "正在等待 Windows 输入通道。")
        )
        XCTAssertFalse(machine.desiredRouteEnabled)
        XCTAssertEqual(
            actions,
            [.disableRoute, .refresh]
        )
        XCTAssertNil(machine.invariantViolation)
    }

    func testReadinessLossPreservesSpecificMouseFailureReason() {
        var machine = readyWindowsMachine()
        _ = machine.updateMouseAvailability(.failed("driver unavailable"))

        let actions = machine.updateReadiness(isAvailable: false)

        XCTAssertEqual(machine.mouseUnavailableReason, "driver unavailable")
        XCTAssertEqual(machine.status, .windowsWaiting(reason: "driver unavailable"))
        XCTAssertEqual(
            actions,
            [.disableRoute, .refresh]
        )
    }

    func testNewFailureUpdatesExistingWindowsWaitingReason() {
        var machine = readyWindowsMachine()
        _ = machine.updateMouseAvailability(.waiting)

        let actions = machine.updateMouseAvailability(.failed("driver unavailable"))

        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(machine.status, .windowsWaiting(reason: "driver unavailable"))
        XCTAssertEqual(machine.mouseUnavailableReason, "driver unavailable")
        XCTAssertNil(machine.invariantViolation)
    }

    func testStaleOperationCannotCommitOverCurrentOperation() {
        var machine = SoftKVMStateMachine()
        machine.start(enabled: true)
        XCTAssertTrue(machine.beginOperation(id: 1, status: .checking))

        machine.invalidateOperation(reason: "superseded")
        XCTAssertTrue(machine.beginOperation(id: 2, status: .switchingToMac))

        XCTAssertFalse(machine.setStatus(.macReady(remoteName: "stale"), operationID: 1))
        XCTAssertTrue(machine.setStatus(.macReady(remoteName: "current"), operationID: 2))
        XCTAssertEqual(machine.status, .macReady(remoteName: "current"))
        XCTAssertTrue(machine.finishOperation(id: 2))
        XCTAssertNil(machine.invariantViolation)
    }

    func testSuspensionInvalidatesOperationAndFailsClosed() {
        var machine = SoftKVMStateMachine()
        machine.start(enabled: true)
        XCTAssertTrue(machine.beginOperation(id: 7, status: .switchingToWindows))
        machine.setDesiredRouteEnabled(true)

        machine.suspend(systemSleeping: true, sessionInactive: false)

        XCTAssertFalse(machine.routeMayBeEnabled)
        XCTAssertFalse(machine.canStartAutomaticRefresh)
        XCTAssertFalse(machine.desiredRouteEnabled)
        XCTAssertFalse(machine.isCurrentOperation(7))
        XCTAssertEqual(
            machine.status,
            .recoveryNeeded(reason: "系统状态发生变化，需要重新检查显示与输入状态。")
        )
        XCTAssertNil(machine.invariantViolation)
    }

    func testAutomaticRefreshIsBlockedDuringAnOperation() {
        var machine = SoftKVMStateMachine()
        machine.start(enabled: true)
        XCTAssertTrue(machine.canStartAutomaticRefresh)

        XCTAssertTrue(machine.beginOperation(id: 3, status: .checking))

        XCTAssertFalse(machine.canStartAutomaticRefresh)
        XCTAssertTrue(machine.updateMouseAvailability(.standby).isEmpty)
    }

    func testEventQueueProcessesSynchronousFeedbackWithoutRecursion() {
        let queue = RunToCompletionEventQueue<Int>()
        var received: [Int] = []
        var depth = 0
        var maximumDepth = 0

        func handle(_ value: Int) {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            received.append(value)
            if value < 10_000 {
                queue.send(value + 1, handle: handle)
            }
            depth -= 1
        }
        queue.send(0, handle: handle)

        XCTAssertEqual(maximumDepth, 1)
        XCTAssertEqual(received, Array(0...10_000))
    }

    func testFailureFeedbackProducesOnlyOneDisableEffect() {
        enum Event {
            case failed
        }

        let queue = RunToCompletionEventQueue<Event>()
        var machine = readyWindowsMachine()
        var handlerDepth = 0
        var maximumDepth = 0
        var disableCount = 0

        func handle(_ event: Event) {
            handlerDepth += 1
            maximumDepth = max(maximumDepth, handlerDepth)
            defer { handlerDepth -= 1 }

            let actions = machine.updateMouseAvailability(.failed("driver unavailable"))
            for action in actions where action == .disableRoute {
                disableCount += 1
                queue.send(.failed, handle: handle)
            }
        }

        queue.send(.failed, handle: handle)

        XCTAssertEqual(maximumDepth, 1)
        XCTAssertEqual(disableCount, 1)
        XCTAssertEqual(machine.status, .windowsWaiting(reason: "driver unavailable"))
        XCTAssertNil(machine.invariantViolation)
    }

    private func readyWindowsMachine() -> SoftKVMStateMachine {
        var machine = SoftKVMStateMachine()
        machine.start(enabled: true)
        XCTAssertTrue(machine.beginOperation(id: 1, status: .switchingToWindows))
        machine.setDesiredRouteEnabled(true)
        XCTAssertTrue(machine.setStatus(.windowsReady(remoteName: "Windows"), operationID: 1))
        XCTAssertTrue(machine.finishOperation(id: 1))
        XCTAssertNil(machine.invariantViolation)
        return machine
    }
}
