import XCTest

final class MouseTransportQueueTests: XCTestCase {
    func testEnterUsesRouteContractAndKeepsResidualMovementOrdered() throws {
        var queue = readyQueue()

        XCTAssertEqual(
            queue.beginSession(
                controlID: 7,
                routeID: 9,
                normalizedY: 32_768,
                residualX: 12,
                entryEdge: .right,
                returnOpeningY: 10_000...50_000
            ),
            .scheduleDrain
        )
        let frames = queue.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(frames.map(\.kind), [.mouseEnterV2, .mouseMove])
        XCTAssertEqual(
            MousePayload.decodeEnterV2(frames[0].payload),
            MouseEnterV2Payload(
                controlID: 7,
                routeID: 9,
                normalizedY: 32_768,
                openingLowerY: 10_000,
                openingUpperY: 50_000,
                entryEdge: .right
            )
        )
        XCTAssertEqual(
            MousePayload.decodeMove(frames[1].payload)?.samples,
            [MouseMoveSample(dx: 12, dy: 0)]
        )
    }

    func testConsecutiveMovementIsPackedWithoutCollapsingSamples() throws {
        var queue = activeQueue()

        XCTAssertEqual(queue.enqueueMove(controlID: 7, dx: 3, dy: 2), .scheduleDrain)
        XCTAssertEqual(queue.enqueueMove(controlID: 7, dx: -4, dy: 1), .queued)

        let frame = try XCTUnwrap(queue.dequeue(maximumFrameCount: 4).first)
        XCTAssertEqual(
            MousePayload.decodeMove(frame.payload)?.samples,
            [MouseMoveSample(dx: 3, dy: 2), MouseMoveSample(dx: -4, dy: 1)]
        )
    }

    func testMovementNeverMergesAcrossButtonBoundary() throws {
        var queue = activeQueue()

        XCTAssertEqual(queue.enqueueMove(controlID: 7, dx: 3, dy: 0), .scheduleDrain)
        XCTAssertEqual(queue.enqueueButton(controlID: 7, button: 1, down: true), .queued)
        XCTAssertEqual(queue.enqueueMove(controlID: 7, dx: 4, dy: 0), .queued)

        XCTAssertEqual(
            queue.dequeue(maximumFrameCount: 4).map(\.kind),
            [.mouseMove, .mouseButton, .mouseMove]
        )
    }

    func testMovementOrderIsPreservedAcrossEverySemanticBoundary() throws {
        var queue = activeQueue()
        let report = KeyboardReport(modifiers: 1, usages: [0x04])

        _ = queue.enqueueMove(controlID: 7, dx: 1, dy: 0)
        _ = queue.enqueueButton(controlID: 7, button: 1, down: true)
        _ = queue.enqueueMove(controlID: 7, dx: 2, dy: 0)
        _ = queue.enqueueWheel(controlID: 7, inputLines: 1)
        _ = queue.enqueueMove(controlID: 7, dx: 3, dy: 0)
        _ = queue.enqueueKeyboard(controlID: 7, report: report)
        _ = queue.enqueueMove(controlID: 7, dx: 4, dy: 0)
        _ = queue.enqueueRelease(controlID: 7)

        var frames: [MouseOutboundFrameSpec] = []
        while true {
            let batch = queue.dequeue(maximumFrameCount: 4)
            guard !batch.isEmpty else { break }
            frames.append(contentsOf: batch)
        }
        XCTAssertEqual(
            frames.map(\.kind),
            [
                .mouseMove, .mouseButton, .mouseMove, .mouseWheel,
                .mouseMove, .keyboardState, .mouseMove,
                .keyboardState, .mouseReleaseAll,
            ]
        )
        let movement = frames.filter { $0.kind == .mouseMove }.compactMap {
            MousePayload.decodeMove($0.payload)?.samples.first?.dx
        }
        XCTAssertEqual(movement, [1, 2, 3, 4])
    }

    func testMovementIsNotClampedToRemoteScreenOrEntryEdge() throws {
        var queue = activeQueue()

        XCTAssertEqual(
            queue.enqueueMove(controlID: 7, dx: 100_000, dy: -100_000),
            .scheduleDrain
        )
        let frames = queue.dequeue(maximumFrameCount: 8)
        let samples = try frames.flatMap { frame in
            try XCTUnwrap(MousePayload.decodeMove(frame.payload)).samples
        }

        XCTAssertEqual(samples.reduce(Int64.zero) { $0 + Int64($1.dx) }, 100_000)
        XCTAssertEqual(samples.reduce(Int64.zero) { $0 + Int64($1.dy) }, -100_000)
    }

    func testFullQueueFailsInsteadOfDroppingInputBoundary() {
        var queue = MouseTransportQueue(maximumItems: 2)
        queue.activate(keyboardSupported: true)
        _ = queue.beginSession(
            controlID: 7,
            routeID: 9,
            normalizedY: 0,
            residualX: 0,
            entryEdge: .left,
            returnOpeningY: 0...UInt16.max
        )
        XCTAssertEqual(queue.enqueueButton(controlID: 7, button: 1, down: true), .queued)
        XCTAssertEqual(queue.enqueueWheel(controlID: 7, inputLines: 1), .failed)
    }

    func testAbortDropsQueuedSessionInputAndPrioritizesRelease() {
        var queue = activeQueue()
        _ = queue.enqueueMove(controlID: 7, dx: 12, dy: 3)
        _ = queue.enqueueButton(controlID: 7, button: 1, down: true)

        XCTAssertEqual(queue.abortControl(controlID: 7), .queued)
        XCTAssertEqual(
            queue.dequeue(maximumFrameCount: 4).map(\.kind),
            [.keyboardState, .mouseReleaseAll]
        )
        XCTAssertEqual(queue.enqueueMove(controlID: 7, dx: 1, dy: 0), .ignored)
    }

    func testHeartbeatRefreshesHeldKeyboardAndDeduplicates() {
        var queue = activeQueue()
        let report = KeyboardReport(modifiers: 1, usages: [0x04])
        _ = queue.enqueueKeyboard(controlID: 7, report: report)
        _ = queue.dequeue(maximumFrameCount: 4)
        _ = queue.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(queue.enqueueHeartbeat(controlID: 7), .scheduleDrain)
        XCTAssertEqual(queue.enqueueHeartbeat(controlID: 7), .queued)
        let frames = queue.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(frames.map(\.kind), [.mouseControlHeartbeat, .keyboardState])
        XCTAssertEqual(frames[1].payload, MousePayload.keyboard(controlID: 7, report: report))
    }

    private func readyQueue() -> MouseTransportQueue {
        var queue = MouseTransportQueue()
        queue.activate(keyboardSupported: true)
        return queue
    }

    private func activeQueue() -> MouseTransportQueue {
        var queue = readyQueue()
        _ = queue.beginSession(
            controlID: 7,
            routeID: 9,
            normalizedY: 0,
            residualX: 0,
            entryEdge: .left,
            returnOpeningY: 0...UInt16.max
        )
        _ = queue.dequeue(maximumFrameCount: 4)
        _ = queue.dequeue(maximumFrameCount: 4)
        return queue
    }
}
