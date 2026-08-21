import Foundation
import Network

final class MouseConnection: @unchecked Sendable {
    typealias ReadyHandler = @Sendable (MousePeer) -> Void
    typealias AcquiredHandler = @Sendable (UInt64) -> Void
    typealias ReleasedHandler = @Sendable (UInt64) -> Void
    typealias LeaveHandler = @Sendable (UInt64, UInt16) -> Void
    typealias DisconnectHandler = @Sendable (String?) -> Void
    typealias DriverUnavailableHandler = @Sendable () -> Void
    typealias RemoteShutdownCompletion = @Sendable (Bool) -> Void

    private struct ActiveWrite {
        let id: UInt64
        let deadline: ContinuousClock.Instant
        let includesRemoteShutdown: Bool
    }

    let id: UUID

    private let connection: NWConnection
    private let queue = DispatchQueue(
        label: "com.sunkanwei.Meno.MouseConnection",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let mailboxLock = NSLock()
    private let localName: String
    private let onReady: ReadyHandler
    private let onAcquired: AcquiredHandler
    private let onReleased: ReleasedHandler
    private let onLeave: LeaveHandler
    private let onDisconnect: DisconnectHandler
    private let onDriverUnavailable: DriverUnavailableHandler
    private var mailbox = MouseOutboundMailbox()
    private var readiness = ConnectionReadinessGate()
    private lazy var transport = CompanionFrameTransport(
        connection: connection,
        queue: queue,
        onFrame: { [weak self] frame in
            try self?.handle(frame)
        },
        onActivity: { [weak self] in
            self?.recordActivity()
        },
        onClosed: { [weak self] reason in
            self?.disconnect(reason)
        }
    )
    private var didDisconnect = false
    private var handshakeTimer: DispatchSourceTimer?
    private var remoteShutdownSupported = false
    private var remoteShutdownCompletion: RemoteShutdownCompletion?
    private var sending = false
    private var activeWrite: ActiveWrite?
    private var nextWriteID: UInt64 = 1
    private var nextMessageID = UInt64.random(in: 1...UInt64.max)
    private var keepaliveTimer: DispatchSourceTimer?
    private var controlHeartbeatTimer: DispatchSourceTimer?
    private var writeWatchdogTimer: DispatchSourceTimer?
    private var activeControlID: UInt64?
    private var lastActivity = ContinuousClock.now
    private var waitingForPong = false
    private static let maximumFramesPerWrite = 4
    private static let writeTimeout: Duration = .milliseconds(100)
    private static let handshakeTimeout: Duration = .seconds(5)
    private static let idleBeforePing: Duration = .seconds(30)
    private static let pongTimeout: Duration = .seconds(10)
    private static let controlHeartbeatInterval: TimeInterval = 0.1
    init(
        id: UUID,
        connection: NWConnection,
        localName: String,
        onReady: @escaping ReadyHandler,
        onAcquired: @escaping AcquiredHandler,
        onReleased: @escaping ReleasedHandler,
        onLeave: @escaping LeaveHandler,
        onDriverUnavailable: @escaping DriverUnavailableHandler,
        onDisconnect: @escaping DisconnectHandler
    ) {
        self.id = id
        self.connection = connection
        self.localName = localName
        self.onReady = onReady
        self.onAcquired = onAcquired
        self.onReleased = onReleased
        self.onLeave = onLeave
        self.onDriverUnavailable = onDriverUnavailable
        self.onDisconnect = onDisconnect
    }

    func start() {
        transport.start()
        queue.async { [weak self] in
            self?.scheduleHandshakeTimeout()
        }
    }

    func stop() {
        queue.async {
            self.transport.cancel()
        }
    }

    func sendEnter(
        controlID: UInt64,
        normalizedY: UInt16,
        residualX: Int32,
        entryEdge: HorizontalDisplaySide,
        returnOpeningY: ClosedRange<Int32>
    ) {
        let result = mailboxLock.withCriticalSection {
            mailbox.beginSession(
                controlID: controlID,
                normalizedY: normalizedY,
                residualX: residualX,
                entryEdge: entryEdge,
                returnOpeningY: returnOpeningY
            )
        }
        switch result {
        case .scheduleDrain, .queued:
            queue.async { [weak self] in
                guard let self, readiness.isReady, !didDisconnect else { return }
                guard activeControlID == nil || activeControlID == controlID else {
                    failConnection("跨屏鼠标会话发生重叠。")
                    return
                }
                activeControlID = controlID
                let shouldHeartbeat = mailboxLock.withCriticalSection {
                    mailbox.isAccepting(controlID: controlID)
                }
                if shouldHeartbeat { startControlHeartbeat() }
                if result == .scheduleDrain { drainMailbox() }
            }
        case .failed:
            scheduleMailboxFailure()
        case .ignored:
            break
        }
    }

    func sendMove(controlID: UInt64, dx: Int32, dy: Int32) {
        guard dx != 0 || dy != 0 else { return }
        submit { mailbox in
            mailbox.enqueueMove(
                controlID: controlID,
                dx: dx,
                dy: dy
            )
        }
    }

    func sendButton(controlID: UInt64, _ button: UInt8, down: Bool) {
        submit { mailbox in
            mailbox.enqueueButton(
                controlID: controlID,
                button: button,
                down: down
            )
        }
    }

    func sendWheel(controlID: UInt64, _ inputLines: Double) {
        guard inputLines != 0 else { return }
        submit { mailbox in
            mailbox.enqueueWheel(
                controlID: controlID,
                inputLines: inputLines
            )
        }
    }

    func sendKeyboardState(controlID: UInt64, _ report: KeyboardReport) {
        submit { mailbox in
            mailbox.enqueueKeyboard(
                controlID: controlID,
                report: report
            )
        }
    }

    func sendReleaseAll(controlID: UInt64) {
        let result = mailboxLock.withCriticalSection {
            mailbox.enqueueRelease(controlID: controlID)
        }
        queue.async { [weak self] in
            guard let self else { return }
            stopControlHeartbeat()
            handleQueueSubmission(result)
        }
    }

    func abortControl(controlID: UInt64) {
        let result = mailboxLock.withCriticalSection {
            mailbox.abortControl(controlID: controlID)
        }
        queue.async { [weak self] in
            guard let self else { return }
            stopControlHeartbeat()
            handleQueueSubmission(result)
        }
    }

    func sendRemoteShutdown(completion: @escaping RemoteShutdownCompletion) {
        queue.async { [weak self] in
            guard let self, readiness.isReady, !didDisconnect, remoteShutdownSupported,
                  remoteShutdownCompletion == nil else {
                completion(false)
                return
            }
            remoteShutdownCompletion = completion
            let result = mailboxLock.withCriticalSection {
                mailbox.enqueueConnectionFrame(kind: .shutdownRequest, payload: Data())
            }
            switch result {
            case .scheduleDrain:
                drainMailbox()
            case .queued:
                break
            case .ignored:
                finishRemoteShutdownWrite(succeeded: false)
            case .failed:
                finishRemoteShutdownWrite(succeeded: false)
                failConnection("跨屏鼠标发送邮箱无法保持事件顺序。")
            }
        }
    }

    private func submit(
        _ operation: (inout MouseOutboundMailbox) -> MouseMailboxSubmission
    ) {
        let result = mailboxLock.withCriticalSection {
            operation(&mailbox)
        }
        switch result {
        case .scheduleDrain:
            queue.async { [weak self] in self?.drainMailbox() }
        case .failed:
            scheduleMailboxFailure()
        case .ignored, .queued:
            break
        }
    }

    private func scheduleMailboxFailure() {
        queue.async { [weak self] in
            self?.failConnection("跨屏鼠标发送邮箱无法保持事件顺序。")
        }
    }

    private func handleQueueSubmission(_ result: MouseMailboxSubmission) {
        switch result {
        case .scheduleDrain:
            drainMailbox()
        case .failed:
            failConnection("跨屏鼠标发送邮箱无法保持事件顺序。")
        case .ignored, .queued:
            break
        }
    }

    private func drainMailbox() {
        guard !didDisconnect, !sending else { return }
        let specs = mailboxLock.withCriticalSection {
            mailbox.dequeue(maximumFrameCount: Self.maximumFramesPerWrite)
        }
        guard !specs.isEmpty else { return }

        var content = Data(capacity: specs.reduce(0) {
            $0 + ClipboardWire.headerSize + $1.payload.count
        })
        for spec in specs {
            content.append(frame(kind: spec.kind, payload: spec.payload).encoded())
        }
        sending = true
        let writeID = nextWriteID
        nextWriteID &+= 1
        if nextWriteID == 0 { nextWriteID = 1 }
        let startedAt = ContinuousClock.now
        activeWrite = ActiveWrite(
            id: writeID,
            deadline: startedAt.advanced(by: Self.writeTimeout),
            includesRemoteShutdown: specs.contains { $0.kind == .shutdownRequest }
        )
        armWriteWatchdog()
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            self?.completeWrite(id: writeID, error: error)
        })
    }

    private func completeWrite(id: UInt64, error: NWError?) {
        guard let write = activeWrite, write.id == id, !didDisconnect else { return }
        let now = ContinuousClock.now
        if now >= write.deadline {
            failConnection("跨屏鼠标网络写入超过 100 毫秒。")
            return
        }
        if let error {
            failConnection(error.localizedDescription)
            return
        }
        activeWrite = nil
        sending = false
        disarmWriteWatchdog()
        recordActivity()
        drainMailbox()
        if write.includesRemoteShutdown {
            finishRemoteShutdownWrite(succeeded: true)
        }
    }

    private func armWriteWatchdog() {
        let timer: DispatchSourceTimer
        if let writeWatchdogTimer {
            timer = writeWatchdogTimer
        } else {
            let newTimer = DispatchSource.makeTimerSource(queue: queue)
            newTimer.setEventHandler { [weak self] in
                self?.writeWatchdogFired()
            }
            newTimer.resume()
            writeWatchdogTimer = newTimer
            timer = newTimer
        }
        timer.schedule(deadline: .now() + Self.writeTimeout.timeInterval)
    }

    private func disarmWriteWatchdog() {
        writeWatchdogTimer?.schedule(deadline: .distantFuture)
    }

    private func writeWatchdogFired() {
        guard let write = activeWrite, !didDisconnect else { return }
        let now = ContinuousClock.now
        guard now >= write.deadline else {
            writeWatchdogTimer?.schedule(
                deadline: .now() + now.duration(to: write.deadline).timeInterval
            )
            return
        }
        failConnection("跨屏鼠标网络写入超过 100 毫秒。")
    }

    private func handle(_ frame: ClipboardFrame) throws {
        switch frame.kind {
        case .hello:
            guard let peer = MousePayload.decodeHello(frame.payload),
                  readiness.beginHello() else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            let ready = CompanionHello(
                name: localName,
                capabilities: peer.capabilities,
                driverABI: nil,
                screenWidth: nil,
                screenHeight: nil
            )
            sendReady(ready, peer: peer)
        case .mouseLeave:
            guard readiness.isReady, let leave = MousePayload.decodeLeave(frame.payload) else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            guard finishControl(controlID: leave.controlID) else { return }
            onLeave(leave.controlID, leave.normalizedY)
        case .mouseAcquired:
            guard readiness.isReady, let controlID = MousePayload.decodeControl(frame.payload) else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            guard activeControlID == controlID else { return }
            onAcquired(controlID)
        case .mouseReleased:
            guard readiness.isReady, let controlID = MousePayload.decodeControl(frame.payload) else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            guard finishControl(controlID: controlID) else { return }
            onReleased(controlID)
        case .mouseDriverUnavailable:
            guard readiness.isReady, frame.payload.isEmpty else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            if let controlID = activeControlID {
                _ = finishControl(controlID: controlID)
            }
            mailboxLock.withCriticalSection { mailbox.disableKeyboard() }
            onDriverUnavailable()
        case .ping:
            guard readiness.isReady, frame.payload.isEmpty else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            let result = mailboxLock.withCriticalSection {
                mailbox.enqueueConnectionFrame(kind: .pong, payload: Data())
            }
            handleQueueSubmission(result)
        case .pong:
            guard readiness.isReady, frame.payload.isEmpty else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            waitingForPong = false
            recordActivity()
        case .ready, .text, .png, .mouseEnter, .directionalMouseEnter,
             .mouseMove, .mouseButton, .mouseWheel,
             .mouseReleaseAll, .keyboardState, .mouseControlHeartbeat,
             .fileOffer, .fileAccept, .fileChunk, .fileComplete, .fileResult,
             .fileCancel, .fileAck, .shutdownRequest, .microphonePCM, .windowsOnline,
             .diagnosticEvent:
            throw ClipboardFrameDecoderError.invalidHeader
        }
    }

    private func finishRemoteShutdownWrite(succeeded: Bool) {
        let completion = remoteShutdownCompletion
        remoteShutdownCompletion = nil
        completion?(succeeded)
    }

    private func frame(kind: ClipboardMessageKind, payload: Data) -> ClipboardFrame {
        let messageID = nextMessageID
        nextMessageID &+= 1
        if nextMessageID == 0 { nextMessageID = 1 }
        return ClipboardFrame(kind: kind, messageID: messageID, payload: payload)
    }

    private func startControlHeartbeat() {
        controlHeartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.controlHeartbeatInterval,
            repeating: Self.controlHeartbeatInterval,
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            guard let self, readiness.isReady, let controlID = activeControlID else { return }
            let result = mailboxLock.withCriticalSection {
                mailbox.enqueueHeartbeat(controlID: controlID)
            }
            handleQueueSubmission(result)
        }
        controlHeartbeatTimer = timer
        timer.resume()
    }

    private func stopControlHeartbeat() {
        controlHeartbeatTimer?.cancel()
        controlHeartbeatTimer = nil
    }

    private func finishControl(controlID: UInt64) -> Bool {
        guard activeControlID == controlID else { return false }
        stopControlHeartbeat()
        activeControlID = nil
        mailboxLock.withCriticalSection { mailbox.finishSession(controlID: controlID) }
        return true
    }

    private func recordActivity() {
        guard !didDisconnect else { return }
        lastActivity = .now
        if readiness.isReady, !waitingForPong, keepaliveTimer == nil {
            scheduleKeepalive(after: Self.idleBeforePing)
        }
    }

    private func sendReady(_ ready: CompanionHello, peer: MousePeer) {
        let content = frame(kind: .ready, payload: ready.encoded()).encoded()
        connection.send(content: content, completion: .contentProcessed { [weak self] error in
            guard let self, !didDisconnect else { return }
            if let error {
                failConnection(error.localizedDescription)
                return
            }
            handshakeTimer?.cancel()
            handshakeTimer = nil
            guard readiness.readyFrameWasSent() else {
                failConnection("鼠标通道 Ready 状态无效。")
                return
            }
            remoteShutdownSupported = peer.remoteShutdownSupported
            mailboxLock.withCriticalSection {
                mailbox.activate(
                    screenMetrics: peer.screenMetrics,
                    keyboardSupported: peer.keyboardSupported
                )
            }
            recordActivity()
            onReady(peer)
        })
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
            failConnection("Windows 未在 5 秒内完成鼠标通道握手。")
        }
        handshakeTimer = timer
        timer.resume()
    }

    private func scheduleKeepalive(after delay: Duration) {
        guard !didDisconnect else { return }
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay.timeInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.performKeepalive() }
        keepaliveTimer = timer
        timer.resume()
    }

    private func performKeepalive() {
        keepaliveTimer = nil
        guard !didDisconnect else { return }
        let now = ContinuousClock.now
        if waitingForPong {
            failConnection("Windows 鼠标通道未响应保活消息。")
            return
        }
        let idleDuration = lastActivity.duration(to: now)
        guard idleDuration >= Self.idleBeforePing else {
            scheduleKeepalive(after: Self.idleBeforePing - idleDuration)
            return
        }
        waitingForPong = true
        let result = mailboxLock.withCriticalSection {
            mailbox.enqueueConnectionFrame(kind: .ping, payload: Data())
        }
        handleQueueSubmission(result)
        scheduleKeepalive(after: Self.pongTimeout)
    }

    private func failConnection(_ reason: String?) {
        transport.close(reason)
    }

    private func disconnect(_ reason: String?) {
        guard !didDisconnect else { return }
        didDisconnect = true
        readiness.close()
        handshakeTimer?.cancel()
        handshakeTimer = nil
        remoteShutdownSupported = false
        finishRemoteShutdownWrite(succeeded: false)
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        stopControlHeartbeat()
        writeWatchdogTimer?.cancel()
        writeWatchdogTimer = nil
        activeWrite = nil
        sending = false
        activeControlID = nil
        mailboxLock.withCriticalSection { mailbox.deactivate() }
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
