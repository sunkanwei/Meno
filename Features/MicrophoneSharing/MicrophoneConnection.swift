import Foundation
import Network
import OSLog

final class MicrophoneConnection: @unchecked Sendable {
    typealias ReadyHandler = @Sendable (String) -> Void
    typealias DisconnectHandler = @Sendable (String?) -> Void
    typealias DeliveryHandler = @Sendable () -> Void
    typealias MetricsHandler = @Sendable (MicrophoneNetworkMetrics) -> Void

    let id: UUID

    private let connection: NWConnection
    private let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "MicrophoneConnection")
    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.MicrophoneConnection")
    private let localName: String
    private let onReady: ReadyHandler
    private let onDisconnect: DisconnectHandler
    private let onPCMDelivered: DeliveryHandler
    private let onMetrics: MetricsHandler
    private var decoder = ClipboardFrameDecoder()
    private var readiness = ConnectionReadinessGate()
    private var sequence = MicrophoneFrameSequence()
    private var pendingPCM = MicrophonePendingFrames()
    private var pendingControl: [PendingWrite] = []
    private var activeWrite: PendingWrite?
    private var deliveryGate = MicrophoneDeliveryGate()
    private var didDisconnect = false
    private var enqueuedFrames: UInt64 = 0
    private var writtenFrames: UInt64 = 0
    private var writtenPCMBytes: UInt64 = 0
    private var writtenWireBytes: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var rejectedFrames: UInt64 = 0
    private var lastSequenceID: UInt64 = 0
    private var previousMetrics: MicrophoneNetworkMetrics?
    private var startupMetricsBaseline: MicrophoneNetworkMetrics?
    private var startupIgnoredSequenceID: UInt64?
    private var handshakeTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var writeTimer: DispatchSourceTimer?
    private var diagnosticsTimer: DispatchSourceTimer?
    private var lastActivity = ContinuousClock.now
    private var waitingForPongSince: ContinuousClock.Instant?

    private static let handshakeTimeout: Duration = .seconds(5)
    private static let idleBeforePing: Duration = .seconds(15)
    private static let pongTimeout: Duration = .seconds(5)
    private static let writeTimeout: Duration = .milliseconds(250)

    init(
        id: UUID,
        connection: NWConnection,
        localName: String,
        onReady: @escaping ReadyHandler,
        onDisconnect: @escaping DisconnectHandler,
        onPCMDelivered: @escaping DeliveryHandler,
        onMetrics: @escaping MetricsHandler
    ) {
        self.id = id
        self.connection = connection
        self.localName = localName
        self.onReady = onReady
        self.onDisconnect = onDisconnect
        self.onPCMDelivered = onPCMDelivered
        self.onMetrics = onMetrics
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                receiveNext()
            case let .failed(error):
                disconnect(error.localizedDescription)
            case .cancelled:
                disconnect(nil)
            default:
                break
            }
        }
        queue.async { [weak self] in
            self?.scheduleHandshakeTimeout()
        }
        connection.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            self.disconnect(nil)
            self.connection.cancel()
        }
    }

    func armDeliveryConfirmation() {
        queue.async { [weak self] in
            guard let self else { return }
            let staleFrames = UInt64(pendingPCM.frames.count)
            pendingPCM.removeAll()
            droppedFrames &+= staleFrames
            let activeSequenceID = activeWrite?.isPCM == true
                ? activeWrite?.frame.messageID
                : nil
            deliveryGate.arm(afterSequenceID: activeSequenceID)
            startupIgnoredSequenceID = activeSequenceID
            startupMetricsBaseline = currentMetrics()
        }
    }

    func sendPCM(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard readiness.isReady, !didDisconnect,
                  payload.count == MicrophoneWire.payloadSize else {
                rejectedFrames &+= 1
                return
            }
            enqueuedFrames &+= 1
            if pendingPCM.enqueue(payload) {
                droppedFrames &+= 1
            }
            drainWrites()
        }
    }

    private func receiveNext() {
        guard !didDisconnect else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                recordActivity()
                do {
                    for frame in try decoder.append(data) {
                        try handle(frame)
                    }
                } catch {
                    disconnect(error.localizedDescription)
                    connection.cancel()
                    return
                }
            }
            if let error {
                disconnect(error.localizedDescription)
                connection.cancel()
                return
            }
            if isComplete {
                disconnect(nil)
                connection.cancel()
                return
            }
            receiveNext()
        }
    }

    private func handle(_ frame: ClipboardFrame) throws {
        if readiness.isHandshakePending {
            guard frame.kind == .hello,
                  readiness.beginHello(),
                  let hello = CompanionHello.decode(frame.payload),
                  isValidAudioHello(hello) else {
                throw MicrophoneConnectionError.protocolViolation
            }
            let ready = CompanionHello(
                name: localName,
                capabilities: [.macMicrophone],
                driverABI: nil,
                screenWidth: nil,
                screenHeight: nil
            )
            enqueueControl(kind: .ready, payload: ready.encoded()) { [weak self] sent in
                guard let self, sent, !didDisconnect,
                      readiness.readyFrameWasSent() else { return }
                handshakeTimer?.cancel()
                handshakeTimer = nil
                recordActivity()
                scheduleDiagnostics()
                onReady(hello.name)
            }
            return
        }

        switch frame.kind {
        case .ping where frame.payload.isEmpty:
            enqueueControl(kind: .pong, payload: Data())
        case .pong where frame.payload.isEmpty:
            waitingForPongSince = nil
            recordActivity()
        default:
            throw MicrophoneConnectionError.protocolViolation
        }
    }

    private func isValidAudioHello(_ hello: CompanionHello) -> Bool {
        !hello.name.isEmpty
            && hello.capabilities == [.macMicrophone]
            && hello.driverABI == nil
            && hello.screenWidth == nil
            && hello.screenHeight == nil
            && hello.audioPort == nil
    }

    private func enqueueControl(
        kind: ClipboardMessageKind,
        payload: Data,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let frame = ClipboardFrame(
            kind: kind,
            messageID: UInt64.random(in: UInt64.min...UInt64.max),
            payload: payload
        )
        pendingControl.append(PendingWrite(
            frame: frame,
            isPCM: false,
            closesAfterWrite: false,
            completion: completion
        ))
        drainWrites()
    }

    private func drainWrites() {
        guard !didDisconnect, activeWrite == nil else { return }
        let write: PendingWrite
        if !pendingControl.isEmpty {
            write = pendingControl.removeFirst()
        } else {
            guard let payload = pendingPCM.dequeue(),
                  let frame = sequence.frame(payload: payload) else {
                if sequence.isExhausted {
                    disconnect("麦克风音频序列号已耗尽。")
                    connection.cancel()
                }
                return
            }
            write = PendingWrite(
                frame: frame,
                isPCM: true,
                closesAfterWrite: sequence.isExhausted,
                completion: nil
            )
        }

        activeWrite = write
        scheduleWriteTimeout()
        connection.send(content: write.frame.encoded(), completion: .contentProcessed {
            [weak self] error in
            guard let self, activeWrite?.id == write.id else { return }
            writeTimer?.cancel()
            writeTimer = nil
            activeWrite = nil
            if let error {
                write.completion?(false)
                disconnect(error.localizedDescription)
                connection.cancel()
                return
            }
            recordActivity()
            if write.isPCM {
                writtenFrames &+= 1
                writtenPCMBytes &+= UInt64(write.frame.payload.count)
                writtenWireBytes &+= UInt64(ClipboardWire.headerSize + write.frame.payload.count)
                lastSequenceID = write.frame.messageID
                excludeIgnoredPCMWriteFromStartupMetrics(write)
                if deliveryGate.didWritePCM(sequenceID: write.frame.messageID) {
                    onPCMDelivered()
                }
            }
            write.completion?(true)
            if write.closesAfterWrite {
                disconnect("麦克风音频序列号已耗尽。")
                connection.cancel()
            } else {
                drainWrites()
            }
        })
    }

    private func scheduleHandshakeTimeout() {
        guard !didDisconnect, readiness.isHandshakePending else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.handshakeTimeout.timeInterval)
        timer.setEventHandler { [weak self] in
            guard let self, readiness.isHandshakePending, !didDisconnect else { return }
            disconnect("Windows 未在 5 秒内完成麦克风握手。")
            connection.cancel()
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func scheduleWriteTimeout() {
        writeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.writeTimeout.timeInterval)
        timer.setEventHandler { [weak self] in
            guard let self, activeWrite != nil, !didDisconnect else { return }
            disconnect("麦克风音频写入超过 250 毫秒。")
            connection.cancel()
        }
        writeTimer = timer
        timer.resume()
    }

    private func scheduleDiagnostics() {
        diagnosticsTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.reportMetrics()
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    private func reportMetrics() {
        let metrics = currentMetrics()
        let previous = previousMetrics
        let delta = metrics.delta(since: previous)
        if delta.enqueuedFrames > 0 || delta.writtenFrames > 0
            || delta.droppedFrames > 0 || delta.rejectedFrames > 0
            || delta.pendingFrames > 0 {
            logger.info(
                "network enqueued=\(delta.enqueuedFrames, privacy: .public) written=\(delta.writtenFrames, privacy: .public) pcm_bytes=\(delta.writtenPCMBytes, privacy: .public) wire_bytes=\(delta.writtenWireBytes, privacy: .public) dropped=\(delta.droppedFrames, privacy: .public) rejected=\(delta.rejectedFrames, privacy: .public) pending=\(delta.pendingFrames, privacy: .public) last_sequence=\(delta.lastSequenceID, privacy: .public)"
            )
        }
        previousMetrics = metrics
        onMetrics(metrics.delta(since: startupMetricsBaseline))
    }

    private func currentMetrics() -> MicrophoneNetworkMetrics {
        MicrophoneNetworkMetrics(
            enqueuedFrames: enqueuedFrames,
            writtenFrames: writtenFrames,
            writtenPCMBytes: writtenPCMBytes,
            writtenWireBytes: writtenWireBytes,
            droppedFrames: droppedFrames,
            rejectedFrames: rejectedFrames,
            lastSequenceID: lastSequenceID,
            pendingFrames: pendingPCM.frames.count + (activeWrite?.isPCM == true ? 1 : 0)
        )
    }

    private func excludeIgnoredPCMWriteFromStartupMetrics(_ write: PendingWrite) {
        guard startupIgnoredSequenceID == write.frame.messageID,
              let baseline = startupMetricsBaseline else { return }
        startupIgnoredSequenceID = nil
        startupMetricsBaseline = MicrophoneNetworkMetrics(
            enqueuedFrames: baseline.enqueuedFrames,
            writtenFrames: baseline.writtenFrames + 1,
            writtenPCMBytes: baseline.writtenPCMBytes + UInt64(write.frame.payload.count),
            writtenWireBytes: baseline.writtenWireBytes
                + UInt64(ClipboardWire.headerSize + write.frame.payload.count),
            droppedFrames: baseline.droppedFrames,
            rejectedFrames: baseline.rejectedFrames,
            lastSequenceID: write.frame.messageID,
            pendingFrames: baseline.pendingFrames
        )
    }

    private func recordActivity() {
        guard !didDisconnect else { return }
        lastActivity = .now
        if readiness.isReady, waitingForPongSince == nil, keepaliveTimer == nil {
            scheduleKeepalive(after: Self.idleBeforePing)
        }
    }

    private func scheduleKeepalive(after delay: Duration) {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.timeInterval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.performKeepalive()
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func performKeepalive() {
        keepaliveTimer = nil
        guard readiness.isReady, !didDisconnect else { return }
        let now = ContinuousClock.now
        if waitingForPongSince != nil {
            disconnect("Windows 未响应麦克风保活消息。")
            connection.cancel()
            return
        }
        let idleDuration = lastActivity.duration(to: now)
        guard idleDuration >= Self.idleBeforePing else {
            scheduleKeepalive(after: Self.idleBeforePing - idleDuration)
            return
        }
        waitingForPongSince = now
        enqueueControl(kind: .ping, payload: Data())
        scheduleKeepalive(after: Self.pongTimeout)
    }

    private func disconnect(_ reason: String?) {
        guard !didDisconnect else { return }
        didDisconnect = true
        readiness.close()
        pendingPCM.removeAll()
        pendingControl.removeAll()
        activeWrite?.completion?(false)
        activeWrite = nil
        handshakeTimer?.cancel()
        handshakeTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        writeTimer?.cancel()
        writeTimer = nil
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        startupMetricsBaseline = nil
        startupIgnoredSequenceID = nil
        onDisconnect(reason)
    }
}

private struct PendingWrite: @unchecked Sendable {
    let id = UUID()
    let frame: ClipboardFrame
    let isPCM: Bool
    let closesAfterWrite: Bool
    let completion: (@Sendable (Bool) -> Void)?
}

private enum MicrophoneConnectionError: LocalizedError {
    case protocolViolation

    var errorDescription: String? {
        "麦克风连接收到不符合 MENO 协议的消息。"
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
