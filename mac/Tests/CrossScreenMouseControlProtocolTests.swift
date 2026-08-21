import Foundation
import XCTest

final class CrossScreenMouseControlProtocolTests: XCTestCase {
    func testMovementScalePreservesFractionalDistance() {
        var scaler = MouseMovementScaler(scaleX: 1.875, scaleY: 1.875)
        var totalX: Int32 = 0
        var totalY: Int32 = 0

        for _ in 0..<8 {
            let movement = scaler.convert(dx: 1, dy: -1)
            totalX += movement.dx
            totalY += movement.dy
        }

        XCTAssertEqual(totalX, 15)
        XCTAssertEqual(totalY, -15)
    }

    func testMovementScaleDoesNotDriftAfterDirectionReversal() {
        var scaler = MouseMovementScaler(scaleX: 1.875, scaleY: 1.875)
        let forward = scaler.convert(dx: 1, dy: 1)
        let backward = scaler.convert(dx: -1, dy: -1)

        XCTAssertEqual(forward.dx + backward.dx, 0)
        XCTAssertEqual(forward.dy + backward.dy, 0)
    }

    func testMovementScaleUsesIndependentAxisRatios() {
        var scaler = MouseMovementScaler(scaleX: 1.875, scaleY: 1.5)
        var totalX: Int32 = 0
        var totalY: Int32 = 0

        for _ in 0..<8 {
            let movement = scaler.convert(dx: 1, dy: 1)
            totalX += movement.dx
            totalY += movement.dy
        }

        XCTAssertEqual(totalX, 15)
        XCTAssertEqual(totalY, 12)
    }

    func testMovementScaleResetDropsPreviousSessionResidual() {
        var scaler = MouseMovementScaler(scaleX: 1.875, scaleY: 1.875)
        _ = scaler.convert(dx: 1, dy: 1)
        scaler.reset()

        XCTAssertEqual(scaler.convert(dx: 1, dy: -1).dx, 1)
        scaler.reset()
        XCTAssertEqual(scaler.convert(dx: 1, dy: -1).dy, -1)
    }

    func testMovementScaleTracksScreenMetricsAndMacGeometry() {
        let scaler = MouseMovementScaler(
            sourceWidth: 2_048,
            sourceHeight: 1_152,
            destination: MouseScreenMetrics(width: 3_840, height: 2_160)
        )

        XCTAssertEqual(scaler.scaleX, 1.875)
        XCTAssertEqual(scaler.scaleY, 1.875)
    }

    func testMovementScaleUsesPhysicalScreenHeightsWhenAvailable() {
        let scaler = MouseMovementScaler(
            sourceWidth: 1_496,
            sourceHeight: 967,
            sourceHeightMM: 223.28908755562523,
            destination: MouseScreenMetrics(width: 3_840, height: 2_160),
            destinationHeightMM: 335.664
        )

        XCTAssertTrue(scaler.usesPhysicalScreenSize)
        XCTAssertEqual(scaler.scaleX, 1.485901463585485, accuracy: 0.000_001)
        XCTAssertEqual(scaler.scaleY, 1.485901463585485, accuracy: 0.000_001)
    }

    func testMovementScaleFallsBackToPixelRatiosWithoutPhysicalHeights() {
        let scaler = MouseMovementScaler(
            sourceWidth: 2_048,
            sourceHeight: 1_152,
            sourceHeightMM: nil,
            destination: MouseScreenMetrics(width: 3_840, height: 2_160),
            destinationHeightMM: 335.664
        )

        XCTAssertFalse(scaler.usesPhysicalScreenSize)
        XCTAssertEqual(scaler.scaleX, 1.875)
        XCTAssertEqual(scaler.scaleY, 1.875)
    }

    func testMovementScaleFallsBackWhenPhysicalHeightsAreInvalid() {
        let scaler = MouseMovementScaler(
            sourceWidth: 2_048,
            sourceHeight: 1_152,
            sourceHeightMM: .infinity,
            destination: MouseScreenMetrics(width: 3_840, height: 2_160),
            destinationHeightMM: 335.664
        )

        XCTAssertFalse(scaler.usesPhysicalScreenSize)
        XCTAssertEqual(scaler.scaleX, 1.875)
        XCTAssertEqual(scaler.scaleY, 1.875)
    }

    func testMouseControlWireIdentifiersRemainStable() {
        XCTAssertEqual(ClipboardWire.magic, [0x4D, 0x45, 0x4E, 0x4F])
        XCTAssertEqual(ClipboardMessageKind.mouseAcquired.rawValue, 15)
        XCTAssertEqual(ClipboardMessageKind.mouseReleased.rawValue, 16)
        XCTAssertEqual(ClipboardMessageKind.mouseControlHeartbeat.rawValue, 17)
        XCTAssertEqual(ClipboardMessageKind.directionalMouseEnter.rawValue, 29)
        XCTAssertEqual(CompanionCapability.directionalMouseHandoff.rawValue, 9)
        XCTAssertEqual(ClipboardMessageKind.diagnosticEvent.rawValue, 31)
        XCTAssertEqual(CompanionCapability.remoteDiagnostics.rawValue, 11)
        XCTAssertEqual(ClipboardMessageKind.mouseEnterV2.rawValue, 32)
        XCTAssertEqual(CompanionCapability.mouseRouteContract.rawValue, 12)
    }

    func testControlPayloadsCarryStableNonzeroSessionID() {
        let controlID: UInt64 = 0x0102_0304_0506_0708

        XCTAssertEqual(
            [UInt8](MousePayload.control(controlID: controlID)),
            [1, 2, 3, 4, 5, 6, 7, 8]
        )
        XCTAssertEqual(MousePayload.decodeControl(MousePayload.control(controlID: controlID)), controlID)
        XCTAssertNil(MousePayload.decodeControl(Data(repeating: 0, count: 8)))
        XCTAssertNil(MousePayload.decodeControl(Data([1, 2, 3, 4, 5, 6, 7])))
    }

    func testEnterAndLeaveCarrySessionAndNormalizedPosition() {
        let payload = MousePayload.enter(controlID: 9, normalizedY: 0xCAFE)

        XCTAssertEqual([UInt8](payload), [0, 0, 0, 0, 0, 0, 0, 9, 0xCA, 0xFE])
        let decoded = MousePayload.decodeLeave(payload)
        XCTAssertEqual(decoded?.controlID, 9)
        XCTAssertEqual(decoded?.normalizedY, 0xCAFE)
    }

    func testDirectionalEnterCarriesStableEntryEdge() {
        let payload = MousePayload.directionalEnter(
            controlID: 9,
            normalizedY: 0xCAFE,
            entryEdge: .right
        )

        XCTAssertEqual(
            [UInt8](payload),
            [0, 0, 0, 0, 0, 0, 0, 9, 0xCA, 0xFE, HorizontalDisplaySide.right.rawValue]
        )
    }

    func testMouseEnterV2MatchesFixedPayloadAndFrameBytes() {
        let payload = MousePayload.enterV2(
            controlID: 0x0102_0304_0506_0708,
            routeID: 0x2122_2324_2526_2728,
            normalizedY: 0xCAFE,
            openingLowerY: 0x1234,
            openingUpperY: 0xABCD,
            entryEdge: .right
        )
        let payloadBytes: [UInt8] = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
            0xCA, 0xFE,
            0x12, 0x34,
            0xAB, 0xCD,
            0x02,
        ]

        XCTAssertEqual(ClipboardWire.mouseEnterV2PayloadSize, 23)
        XCTAssertEqual([UInt8](payload), payloadBytes)
        XCTAssertEqual(
            MousePayload.decodeEnterV2(payload),
            MouseEnterV2Payload(
                controlID: 0x0102_0304_0506_0708,
                routeID: 0x2122_2324_2526_2728,
                normalizedY: 0xCAFE,
                openingLowerY: 0x1234,
                openingUpperY: 0xABCD,
                entryEdge: .right
            )
        )

        let frame = ClipboardFrame(
            kind: .mouseEnterV2,
            messageID: 0x1112_1314_1516_1718,
            payload: payload
        ).encoded()
        XCTAssertEqual(
            [UInt8](frame),
            [
                0x4D, 0x45, 0x4E, 0x4F,
                0x20, 0x00, 0x00, 0x00,
                0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
                0x00, 0x00, 0x00, 0x17,
            ] + payloadBytes
        )
    }

    func testMouseEnterV2RejectsMalformedPayloads() {
        let valid = MousePayload.enterV2(
            controlID: 1,
            routeID: 2,
            normalizedY: 3,
            openingLowerY: 4,
            openingUpperY: 5,
            entryEdge: .left
        )

        XCTAssertNil(MousePayload.decodeEnterV2(valid.dropLast()))
        XCTAssertNil(MousePayload.decodeEnterV2(valid + Data([0])))

        var zeroControlID = valid
        zeroControlID.replaceSubrange(0...7, with: repeatElement(0, count: 8))
        XCTAssertNil(MousePayload.decodeEnterV2(zeroControlID))

        var zeroRouteID = valid
        zeroRouteID.replaceSubrange(8...15, with: repeatElement(0, count: 8))
        XCTAssertNil(MousePayload.decodeEnterV2(zeroRouteID))

        var reversedOpening = valid
        reversedOpening.replaceSubrange(18...21, with: [0, 6, 0, 5])
        XCTAssertNil(MousePayload.decodeEnterV2(reversedOpening))

        for invalidEdge in [UInt8(0), 3, .max] {
            var invalid = valid
            invalid[22] = invalidEdge
            XCTAssertNil(MousePayload.decodeEnterV2(invalid))
        }
    }

    func testMoveRoundTripPreservesSessionAndSamples() {
        let samples = [
            MouseMoveSample(dx: -32_767, dy: 32_767),
            MouseMoveSample(dx: 123, dy: -456),
        ]
        let payload = MousePayload.move(controlID: 42, samples: samples)

        XCTAssertEqual(payload.count, 17)
        XCTAssertEqual(payload[8], 2)
        XCTAssertEqual(MousePayload.decodeMove(payload), MouseMovePayload(controlID: 42, samples: samples))
    }

    func testMoveRejectsZeroSessionAndInvalidBatchCounts() {
        let valid = MousePayload.move(
            controlID: 1,
            samples: [MouseMoveSample(dx: 1, dy: -1)]
        )
        var zeroSession = valid
        zeroSession.replaceSubrange(0...7, with: repeatElement(0, count: 8))
        let prefix = Data([0, 0, 0, 0, 0, 0, 0, 1])
        let zeroBatch = prefix + Data([0])
        let oversizedCount = ClipboardWire.maximumMouseMoveBatch + 1
        let oversizedBatch = prefix
            + Data([UInt8(oversizedCount)])
            + Data(repeating: 0, count: oversizedCount * 4)

        XCTAssertNil(MousePayload.decodeMove(zeroSession))
        XCTAssertNil(MousePayload.decodeMove(zeroBatch))
        XCTAssertNil(MousePayload.decodeMove(oversizedBatch))
        XCTAssertNil(MousePayload.decodeMove(valid.dropLast()))
    }

    func testZeroMovementDoesNotCreateNoopSample() {
        XCTAssertTrue(MousePayload.split(dx: 0, dy: 0).isEmpty)
    }

    func testButtonWheelAndKeyboardPayloadsUseSameSessionPrefix() {
        let prefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 7]
        let button = MousePayload.button(controlID: 7, button: 2, down: true)
        let wheel = MousePayload.wheel(controlID: 7, lines: -120)
        let keyboard = MousePayload.keyboard(
            controlID: 7,
            report: KeyboardReport(modifiers: 1, usages: [0x04])
        )

        XCTAssertEqual(button.count, 10)
        XCTAssertEqual(Array(button.prefix(8)), prefix)
        XCTAssertEqual(Array(button.suffix(2)), [2, 1])
        XCTAssertEqual(wheel.count, 12)
        XCTAssertEqual(Array(wheel.prefix(8)), prefix)
        XCTAssertEqual(Array(wheel.suffix(4)), [0xFF, 0xFF, 0xFF, 0x88])
        XCTAssertEqual(keyboard.count, 16)
        XCTAssertEqual(Array(keyboard.prefix(8)), prefix)
        XCTAssertEqual(Array(keyboard.dropFirst(8)), [1, 1, 0x04, 0, 0, 0, 0, 0])
    }

    func testWheelAccumulatorPreservesFractionalInputUntilOneLine() {
        var accumulator = MouseWheelAccumulator()

        accumulator.add(0.25)
        accumulator.add(0.5)
        XCTAssertEqual(accumulator.drain(), 0)
        XCTAssertEqual(accumulator.pendingLines, 0.75)
        accumulator.add(0.25)
        XCTAssertEqual(accumulator.drain(), 1)
        XCTAssertEqual(accumulator.pendingLines, 0)
    }

    func testWheelAccumulatorDoesNotMissDecimalThresholds() {
        var accumulator = MouseWheelAccumulator()

        for _ in 0..<10 {
            accumulator.add(0.1)
        }
        XCTAssertEqual(accumulator.drain(), 1)
        XCTAssertEqual(accumulator.pendingLines, 0)

        for _ in 0..<10 {
            accumulator.add(-0.1)
        }
        XCTAssertEqual(accumulator.drain(), -1)
        XCTAssertEqual(accumulator.pendingLines, 0)
    }

    func testWheelInputPreservesCoarseNotchesAndNormalizesContinuousInput() {
        XCTAssertEqual(
            MouseWheelInput.normalized(
                1,
                isContinuous: false,
                directionInvertedFromDevice: false
            ),
            1
        )
        XCTAssertEqual(
            MouseWheelInput.normalized(
                1.5,
                isContinuous: true,
                directionInvertedFromDevice: false
            ),
            0.5
        )
        XCTAssertEqual(
            MouseWheelInput.normalized(
                3,
                isContinuous: true,
                directionInvertedFromDevice: true
            ),
            -1
        )
    }

    func testWheelAccumulatorCancelsSublineDirectionChanges() {
        var accumulator = MouseWheelAccumulator()

        accumulator.add(0.5)
        accumulator.add(0.25)
        accumulator.add(-0.5)

        XCTAssertEqual(accumulator.drain(), 0)
        XCTAssertEqual(accumulator.pendingLines, 0.25)
    }

    func testWheelAccumulatorPreservesSignedRemainderAndMultipleLines() {
        var accumulator = MouseWheelAccumulator()

        accumulator.add(-2.25)
        XCTAssertEqual(accumulator.drain(), -2)
        XCTAssertEqual(accumulator.pendingLines, -0.25)
        accumulator.reset()
        XCTAssertEqual(accumulator.pendingLines, 0)
    }

    func testWheelAccumulatorRespectsAnExplicitDrainLimit() {
        var accumulator = MouseWheelAccumulator()

        accumulator.add(4)
        XCTAssertEqual(accumulator.drain(maximumLines: 1), 1)
        XCTAssertEqual(accumulator.pendingLines, 3)
        XCTAssertEqual(accumulator.drain(maximumLines: 1), 1)
        XCTAssertEqual(accumulator.pendingLines, 2)
    }

    func testWheelAccumulatorBoundsBacklogInBothDirections() {
        var accumulator = MouseWheelAccumulator()

        accumulator.add(MouseWheelAccumulator.maximumBufferedLines * 2)
        XCTAssertEqual(accumulator.pendingLines, MouseWheelAccumulator.maximumBufferedLines)
        accumulator.add(-MouseWheelAccumulator.maximumBufferedLines * 2)
        XCTAssertEqual(accumulator.pendingLines, -MouseWheelAccumulator.maximumBufferedLines)
    }

    func testWheelAccumulatorIgnoresNonfiniteInput() {
        var accumulator = MouseWheelAccumulator()

        accumulator.add(.nan)
        accumulator.add(.infinity)
        accumulator.add(-.infinity)

        XCTAssertEqual(accumulator.pendingLines, 0)
        accumulator.add(1)
        XCTAssertEqual(accumulator.drain(), 1)
        XCTAssertEqual(accumulator.pendingLines, 0)
    }

    func testMailboxDirectionalLeftEntryAndResidualShareFirstWrite() throws {
        var mailbox = readyMailbox(width: 100, height: 81)

        XCTAssertEqual(
            mailbox.beginSession(
                controlID: 7,
                normalizedY: 32_768,
                residualX: 9,
                returnOpeningY: 0...80
            ),
            .scheduleDrain
        )
        let frames = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(frames.map(\.kind), [.directionalMouseEnter, .mouseMove])
        XCTAssertEqual(mailbox.sessionPosition?.x, 10)
        XCTAssertEqual(mailbox.sessionPosition?.y, 40)
        let move = try XCTUnwrap(MousePayload.decodeMove(frames[1].payload))
        XCTAssertEqual(move.samples, [MouseMoveSample(dx: 9, dy: 0)])
    }

    func testMailboxDirectionalRightEntryAndResidualShareFirstWrite() throws {
        var mailbox = readyMailbox(width: 100, height: 81)

        XCTAssertEqual(
            mailbox.beginSession(
                controlID: 7,
                normalizedY: 32_768,
                residualX: -9,
                entryEdge: .right,
                returnOpeningY: 0...80
            ),
            .scheduleDrain
        )
        let frames = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(frames.map(\.kind), [.directionalMouseEnter, .mouseMove])
        XCTAssertEqual(mailbox.sessionPosition?.x, 89)
        XCTAssertEqual(mailbox.sessionPosition?.y, 40)
        let move = try XCTUnwrap(MousePayload.decodeMove(frames[1].payload))
        XCTAssertEqual(move.samples, [MouseMoveSample(dx: -9, dy: 0)])
    }

    func testMailboxClampsEachSampleBeforeDirectionReversal() throws {
        var mailbox = activeMailbox(width: 100, height: 100, residualX: 49)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 100, dy: 0), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -10, dy: 0), .queued)
        let frame = try XCTUnwrap(mailbox.dequeue(maximumFrameCount: 4).first)
        let move = try XCTUnwrap(MousePayload.decodeMove(frame.payload))

        XCTAssertEqual(mailbox.sessionPosition?.x, 89)
        XCTAssertEqual(move.samples, [MouseMoveSample(dx: 39, dy: 0)])
    }

    func testMailboxKeepsFirstLeftEdgeReturnCandidate() throws {
        var mailbox = activeMailbox(width: 100, height: 100, residualX: 49)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -100, dy: 8), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 20, dy: 0), .ignored)
        let frame = try XCTUnwrap(mailbox.dequeue(maximumFrameCount: 4).first)
        let move = try XCTUnwrap(MousePayload.decodeMove(frame.payload))

        XCTAssertTrue(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 0)
        XCTAssertEqual(move.samples.last?.dx, -50)
        XCTAssertEqual(move.samples.reduce(0) { $0 + Int($1.dy) }, 8)
    }

    func testMailboxKeepsFirstRightEdgeReturnCandidate() throws {
        var mailbox = activeMailbox(
            width: 100,
            height: 100,
            residualX: -49,
            entryEdge: .right
        )

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 100, dy: 8), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -20, dy: 0), .ignored)
        let frame = try XCTUnwrap(mailbox.dequeue(maximumFrameCount: 4).first)
        let move = try XCTUnwrap(MousePayload.decodeMove(frame.payload))

        XCTAssertTrue(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 99)
        XCTAssertEqual(move.samples.last?.dx, 50)
        XCTAssertEqual(move.samples.reduce(0) { $0 + Int($1.dy) }, 8)
    }

    func testMailboxBuildsRemoteWallUntilCursorReachesReturnOpening() {
        var mailbox = activeMailbox(
            width: 100,
            height: 100,
            residualX: 49,
            returnOpeningY: 40...99
        )

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -100, dy: 0), .scheduleDrain)
        XCTAssertFalse(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 1)
        XCTAssertEqual(mailbox.sessionPosition?.y, 0)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -4, dy: 50), .scheduleDrain)
        XCTAssertTrue(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 0)
        XCTAssertEqual(mailbox.sessionPosition?.y, 50)
    }

    func testMailboxBuildsMirroredRemoteWallAtRightEntryEdge() {
        var mailbox = activeMailbox(
            width: 100,
            height: 100,
            residualX: -49,
            entryEdge: .right,
            returnOpeningY: 40...99
        )

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 100, dy: 0), .scheduleDrain)
        XCTAssertFalse(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 98)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 4, dy: 50), .scheduleDrain)
        XCTAssertTrue(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 99)
        XCTAssertEqual(mailbox.sessionPosition?.y, 50)
    }

    func testMailboxButtonReleaseOutsideOpeningDoesNotEscapeRemoteWall() {
        var mailbox = activeMailbox(
            width: 100,
            height: 100,
            residualX: 49,
            returnOpeningY: 40...99
        )

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .scheduleDrain
        )
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -100, dy: 0), .scheduleDrain)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: false),
            .scheduleDrain
        )
        XCTAssertFalse(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.sessionPosition?.x, 1)
    }

    func testMailboxPreservesAtBoundaryLeftProbe() throws {
        var mailbox = activeMailbox(width: 1, height: 100)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -4, dy: 3), .scheduleDrain)
        let frame = try XCTUnwrap(mailbox.dequeue(maximumFrameCount: 4).first)
        let move = try XCTUnwrap(MousePayload.decodeMove(frame.payload))

        XCTAssertEqual(move.samples.last, MouseMoveSample(dx: -1, dy: 0))
        XCTAssertEqual(move.samples.reduce(0) { $0 + Int($1.dy) }, 3)
        XCTAssertTrue(mailbox.isWaitingForLeave)
    }

    func testMailboxPreservesAtBoundaryRightProbe() throws {
        var mailbox = activeMailbox(
            width: 1,
            height: 100,
            entryEdge: .right
        )

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 4, dy: 3), .scheduleDrain)
        let frame = try XCTUnwrap(mailbox.dequeue(maximumFrameCount: 4).first)
        let move = try XCTUnwrap(MousePayload.decodeMove(frame.payload))

        XCTAssertEqual(move.samples.last, MouseMoveSample(dx: 1, dy: 0))
        XCTAssertEqual(move.samples.reduce(0) { $0 + Int($1.dy) }, 3)
        XCTAssertTrue(mailbox.isWaitingForLeave)
    }

    func testMailboxButtonHeldAtEdgeLeavesOnlyAfterButtonUp() {
        var mailbox = activeMailbox(width: 100, height: 100)

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .scheduleDrain
        )
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -10, dy: 0), .scheduleDrain)
        XCTAssertFalse(mailbox.isWaitingForLeave)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: false),
            .scheduleDrain
        )
        XCTAssertTrue(mailbox.isWaitingForLeave)
    }

    func testMailboxButtonHeldAtRightEdgeLeavesOnlyAfterButtonUp() {
        var mailbox = activeMailbox(
            width: 100,
            height: 100,
            entryEdge: .right
        )

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .scheduleDrain
        )
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 10, dy: 0), .scheduleDrain)
        XCTAssertFalse(mailbox.isWaitingForLeave)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: false),
            .scheduleDrain
        )
        XCTAssertTrue(mailbox.isWaitingForLeave)
    }

    func testMailboxPreservesHeldLeftProbeWhenAlreadyAtBoundary() throws {
        var mailbox = activeMailbox(width: 1, height: 100)

        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .scheduleDrain
        )
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -4, dy: 3), .scheduleDrain)
        let frame = try XCTUnwrap(mailbox.dequeue(maximumFrameCount: 4).first)
        let move = try XCTUnwrap(MousePayload.decodeMove(frame.payload))

        XCTAssertEqual(move.samples.last, MouseMoveSample(dx: -1, dy: 0))
        XCTAssertEqual(move.samples.reduce(0) { $0 + Int($1.dy) }, 3)
        XCTAssertFalse(mailbox.isWaitingForLeave)
    }

    func testMailboxCanReleaseWhileWaitingForEdgeLeaveAcknowledgement() {
        var mailbox = activeMailbox(width: 100, height: 100)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: -10, dy: 0), .scheduleDrain)
        XCTAssertTrue(mailbox.isWaitingForLeave)
        XCTAssertEqual(mailbox.enqueueRelease(controlID: 7), .queued)

        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).map(\.kind),
            [.mouseMove, .keyboardState, .mouseReleaseAll]
        )
    }

    func testMailboxAbortDropsUnsentInputAndPrioritizesRelease() {
        var mailbox = activeMailbox(width: 100, height: 100)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 12, dy: 3), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueButton(controlID: 7, button: 1, down: true), .queued)
        XCTAssertEqual(mailbox.enqueueHeartbeat(controlID: 7), .queued)
        XCTAssertEqual(mailbox.abortControl(controlID: 7), .queued)

        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).map(\.kind),
            [.keyboardState, .mouseReleaseAll]
        )
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 1, dy: 0), .ignored)
        XCTAssertTrue(mailbox.dequeue(maximumFrameCount: 4).isEmpty)
    }

    func testMailboxAbortUpgradesAnAlreadyQueuedNormalRelease() {
        var mailbox = activeMailbox(width: 100, height: 100)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 12, dy: 3), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueRelease(controlID: 7), .queued)
        XCTAssertEqual(mailbox.abortControl(controlID: 7), .queued)

        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).map(\.kind),
            [.keyboardState, .mouseReleaseAll]
        )
    }

    func testMailboxAbortCanRecoverAFullQueueWithoutDroppingRelease() {
        var mailbox = MouseOutboundMailbox(maximumItems: 2)
        mailbox.activate(
            screenMetrics: MouseScreenMetrics(width: 100, height: 100),
            keyboardSupported: true
        )
        XCTAssertEqual(
            mailbox.beginSession(
                controlID: 7,
                normalizedY: 0,
                residualX: 0,
                returnOpeningY: 0...99
            ),
            .scheduleDrain
        )
        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .queued
        )

        XCTAssertEqual(mailbox.abortControl(controlID: 7), .queued)
        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).map(\.kind),
            [.keyboardState, .mouseReleaseAll]
        )
    }

    func testMailboxAbortPrioritizesReleaseAheadOfConnectionFrames() {
        var mailbox = readyMailbox(width: 100, height: 100)
        XCTAssertEqual(
            mailbox.enqueueConnectionFrame(kind: .ping, payload: Data()),
            .scheduleDrain
        )
        XCTAssertEqual(
            mailbox.beginSession(
                controlID: 7,
                normalizedY: 0,
                residualX: 0,
                returnOpeningY: 0...99
            ),
            .queued
        )
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 4, dy: 0), .queued)

        XCTAssertEqual(mailbox.abortControl(controlID: 7), .queued)
        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).map(\.kind),
            [.keyboardState, .mouseReleaseAll, .ping]
        )
    }

    func testMailboxDeduplicatesConsecutiveFreshnessHeartbeats() {
        var mailbox = activeMailbox(width: 100, height: 100)

        XCTAssertEqual(mailbox.enqueueHeartbeat(controlID: 7), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueHeartbeat(controlID: 7), .queued)

        XCTAssertEqual(mailbox.queuedItemCount, 1)
    }

    func testMailboxHeartbeatRefreshesHeldKeyboardStateAndDeduplicates() {
        var mailbox = activeMailbox(width: 100, height: 100)
        let report = KeyboardReport(modifiers: 1, usages: [0x04])
        XCTAssertEqual(mailbox.enqueueKeyboard(controlID: 7, report: report), .scheduleDrain)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(mailbox.enqueueHeartbeat(controlID: 7), .scheduleDrain)
        XCTAssertEqual(mailbox.enqueueHeartbeat(controlID: 7), .queued)
        let frames = mailbox.dequeue(maximumFrameCount: 4)

        XCTAssertEqual(frames.map(\.kind), [.mouseControlHeartbeat, .keyboardState])
        XCTAssertEqual(frames[1].payload, MousePayload.keyboard(controlID: 7, report: report))
    }

    func testMailboxSchedulesOnlyOneDrainUntilQueueIsObservedEmpty() {
        var mailbox = activeMailbox(width: 1_000, height: 100, residualX: 100)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 1, dy: 0), .scheduleDrain)
        for _ in 0..<100 {
            XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 1, dy: 0), .queued)
        }
        XCTAssertEqual(mailbox.queuedItemCount, 1)
        XCTAssertFalse(mailbox.dequeue(maximumFrameCount: 4).isEmpty)
        XCTAssertTrue(mailbox.dequeue(maximumFrameCount: 4).isEmpty)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 1, dy: 0), .scheduleDrain)
    }

    func testMailboxSendsMultipleWheelLinesImmediatelyAndResetsIdleResidual() {
        var mailbox = activeMailbox(width: 100, height: 100)
        let start = ContinuousClock.now

        XCTAssertEqual(
            mailbox.enqueueWheel(controlID: 7, inputLines: 2.25, capturedAt: start),
            .scheduleDrain
        )
        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).first?.payload,
            MousePayload.wheel(controlID: 7, lines: 2)
        )
        _ = mailbox.dequeue(maximumFrameCount: 4)
        XCTAssertEqual(
            mailbox.enqueueWheel(
                controlID: 7,
                inputLines: 0.5,
                capturedAt: start.advanced(by: .milliseconds(20))
            ),
            .ignored
        )

        XCTAssertEqual(
            mailbox.enqueueWheel(
                controlID: 7,
                inputLines: 0.5,
                capturedAt: start.advanced(by: .milliseconds(150))
            ),
            .ignored
        )
        XCTAssertEqual(
            mailbox.enqueueWheel(
                controlID: 7,
                inputLines: 0.5,
                capturedAt: start.advanced(by: .milliseconds(160))
            ),
            .scheduleDrain
        )
        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).first?.payload,
            MousePayload.wheel(controlID: 7, lines: 1)
        )
    }

    func testMailboxBoundsAnAbnormalWheelBurst() {
        var mailbox = activeMailbox(width: 100, height: 100)

        XCTAssertEqual(
            mailbox.enqueueWheel(controlID: 7, inputLines: 1_000),
            .scheduleDrain
        )
        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).first?.payload,
            MousePayload.wheel(
                controlID: 7,
                lines: Int32(MouseWheelAccumulator.maximumBufferedLines)
            )
        )
    }

    func testMailboxDoesNotMergeMovementAcrossButtonBoundary() {
        var mailbox = activeMailbox(width: 100, height: 100, residualX: 20)

        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 3, dy: 0), .scheduleDrain)
        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .queued
        )
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 4, dy: 0), .queued)

        XCTAssertEqual(
            mailbox.dequeue(maximumFrameCount: 4).map(\.kind),
            [.mouseMove, .mouseButton, .mouseMove]
        )
    }

    func testMailboxFailsInsteadOfDroppingBoundaryWhenFull() {
        var mailbox = MouseOutboundMailbox(maximumItems: 2)
        mailbox.activate(
            screenMetrics: MouseScreenMetrics(width: 100, height: 100),
            keyboardSupported: true
        )

        XCTAssertEqual(
            mailbox.beginSession(
                controlID: 7,
                normalizedY: 0,
                residualX: 0,
                returnOpeningY: 0...99
            ),
            .scheduleDrain
        )
        XCTAssertEqual(
            mailbox.enqueueButton(controlID: 7, button: 1, down: true),
            .queued
        )
        XCTAssertEqual(mailbox.enqueueWheel(controlID: 7, inputLines: 1), .failed)
    }

    func testMailboxFinishSessionClearsStaleInput() {
        var mailbox = activeMailbox(width: 100, height: 100)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 3, dy: 0), .scheduleDrain)

        mailbox.finishSession(controlID: 7)

        XCTAssertEqual(mailbox.queuedItemCount, 0)
        XCTAssertNil(mailbox.sessionPosition)
        XCTAssertEqual(mailbox.enqueueMove(controlID: 7, dx: 3, dy: 0), .ignored)
    }

    func testMailboxPreservesRemoteShutdownAsAnOrderedConnectionFrame() {
        var mailbox = readyMailbox(width: 100, height: 100)

        XCTAssertEqual(
            mailbox.enqueueConnectionFrame(kind: .shutdownRequest, payload: Data()),
            .scheduleDrain
        )

        let frames = mailbox.dequeue(maximumFrameCount: 4)
        XCTAssertEqual(frames.map(\.kind), [.shutdownRequest])
        XCTAssertEqual(frames.first?.payload, Data())
        XCTAssertNil(frames.first?.controlID)
    }

    func testHelloNegotiatesOnlySupportedCapabilities() throws {
        let payload = CompanionHello(
            name: "Windows",
            capabilities: [
                .mouseControl,
                .keyboardState,
                .remoteShutdown,
                .directionalMouseHandoff,
                .remoteDiagnostics,
                .mouseRouteContract,
            ],
            driverABI: 4,
            screenWidth: 3_840,
            screenHeight: 2_160
        ).encoded()

        let peer = try XCTUnwrap(MousePayload.decodeHello(payload))

        XCTAssertEqual(peer.name, "Windows")
        XCTAssertTrue(peer.driverAvailable)
        XCTAssertEqual(peer.screenMetrics, MouseScreenMetrics(width: 3_840, height: 2_160))
        XCTAssertEqual(
            peer.capabilities,
            [
                .mouseControl,
                .keyboardState,
                .remoteShutdown,
                .directionalMouseHandoff,
                .mouseRouteContract,
            ]
        )
        XCTAssertTrue(peer.keyboardSupported)
        XCTAssertTrue(peer.remoteShutdownSupported)
        XCTAssertTrue(peer.directionalHandoffSupported)
        XCTAssertTrue(peer.routeContractSupported)
    }

    func testHelloKeepsCapabilitiesIndependentFromDriverAvailability() throws {
        let payload = CompanionHello(
            name: "Windows",
            capabilities: [.mouseControl, .keyboardState],
            driverABI: 0,
            screenWidth: 3_840,
            screenHeight: 2_160
        ).encoded()

        let peer = try XCTUnwrap(MousePayload.decodeHello(payload))

        XCTAssertFalse(peer.driverAvailable)
        XCTAssertEqual(peer.capabilities, [.mouseControl, .keyboardState])
        XCTAssertTrue(peer.keyboardSupported)
        XCTAssertFalse(peer.remoteShutdownSupported)
    }

    func testRemoteShutdownCapabilityDoesNotRequireMouseDriver() throws {
        let payload = CompanionHello(
            name: "Windows",
            capabilities: [.mouseControl, .remoteShutdown],
            driverABI: 0,
            screenWidth: 3_840,
            screenHeight: 2_160
        ).encoded()

        let peer = try XCTUnwrap(MousePayload.decodeHello(payload))

        XCTAssertFalse(peer.driverAvailable)
        XCTAssertTrue(peer.remoteShutdownSupported)
    }

    func testHelloRequiresMouseCapabilityDriverABIAndScreenMetrics() {
        XCTAssertNil(
            MousePayload.decodeHello(
                CompanionHello(
                    name: "Windows",
                    capabilities: [.keyboardState],
                    driverABI: 4,
                    screenWidth: 3_840,
                    screenHeight: 2_160
                ).encoded()
            )
        )
        XCTAssertNil(
            MousePayload.decodeHello(
                CompanionHello(
                    name: "Windows",
                    capabilities: [.mouseControl],
                    driverABI: 4,
                    screenWidth: 3_840,
                    screenHeight: 2_160,
                    audioPort: 48_000
                ).encoded()
            )
        )
        XCTAssertNil(
            MousePayload.decodeHello(
                CompanionHello(
                    name: "Windows",
                    capabilities: [.mouseControl],
                    driverABI: nil,
                    screenWidth: 3_840,
                    screenHeight: 2_160
                ).encoded()
            )
        )
        XCTAssertNil(
            MousePayload.decodeHello(
                CompanionHello(
                    name: "Windows",
                    capabilities: [.mouseControl],
                    driverABI: 4,
                    screenWidth: 0,
                    screenHeight: 2_160
                ).encoded()
            )
        )
        XCTAssertNil(
            MousePayload.decodeHello(
                CompanionHello(
                    name: "Windows",
                    capabilities: [.mouseControl],
                    driverABI: 4,
                    screenWidth: 3_840,
                    screenHeight: 0
                ).encoded()
            )
        )
        XCTAssertNil(
            MousePayload.decodeHello(
                CompanionHello(
                    name: "Windows",
                    capabilities: [.mouseControl],
                    driverABI: 4,
                    screenWidth: UInt32(Int32.max) + 1,
                    screenHeight: 2_160
                ).encoded()
            )
        )
    }

    private func readyMailbox(
        width: UInt32,
        height: UInt32,
        keyboardSupported: Bool = true
    ) -> MouseOutboundMailbox {
        var mailbox = MouseOutboundMailbox()
        mailbox.activate(
            screenMetrics: MouseScreenMetrics(width: width, height: height),
            keyboardSupported: keyboardSupported
        )
        return mailbox
    }

    private func activeMailbox(
        width: UInt32,
        height: UInt32,
        residualX: Int32 = 0,
        entryEdge: HorizontalDisplaySide = .left,
        returnOpeningY: ClosedRange<Int32>? = nil
    ) -> MouseOutboundMailbox {
        var mailbox = readyMailbox(width: width, height: height)
        _ = mailbox.beginSession(
            controlID: 7,
            normalizedY: 0,
            residualX: residualX,
            entryEdge: entryEdge,
            returnOpeningY: returnOpeningY
                ?? (Int32.zero...Int32(clamping: height - 1))
        )
        _ = mailbox.dequeue(maximumFrameCount: 4)
        _ = mailbox.dequeue(maximumFrameCount: 4)
        return mailbox
    }
}
