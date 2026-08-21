@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Synchronization

final class MicrophoneCapture: @unchecked Sendable {
    typealias PCMHandler = @Sendable (Data) -> Void
    typealias FailureHandler = @Sendable (String) -> Void
    typealias DeviceChangeHandler = @Sendable () -> Void
    typealias MetricsHandler = @Sendable (MicrophoneCaptureMetrics) -> Void

    private let worker = DispatchQueue(label: "com.sunkanwei.Meno.MicrophoneCapture")
    private let onPCM: PCMHandler
    private let onFailure: FailureHandler
    private let onDeviceChange: DeviceChangeHandler
    private let onMetrics: MetricsHandler
    private let engine = AVAudioEngine()
    private let realtimeMetrics = CaptureRealtimeMetrics()
    private var converter: AVAudioConverter?
    private var bufferPool: CaptureBufferPool?
    private var accumulator = MicrophonePCMAccumulator()
    private var configurationObserver: NSObjectProtocol?
    private var deviceObserver: DefaultInputDeviceObserver?
    private var diagnosticsTimer: DispatchSourceTimer?
    private var inputSampleRate = 0.0
    private var inputChannels: UInt32 = 0
    private var inputFormatDescription = "unknown"
    private var converterCalls: UInt64 = 0
    private var converterOutputFrames: UInt64 = 0
    private var converterErrors: UInt64 = 0
    private var pcmFrames: UInt64 = 0
    private var lastConverterStatus = "not_started"
    private var intervalInputPeak: Float = 0
    private var intervalOutputPeak: Float = 0
    private var isRunning = false

    init(
        onPCM: @escaping PCMHandler,
        onFailure: @escaping FailureHandler,
        onDeviceChange: @escaping DeviceChangeHandler,
        onMetrics: @escaping MetricsHandler
    ) {
        self.onPCM = onPCM
        self.onFailure = onFailure
        self.onDeviceChange = onDeviceChange
        self.onMetrics = onMetrics
    }

    static func defaultInputDeviceName() -> String? {
        try? AudioHardwareSystem.shared.defaultInputDevice?.name
    }

    func start() throws {
        guard !isRunning else { return }
        guard try AudioHardwareSystem.shared.defaultInputDevice != nil else {
            throw MicrophoneCaptureError.noInputDevice
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: MicrophoneWire.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MicrophoneCaptureError.unsupportedInputFormat
        }

        let pool = try CaptureBufferPool(
            format: inputFormat,
            capacity: AVAudioFrameCount(MicrophoneCaptureConfiguration.bufferFrameCapacity),
            count: 6
        )
        self.converter = converter
        bufferPool = pool
        accumulator.reset()
        inputSampleRate = inputFormat.sampleRate
        inputChannels = inputFormat.channelCount
        inputFormatDescription = inputFormat.settings.description

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            [weak self, weak pool] buffer, _ in
            guard let self, let pool else { return }
            realtimeMetrics.recordTap(frameLength: buffer.frameLength)
            let chunk: CaptureBufferSlot
            switch pool.copy(buffer) {
            case let .copied(slot):
                chunk = slot
            case let .dropped(reason):
                realtimeMetrics.recordDrop(reason)
                return
            }
            worker.async { [weak self, weak pool] in
                defer { pool?.release(chunk) }
                self?.convertAndSend(chunk.buffer, outputFormat: outputFormat)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            try startObservers()
            isRunning = true
            startDiagnostics()
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            self.converter = nil
            bufferPool = nil
            stopObservers()
            throw error
        }
    }

    func stop() {
        guard isRunning || converter != nil else { return }
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        stopObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        worker.sync {
            accumulator.reset()
            converter = nil
            bufferPool = nil
        }
        isRunning = false
    }

    private func startObservers() throws {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onDeviceChange()
        }
        let observer = DefaultInputDeviceObserver(onChange: onDeviceChange)
        try observer.start()
        deviceObserver = observer
    }

    private func stopObservers() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        deviceObserver?.stop()
        deviceObserver = nil
    }

    private func convertAndSend(_ input: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }
        intervalInputPeak = max(intervalInputPeak, Self.peak(in: input))
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, AVAudioFrameCount(MicrophoneWire.samplesPerFrame))
        ) else {
            onFailure(MicrophoneCaptureError.bufferAllocation.localizedDescription)
            return
        }

        let inputState = ConverterInputState(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if inputState.wasProvided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.wasProvided = true
            inputStatus.pointee = .haveData
            return inputState.buffer
        }
        converterCalls &+= 1
        lastConverterStatus = status.diagnosticName
        if status == .error {
            converterErrors &+= 1
            onFailure(
                conversionError?.localizedDescription
                    ?? MicrophoneCaptureError.conversionFailed.localizedDescription
            )
            return
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        converterOutputFrames &+= UInt64(output.frameLength)
        let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        intervalOutputPeak = max(intervalOutputPeak, Self.peak(in: samples))
        let payloads = accumulator.append(samples)
        pcmFrames &+= UInt64(payloads.count)
        for payload in payloads {
            onPCM(payload)
        }
    }

    private func startDiagnostics() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.reportMetrics()
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    private func reportMetrics() {
        let realtime = realtimeMetrics.snapshot()
        let metrics = MicrophoneCaptureMetrics(
            tapCallbacks: realtime.tapCallbacks,
            inputFrames: realtime.inputFrames,
            lastInputFrameLength: realtime.lastInputFrameLength,
            inputSampleRate: inputSampleRate,
            inputChannels: inputChannels,
            inputFormat: inputFormatDescription,
            inputPeak: intervalInputPeak,
            poolLockDrops: realtime.poolLockDrops,
            poolNoSlotDrops: realtime.poolNoSlotDrops,
            poolCapacityDrops: realtime.poolCapacityDrops,
            poolLayoutDrops: realtime.poolLayoutDrops,
            poolByteDrops: realtime.poolByteDrops,
            converterCalls: converterCalls,
            converterStatus: lastConverterStatus,
            converterOutputFrames: converterOutputFrames,
            converterErrors: converterErrors,
            outputPeak: intervalOutputPeak,
            pcmFrames: pcmFrames
        )
        intervalInputPeak = 0
        intervalOutputPeak = 0
        onMetrics(metrics)
    }

    private static func peak(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        if buffer.format.isInterleaved {
            return peak(in: UnsafeBufferPointer(
                start: channels[0],
                count: frameCount * channelCount
            ))
        }
        var peak: Float = 0
        for channelIndex in 0..<channelCount {
            peak = max(
                peak,
                self.peak(in: UnsafeBufferPointer(
                    start: channels[channelIndex],
                    count: frameCount
                ))
            )
        }
        return peak
    }

    private static func peak(in samples: UnsafeBufferPointer<Float>) -> Float {
        var peak: Float = 0
        for sample in samples where sample.isFinite {
            peak = max(peak, abs(sample))
        }
        return peak
    }
}

private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var wasProvided = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private enum CaptureBufferDropReason {
    case lock
    case noSlot
    case capacity
    case layout
    case bytes
}

private enum CaptureBufferCopyResult {
    case copied(CaptureBufferSlot)
    case dropped(CaptureBufferDropReason)
}

private struct CaptureRealtimeSnapshot {
    let tapCallbacks: UInt64
    let inputFrames: UInt64
    let lastInputFrameLength: UInt64
    let poolLockDrops: UInt64
    let poolNoSlotDrops: UInt64
    let poolCapacityDrops: UInt64
    let poolLayoutDrops: UInt64
    let poolByteDrops: UInt64
}

private final class CaptureRealtimeMetrics: Sendable {
    private let tapCallbacks = Atomic<UInt64>(0)
    private let inputFrames = Atomic<UInt64>(0)
    private let lastInputFrameLength = Atomic<UInt64>(0)
    private let poolLockDrops = Atomic<UInt64>(0)
    private let poolNoSlotDrops = Atomic<UInt64>(0)
    private let poolCapacityDrops = Atomic<UInt64>(0)
    private let poolLayoutDrops = Atomic<UInt64>(0)
    private let poolByteDrops = Atomic<UInt64>(0)

    func recordTap(frameLength: AVAudioFrameCount) {
        tapCallbacks.wrappingAdd(1, ordering: .relaxed)
        inputFrames.wrappingAdd(UInt64(frameLength), ordering: .relaxed)
        lastInputFrameLength.store(UInt64(frameLength), ordering: .relaxed)
    }

    func recordDrop(_ reason: CaptureBufferDropReason) {
        switch reason {
        case .lock:
            poolLockDrops.wrappingAdd(1, ordering: .relaxed)
        case .noSlot:
            poolNoSlotDrops.wrappingAdd(1, ordering: .relaxed)
        case .capacity:
            poolCapacityDrops.wrappingAdd(1, ordering: .relaxed)
        case .layout:
            poolLayoutDrops.wrappingAdd(1, ordering: .relaxed)
        case .bytes:
            poolByteDrops.wrappingAdd(1, ordering: .relaxed)
        }
    }

    func snapshot() -> CaptureRealtimeSnapshot {
        CaptureRealtimeSnapshot(
            tapCallbacks: tapCallbacks.load(ordering: .relaxed),
            inputFrames: inputFrames.load(ordering: .relaxed),
            lastInputFrameLength: lastInputFrameLength.load(ordering: .relaxed),
            poolLockDrops: poolLockDrops.load(ordering: .relaxed),
            poolNoSlotDrops: poolNoSlotDrops.load(ordering: .relaxed),
            poolCapacityDrops: poolCapacityDrops.load(ordering: .relaxed),
            poolLayoutDrops: poolLayoutDrops.load(ordering: .relaxed),
            poolByteDrops: poolByteDrops.load(ordering: .relaxed)
        )
    }
}

private final class CaptureBufferPool: @unchecked Sendable {
    private let lock = NSLock()
    private let slots: [CaptureBufferSlot]

    init(format: AVAudioFormat, capacity: AVAudioFrameCount, count: Int) throws {
        var slots: [CaptureBufferSlot] = []
        for _ in 0..<count {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw MicrophoneCaptureError.bufferAllocation
            }
            slots.append(CaptureBufferSlot(buffer: buffer))
        }
        self.slots = slots
    }

    func copy(_ source: AVAudioPCMBuffer) -> CaptureBufferCopyResult {
        guard source.frameLength > 0 else { return .dropped(.bytes) }
        guard lock.try() else { return .dropped(.lock) }
        defer { lock.unlock() }
        guard let slot = slots.first(where: { !$0.inUse }) else {
            return .dropped(.noSlot)
        }
        guard source.frameLength <= slot.buffer.frameCapacity else {
            return .dropped(.capacity)
        }
        slot.inUse = true

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            slot.buffer.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            slot.inUse = false
            return .dropped(.layout)
        }
        let bytesToCopy = UInt32(source.frameLength)
            * source.format.streamDescription.pointee.mBytesPerFrame
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffers[index].mData,
                  bytesToCopy <= sourceBuffer.mDataByteSize,
                  bytesToCopy <= slot.byteCapacities[index] else {
                slot.inUse = false
                return .dropped(.bytes)
            }
            memcpy(destinationData, sourceData, Int(bytesToCopy))
            destinationBuffers[index].mDataByteSize = bytesToCopy
        }
        slot.buffer.frameLength = source.frameLength
        return .copied(slot)
    }

    func release(_ slot: CaptureBufferSlot) {
        lock.lock()
        slot.inUse = false
        slot.buffer.frameLength = 0
        lock.unlock()
    }
}

private extension AVAudioConverterOutputStatus {
    var diagnosticName: String {
        switch self {
        case .haveData:
            return "have_data"
        case .inputRanDry:
            return "input_ran_dry"
        case .endOfStream:
            return "end_of_stream"
        case .error:
            return "error"
        @unknown default:
            return "unknown"
        }
    }
}

private final class CaptureBufferSlot: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let byteCapacities: [UInt32]
    var inUse = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
        let bufferCount = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).count
        let byteCapacity = UInt32(buffer.frameCapacity)
            * buffer.format.streamDescription.pointee.mBytesPerFrame
        byteCapacities = Array(repeating: byteCapacity, count: bufferCount)
    }
}

private final class DefaultInputDeviceObserver: PropertyListenerDelegate, @unchecked Sendable {
    private let system = AudioHardwareSystem.shared
    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.DefaultInputDeviceObserver")
    private let onChange: @Sendable () -> Void
    private let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var isStarted = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() throws {
        guard !isStarted else { return }
        system.delegates.append(self)
        do {
            try system.addListener(forProperties: [address], dispatchQueue: queue)
            isStarted = true
        } catch {
            system.delegates.removeAll { ($0 as AnyObject) === self }
            throw error
        }
    }

    func stop() {
        guard isStarted else { return }
        try? system.removeListener(forProperties: [address], dispatchQueue: queue)
        system.delegates.removeAll { ($0 as AnyObject) === self }
        isStarted = false
    }

    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        guard properties.contains(where: { $0.mSelector == address.mSelector }) else { return }
        onChange()
    }
}

private enum MicrophoneCaptureError: LocalizedError {
    case noInputDevice
    case unsupportedInputFormat
    case bufferAllocation
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "没有可用的默认麦克风。"
        case .unsupportedInputFormat:
            return "当前麦克风格式无法转换为 48 kHz 单声道。"
        case .bufferAllocation:
            return "无法分配麦克风音频缓冲。"
        case .conversionFailed:
            return "麦克风音频格式转换失败。"
        }
    }
}
