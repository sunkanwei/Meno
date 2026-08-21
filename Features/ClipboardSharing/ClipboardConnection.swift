import Foundation
import Network

final class ClipboardConnection: @unchecked Sendable {
    typealias ReadyHandler = @Sendable (String, Set<CompanionCapability>) -> Void
    typealias ContentHandler = @Sendable (SharedClipboardContent) -> Void
    typealias FilesHandler = @Sendable ([URL], @escaping @Sendable (Bool) -> Void) -> Void
    typealias WindowsOnlineHandler = @Sendable () -> Void
    typealias DisconnectHandler = @Sendable (String?) -> Void

    let id: UUID
    let remoteAddress: String

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.ClipboardConnection")
    private let localName: String
    private let supportedCapabilities: Set<CompanionCapability>
    private let audioPort: UInt16?
    private let onReady: ReadyHandler
    private let onContent: ContentHandler
    private let onFiles: FilesHandler
    private let onWindowsOnline: WindowsOnlineHandler
    private let onDisconnect: DisconnectHandler
    private var decoder = ClipboardFrameDecoder()
    private var negotiatedCapabilities = Set<CompanionCapability>()
    private var readiness = ConnectionReadinessGate()
    private var windowsOnlineDelivery = WindowsOnlineDeliveryGate()
    private var didDisconnect = false
    private var handshakeTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var lastActivity = ContinuousClock.now
    private var waitingForPongSince: ContinuousClock.Instant?
    private lazy var fileTransfer = FileClipboardTransfer(
        sendFrame: { [weak self] kind, payload, completion in
            self?.queue.async { [weak self] in
                guard let self else {
                    completion(false)
                    return
                }
                sendFrame(kind: kind, payload: payload, completion: completion)
            }
        },
        publishFiles: { [onFiles] urls, completion in
            onFiles(urls, completion)
        },
        onProtocolViolation: { [weak self] reason in
            self?.queue.async { [weak self] in
                guard let self, !didDisconnect else { return }
                disconnect(reason)
                connection.cancel()
            }
        }
    )

    private static let handshakeTimeout: Duration = .seconds(5)
    private static let idleBeforePing: Duration = .seconds(30)
    private static let pongTimeout: Duration = .seconds(10)

    init(
        id: UUID,
        connection: NWConnection,
        localName: String,
        supportedCapabilities: Set<CompanionCapability>,
        audioPort: UInt16?,
        onReady: @escaping ReadyHandler,
        onContent: @escaping ContentHandler,
        onFiles: @escaping FilesHandler,
        onWindowsOnline: @escaping WindowsOnlineHandler,
        onDisconnect: @escaping DisconnectHandler
    ) {
        self.id = id
        self.connection = connection
        remoteAddress = String(describing: connection.endpoint)
        self.localName = localName
        self.supportedCapabilities = supportedCapabilities
        self.audioPort = audioPort
        self.onReady = onReady
        self.onContent = onContent
        self.onFiles = onFiles
        self.onWindowsOnline = onWindowsOnline
        self.onDisconnect = onDisconnect
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
        queue.async {
            self.fileTransfer.stop()
            self.connection.cancel()
        }
    }

    func send(_ content: SharedClipboardContent) {
        queue.async { [weak self] in
            guard let self, readiness.isReady, !didDisconnect else { return }
            fileTransfer.localClipboardChanged { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, readiness.isReady, !didDisconnect else { return }
                    switch content {
                    case let .text(payload):
                        guard negotiatedCapabilities.contains(.textClipboard) else { return }
                        sendFrame(kind: .text, payload: payload)
                    case let .png(payload):
                        guard negotiatedCapabilities.contains(.pngClipboard) else { return }
                        sendFrame(kind: .png, payload: payload)
                    case let .files(urls):
                        guard negotiatedCapabilities.contains(.fileClipboard) else { return }
                        fileTransfer.sendFiles(urls)
                    }
                }
            }
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
        switch frame.kind {
        case .hello:
            guard let hello = CompanionHello.decode(frame.payload),
                  hello.audioPort == nil,
                  readiness.beginHello() else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            negotiatedCapabilities = hello.capabilities.intersection(supportedCapabilities)
            guard !negotiatedCapabilities.isEmpty else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            let negotiatedAudioPort = negotiatedCapabilities.contains(.macMicrophone)
                ? audioPort : nil
            guard negotiatedCapabilities.contains(.macMicrophone) == (negotiatedAudioPort != nil) else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            let ready = CompanionHello(
                name: localName,
                capabilities: negotiatedCapabilities,
                driverABI: nil,
                screenWidth: nil,
                screenHeight: nil,
                audioPort: negotiatedAudioPort
            )
            sendFrame(kind: .ready, payload: ready.encoded()) { [weak self] sent in
                guard let self, sent, !didDisconnect,
                      readiness.readyFrameWasSent() else { return }
                let shouldNotifyWindowsOnline = windowsOnlineDelivery.readyFrameWasSent()
                handshakeTimer?.cancel()
                handshakeTimer = nil
                _ = fileTransfer
                recordActivity()
                onReady(
                    hello.name.isEmpty ? "Windows" : hello.name,
                    negotiatedCapabilities
                )
                if shouldNotifyWindowsOnline {
                    onWindowsOnline()
                }
            }
        case .text:
            guard readiness.isReady, negotiatedCapabilities.contains(.textClipboard),
                  frame.payload.count <= ClipboardWire.maximumTextSize,
                  String(data: frame.payload, encoding: .utf8) != nil else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            fileTransfer.remoteContentSuperseded { [weak self] in
                self?.onContent(.text(frame.payload))
            }
        case .png:
            guard readiness.isReady, negotiatedCapabilities.contains(.pngClipboard),
                  frame.payload.count <= ClipboardWire.maximumImageSize else {
                throw ClipboardFrameDecoderError.payloadTooLarge
            }
            fileTransfer.remoteContentSuperseded { [weak self] in
                self?.onContent(.png(frame.payload))
            }
        case .fileOffer, .fileAccept, .fileChunk, .fileComplete,
             .fileResult, .fileCancel, .fileAck:
            guard readiness.isReady, negotiatedCapabilities.contains(.fileClipboard) else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            fileTransfer.receive(kind: frame.kind, payload: frame.payload)
        case .ping:
            guard readiness.isReady, frame.payload.isEmpty else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            sendFrame(kind: .pong, payload: Data())
        case .pong:
            guard readiness.isReady, frame.payload.isEmpty else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            waitingForPongSince = nil
            recordActivity()
        case .windowsOnline:
            switch windowsOnlineDelivery.receive(
                isReady: readiness.isReady,
                isSendingReady: readiness.isSendingReady,
                negotiatedCapabilities: negotiatedCapabilities,
                payload: frame.payload
            ) {
            case .notifyNow:
                onWindowsOnline()
            case .waitForReadyWrite:
                break
            case .reject:
                throw ClipboardFrameDecoderError.invalidHeader
            }
        case .ready, .mouseEnter, .directionalMouseEnter, .mouseMove, .mouseButton, .mouseWheel,
             .mouseReleaseAll, .mouseLeave, .mouseDriverUnavailable, .keyboardState,
             .mouseAcquired, .mouseReleased, .mouseControlHeartbeat, .shutdownRequest,
             .microphonePCM, .diagnosticEvent:
            throw ClipboardFrameDecoderError.invalidHeader
        }
    }

    private func sendFrame(
        kind: ClipboardMessageKind,
        payload: Data,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard !didDisconnect else {
            completion?(false)
            return
        }
        let frame = ClipboardFrame(
            kind: kind,
            messageID: UInt64.random(in: UInt64.min...UInt64.max),
            payload: payload
        )
        connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            guard let self else {
                completion?(false)
                return
            }
            guard !self.didDisconnect else {
                completion?(false)
                return
            }
            if let error {
                completion?(false)
                self.disconnect(error.localizedDescription)
                self.connection.cancel()
            } else {
                self.recordActivity()
                completion?(true)
            }
        })
    }

    private func recordActivity() {
        guard !didDisconnect else { return }
        lastActivity = .now
        if readiness.isReady, waitingForPongSince == nil, keepaliveTimer == nil {
            scheduleKeepalive(after: Self.idleBeforePing)
        }
    }

    private func scheduleHandshakeTimeout() {
        guard !didDisconnect, readiness.isHandshakePending else { return }
        handshakeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.handshakeTimeout.timeInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            guard let self, !didDisconnect, readiness.isHandshakePending else { return }
            disconnect("Windows 未在 5 秒内完成剪贴板握手。")
            connection.cancel()
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func scheduleKeepalive(after delay: Duration) {
        guard !didDisconnect else { return }
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.timeInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.performKeepalive()
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func performKeepalive() {
        keepaliveTimer = nil
        guard !didDisconnect else { return }
        let now = ContinuousClock.now
        if waitingForPongSince != nil {
            disconnect("Windows 未响应保活消息。")
            connection.cancel()
            return
        }
        let idleDuration = lastActivity.duration(to: now)
        guard idleDuration >= Self.idleBeforePing else {
            scheduleKeepalive(after: Self.idleBeforePing - idleDuration)
            return
        }
        waitingForPongSince = now
        sendFrame(kind: .ping, payload: Data())
        scheduleKeepalive(after: Self.pongTimeout)
    }

    private func disconnect(_ reason: String?) {
        guard !didDisconnect else { return }
        didDisconnect = true
        readiness.close()
        negotiatedCapabilities.removeAll()
        fileTransfer.stop()
        handshakeTimer?.cancel()
        handshakeTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        onDisconnect(reason)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
