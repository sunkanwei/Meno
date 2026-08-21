import Foundation

enum MicrophoneWire {
    static let sampleRate = 48_000.0
    static let samplesPerFrame = 960
    static let payloadSize = samplesPerFrame * MemoryLayout<Int16>.size
    static let maximumPendingFrames = 5
}

enum MicrophoneCaptureConfiguration {
    static let bufferFrameCapacity = 8_192
}

struct MicrophoneCaptureMetrics: Sendable, Equatable {
    let tapCallbacks: UInt64
    let inputFrames: UInt64
    let lastInputFrameLength: UInt64
    let inputSampleRate: Double
    let inputChannels: UInt32
    let inputFormat: String
    let inputPeak: Float
    let poolLockDrops: UInt64
    let poolNoSlotDrops: UInt64
    let poolCapacityDrops: UInt64
    let poolLayoutDrops: UInt64
    let poolByteDrops: UInt64
    let converterCalls: UInt64
    let converterStatus: String
    let converterOutputFrames: UInt64
    let converterErrors: UInt64
    let outputPeak: Float
    let pcmFrames: UInt64
}

struct MicrophoneNetworkMetrics: Sendable, Equatable {
    let enqueuedFrames: UInt64
    let writtenFrames: UInt64
    let writtenPCMBytes: UInt64
    let writtenWireBytes: UInt64
    let droppedFrames: UInt64
    let rejectedFrames: UInt64
    let lastSequenceID: UInt64
    let pendingFrames: Int

    func delta(since baseline: Self?) -> Self {
        guard let baseline else { return self }
        return Self(
            enqueuedFrames: enqueuedFrames - baseline.enqueuedFrames,
            writtenFrames: writtenFrames - baseline.writtenFrames,
            writtenPCMBytes: writtenPCMBytes - baseline.writtenPCMBytes,
            writtenWireBytes: writtenWireBytes - baseline.writtenWireBytes,
            droppedFrames: droppedFrames - baseline.droppedFrames,
            rejectedFrames: rejectedFrames - baseline.rejectedFrames,
            lastSequenceID: writtenFrames == baseline.writtenFrames ? 0 : lastSequenceID,
            pendingFrames: pendingFrames
        )
    }
}

enum MicrophoneStartupDiagnosis {
    static func message(
        capture: MicrophoneCaptureMetrics?,
        network: MicrophoneNetworkMetrics?
    ) -> String {
        guard let capture, capture.tapCallbacks > 0 else {
            return "音频连接已建立，但 5 秒内没有收到麦克风输入回调。"
        }

        let poolDrops = capture.poolLockDrops
            + capture.poolNoSlotDrops
            + capture.poolCapacityDrops
            + capture.poolLayoutDrops
            + capture.poolByteDrops
        if capture.converterCalls == 0 {
            return poolDrops > 0
                ? "麦克风输入回调存在，但缓冲复制全部失败。"
                : "麦克风输入回调存在，但缓冲没有进入格式转换阶段。"
        }
        if capture.converterOutputFrames == 0 {
            return "缓冲复制成功，但格式转换没有产生样本（状态：\(capture.converterStatus)）。"
        }
        if capture.pcmFrames == 0 {
            return "格式转换已有输出，但没有形成完整的 960 样本 PCM 帧。"
        }
        guard let network, network.enqueuedFrames > 0 else {
            return "PCM 帧已经产生，但没有进入网络发送队列。"
        }
        if network.writtenFrames == 0 {
            return "PCM 帧已经入队，但网络写出没有完成。"
        }
        return "首帧 PCM 已写出，但共享状态确认没有完成。"
    }
}

struct MicrophoneDeliveryGate {
    private var armed = false
    private var ignoredSequenceID: UInt64?

    mutating func arm(afterSequenceID: UInt64?) {
        armed = true
        ignoredSequenceID = afterSequenceID
    }

    mutating func didWritePCM(sequenceID: UInt64) -> Bool {
        guard armed else { return false }
        if sequenceID == ignoredSequenceID {
            ignoredSequenceID = nil
            return false
        }
        armed = false
        ignoredSequenceID = nil
        return true
    }
}

enum MicrophonePCM {
    static func quantize(_ sample: Float) -> Int16 {
        guard sample.isFinite else { return 0 }
        let clamped = min(max(sample, -1), 1)
        let scaled = clamped < 0 ? clamped * 32_768 : clamped * 32_767
        return Int16(scaled.rounded())
    }

    static func encode(_ samples: ArraySlice<Float>) -> Data? {
        guard samples.count == MicrophoneWire.samplesPerFrame else { return nil }
        var payload = Data(capacity: MicrophoneWire.payloadSize)
        for sample in samples {
            payload.appendBigEndian(UInt16(bitPattern: quantize(sample)))
        }
        return payload
    }
}

struct MicrophonePCMAccumulator {
    private var samples: [Float] = []

    mutating func append(_ newSamples: UnsafeBufferPointer<Float>) -> [Data] {
        samples.append(contentsOf: newSamples)
        return takeCompleteFrames()
    }

    mutating func append(_ newSamples: [Float]) -> [Data] {
        samples.append(contentsOf: newSamples)
        return takeCompleteFrames()
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    private mutating func takeCompleteFrames() -> [Data] {
        var frames: [Data] = []
        var consumed = 0
        while samples.count - consumed >= MicrophoneWire.samplesPerFrame {
            let end = consumed + MicrophoneWire.samplesPerFrame
            if let payload = MicrophonePCM.encode(samples[consumed..<end]) {
                frames.append(payload)
            }
            consumed = end
        }
        if consumed != 0 {
            samples.removeFirst(consumed)
        }
        return frames
    }
}

struct MicrophonePendingFrames {
    private(set) var frames: [Data] = []

    @discardableResult
    mutating func enqueue(_ payload: Data) -> Bool {
        var droppedOldest = false
        if frames.count == MicrophoneWire.maximumPendingFrames {
            frames.removeFirst()
            droppedOldest = true
        }
        frames.append(payload)
        return droppedOldest
    }

    mutating func dequeue() -> Data? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    mutating func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }
}

struct MicrophoneFrameSequence {
    private var nextID: UInt64
    private(set) var isExhausted = false

    init(nextID: UInt64 = 1) {
        precondition(nextID != 0)
        self.nextID = nextID
    }

    mutating func frame(payload: Data) -> ClipboardFrame? {
        guard !isExhausted else { return nil }
        let messageID = nextID
        if nextID == UInt64.max {
            isExhausted = true
        } else {
            nextID += 1
        }
        return ClipboardFrame(kind: .microphonePCM, messageID: messageID, payload: payload)
    }
}
