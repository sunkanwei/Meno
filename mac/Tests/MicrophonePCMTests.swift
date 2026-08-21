import Foundation
import XCTest

final class MicrophonePCMTests: XCTestCase {
    func testCapturePoolAcceptsObserved4800FrameHardwareCallbacks() {
        XCTAssertGreaterThanOrEqual(
            MicrophoneCaptureConfiguration.bufferFrameCapacity,
            4_800
        )
    }

    func testQuantizationClampsAndUsesTheFixedSignedRanges() {
        XCTAssertEqual(MicrophonePCM.quantize(-2), -32_768)
        XCTAssertEqual(MicrophonePCM.quantize(-1), -32_768)
        XCTAssertEqual(MicrophonePCM.quantize(-0.5), -16_384)
        XCTAssertEqual(MicrophonePCM.quantize(0), 0)
        XCTAssertEqual(MicrophonePCM.quantize(0.5), 16_384)
        XCTAssertEqual(MicrophonePCM.quantize(1), 32_767)
        XCTAssertEqual(MicrophonePCM.quantize(2), 32_767)
        XCTAssertEqual(MicrophonePCM.quantize(.nan), 0)
    }

    func testEncodingProducesExactly960BigEndianSamples() throws {
        var samples = Array(repeating: Float.zero, count: MicrophoneWire.samplesPerFrame)
        samples[0] = -1
        samples[1] = 1

        let payload = try XCTUnwrap(MicrophonePCM.encode(samples[...]))

        XCTAssertEqual(payload.count, 1_920)
        XCTAssertEqual([UInt8](payload.prefix(4)), [0x80, 0, 0x7F, 0xFF])
        XCTAssertNil(MicrophonePCM.encode(samples.dropLast()))
    }

    func testAccumulatorWaitsForAFullFrameAndResetDropsTheRemainder() {
        var accumulator = MicrophonePCMAccumulator()
        XCTAssertTrue(
            accumulator.append(Array(repeating: 0, count: 959)).isEmpty
        )
        XCTAssertEqual(accumulator.append([1]).count, 1)

        XCTAssertTrue(accumulator.append(Array(repeating: 0, count: 100)).isEmpty)
        accumulator.reset()
        XCTAssertTrue(accumulator.append(Array(repeating: 0, count: 860)).isEmpty)
    }

    func testPendingFramesDropTheOldestAndClearOnStop() {
        var pending = MicrophonePendingFrames()
        for value in 1...5 {
            XCTAssertFalse(pending.enqueue(Data([UInt8(value)])))
        }
        XCTAssertTrue(pending.enqueue(Data([6])))
        XCTAssertEqual(pending.dequeue(), Data([2]))
        pending.removeAll()
        XCTAssertNil(pending.dequeue())
    }

    func testSequenceStartsAtOneResetsAndDoesNotWrap() throws {
        var first = MicrophoneFrameSequence()
        XCTAssertEqual(try XCTUnwrap(first.frame(payload: Data())).messageID, 1)
        XCTAssertEqual(try XCTUnwrap(first.frame(payload: Data())).messageID, 2)

        var reset = MicrophoneFrameSequence()
        XCTAssertEqual(try XCTUnwrap(reset.frame(payload: Data())).messageID, 1)

        var last = MicrophoneFrameSequence(nextID: .max)
        XCTAssertEqual(try XCTUnwrap(last.frame(payload: Data())).messageID, .max)
        XCTAssertTrue(last.isExhausted)
        XCTAssertNil(last.frame(payload: Data()))
    }

    func testDeliveryConfirmationFiresOnlyOncePerArm() {
        var gate = MicrophoneDeliveryGate()
        XCTAssertFalse(gate.didWritePCM(sequenceID: 1))
        gate.arm(afterSequenceID: nil)
        XCTAssertTrue(gate.didWritePCM(sequenceID: 1))
        XCTAssertFalse(gate.didWritePCM(sequenceID: 2))
        gate.arm(afterSequenceID: 2)
        XCTAssertFalse(gate.didWritePCM(sequenceID: 2))
        XCTAssertTrue(gate.didWritePCM(sequenceID: 3))
    }

    func testStartupDiagnosisReportsTheFirstStageThatStopped() {
        XCTAssertEqual(
            MicrophoneStartupDiagnosis.message(capture: nil, network: nil),
            "音频连接已建立，但 5 秒内没有收到麦克风输入回调。"
        )

        let copiedButNotConverted = captureMetrics(
            tapCallbacks: 10,
            converterCalls: 10,
            converterOutputFrames: 0,
            pcmFrames: 0
        )
        XCTAssertEqual(
            MicrophoneStartupDiagnosis.message(
                capture: copiedButNotConverted,
                network: nil
            ),
            "缓冲复制成功，但格式转换没有产生样本（状态：input_ran_dry）。"
        )

        let generated = captureMetrics(
            tapCallbacks: 10,
            converterCalls: 10,
            converterOutputFrames: 9_600,
            pcmFrames: 10
        )
        let queued = MicrophoneNetworkMetrics(
            enqueuedFrames: 10,
            writtenFrames: 0,
            writtenPCMBytes: 0,
            writtenWireBytes: 0,
            droppedFrames: 0,
            rejectedFrames: 0,
            lastSequenceID: 0,
            pendingFrames: 5
        )
        XCTAssertEqual(
            MicrophoneStartupDiagnosis.message(capture: generated, network: queued),
            "PCM 帧已经入队，但网络写出没有完成。"
        )
    }

    func testNetworkMetricsDeltaExcludesFramesFromAnEarlierCaptureGeneration() {
        let baseline = networkMetrics(enqueued: 100, written: 100, sequence: 100)
        let current = networkMetrics(enqueued: 150, written: 149, sequence: 150)

        XCTAssertEqual(
            current.delta(since: baseline),
            MicrophoneNetworkMetrics(
                enqueuedFrames: 50,
                writtenFrames: 49,
                writtenPCMBytes: 49 * 1_920,
                writtenWireBytes: 49 * 1_940,
                droppedFrames: 0,
                rejectedFrames: 0,
                lastSequenceID: 150,
                pendingFrames: 1
            )
        )
        XCTAssertEqual(current.delta(since: nil), current)

        let unchanged = baseline.delta(since: baseline)
        XCTAssertEqual(unchanged.writtenFrames, 0)
        XCTAssertEqual(unchanged.lastSequenceID, 0)
    }

    private func captureMetrics(
        tapCallbacks: UInt64,
        converterCalls: UInt64,
        converterOutputFrames: UInt64,
        pcmFrames: UInt64
    ) -> MicrophoneCaptureMetrics {
        MicrophoneCaptureMetrics(
            tapCallbacks: tapCallbacks,
            inputFrames: tapCallbacks * 1_024,
            lastInputFrameLength: 1_024,
            inputSampleRate: 48_000,
            inputChannels: 1,
            inputFormat: "test",
            inputPeak: 0,
            poolLockDrops: 0,
            poolNoSlotDrops: 0,
            poolCapacityDrops: 0,
            poolLayoutDrops: 0,
            poolByteDrops: 0,
            converterCalls: converterCalls,
            converterStatus: "input_ran_dry",
            converterOutputFrames: converterOutputFrames,
            converterErrors: 0,
            outputPeak: 0,
            pcmFrames: pcmFrames
        )
    }

    private func networkMetrics(
        enqueued: UInt64,
        written: UInt64,
        sequence: UInt64
    ) -> MicrophoneNetworkMetrics {
        MicrophoneNetworkMetrics(
            enqueuedFrames: enqueued,
            writtenFrames: written,
            writtenPCMBytes: written * 1_920,
            writtenWireBytes: written * 1_940,
            droppedFrames: 1,
            rejectedFrames: 2,
            lastSequenceID: sequence,
            pendingFrames: 1
        )
    }
}
