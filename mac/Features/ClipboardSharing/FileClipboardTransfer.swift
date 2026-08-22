import Foundation
final class FileClipboardTransfer: @unchecked Sendable {
    typealias FrameSender = @Sendable (ClipboardMessageKind, Data, @escaping @Sendable (Bool) -> Void) -> Void
    typealias FilePublisher = @Sendable ([URL], @escaping @Sendable (Bool) -> Void) -> Void
    typealias ProtocolViolationHandler = @Sendable (String) -> Void

    enum OutgoingPhase {
        case waitingAccept
        case waitingAck(FileClipboardAck)
        case waitingResult
    }

    struct OutgoingTransfer {
        let manifest: FileClipboardSourceManifest
        var phase: OutgoingPhase
        var nextEntryIndex = 0
        var currentOffset: UInt64 = 0
        var fileHandle: FileHandle?
    }

    struct IncomingTransfer {
        let offer: FileClipboardOffer
        let layout: FileClipboardReceiveLayout
        var receivedBytes: [UInt64]
        var fileHandle: FileHandle?
        var isPublishing = false
    }

    let queue = DispatchQueue(label: "com.sunkanwei.Meno.FileClipboardTransfer")
    let sendFrame: FrameSender
    let publishFiles: FilePublisher
    let onProtocolViolation: ProtocolViolationHandler
    var outgoing: OutgoingTransfer?
    var incoming: IncomingTransfer?
    var outgoingTimer: DispatchSourceTimer?
    var incomingTimer: DispatchSourceTimer?
    var finishedTransferIDs: [UUID] = []

    static let responseTimeout: TimeInterval = 15
    static let chunkTimeout: TimeInterval = 30

    init(
        sendFrame: @escaping FrameSender,
        publishFiles: @escaping FilePublisher,
        onProtocolViolation: @escaping ProtocolViolationHandler
    ) {
        self.sendFrame = sendFrame
        self.publishFiles = publishFiles
        self.onProtocolViolation = onProtocolViolation
        cleanupExpiredCache()
    }

    func sendFiles(_ urls: [URL]) {
        queue.async { [weak self] in
            self?.beginSending(urls)
        }
    }

    func localClipboardChanged(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            cancelOutgoing(reason: .localClipboardChanged, notifyPeer: true)
            cancelIncoming(reason: .localClipboardChanged, notifyPeer: true)
            completion()
        }
    }

    func remoteContentSuperseded(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion()
                return
            }
            cancelOutgoing(reason: .superseded, notifyPeer: true)
            cancelIncoming(reason: .superseded, notifyPeer: true)
            completion()
        }
    }

    func receive(kind: ClipboardMessageKind, payload: Data) {
        queue.async { [weak self] in
            self?.handle(kind: kind, payload: payload)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            cancelOutgoing(reason: .superseded, notifyPeer: false)
            cancelIncoming(reason: .superseded, notifyPeer: false)
            cleanupExpiredCache()
        }
    }

    private func handle(kind: ClipboardMessageKind, payload: Data) {
        do {
            switch kind {
            case .fileOffer:
                try receiveOffer(payload)
            case .fileAccept:
                try receiveAccept(payload)
            case .fileChunk:
                try receiveChunk(payload)
            case .fileComplete:
                try receiveComplete(payload)
            case .fileResult:
                try receiveResult(payload)
            case .fileCancel:
                try receiveCancel(payload)
            case .fileAck:
                try receiveAck(payload)
            default:
                protocolViolation("文件传输状态机收到非文件消息。")
            }
        } catch FileClipboardProtocolError.invalidManifest {
            if kind == .fileOffer, let transferID = FileClipboardWire.transferIDPrefix(payload) {
                sendResult(transferID, .invalidManifest)
                rememberFinished(transferID)
            } else {
                protocolViolation("文件传输清单或状态无效。")
            }
        } catch {
            protocolViolation(error.localizedDescription)
        }
    }

    private func receiveCancel(_ payload: Data) throws {
        let (transferID, reason): (UUID, FileClipboardCancelReason) = try FileClipboardWire.decodeStatus(
            payload,
            as: FileClipboardCancelReason.self
        )
        var matched = false
        if outgoing?.manifest.offer.transferID == transferID {
            cancelOutgoing(reason: reason, notifyPeer: false)
            matched = true
        }
        if incoming?.offer.transferID == transferID {
            cancelIncoming(reason: reason, notifyPeer: false)
            matched = true
        }
        if !matched {
            try ignoreFinishedOrThrow(transferID)
        }
    }

    func cancelOutgoing(reason: FileClipboardCancelReason, notifyPeer: Bool) {
        guard let transfer = outgoing else { return }
        outgoingTimer?.cancel()
        outgoingTimer = nil
        transfer.fileHandle?.closeFile()
        outgoing = nil
        rememberFinished(transfer.manifest.offer.transferID)
        if notifyPeer {
            sendFrame(
                .fileCancel,
                FileClipboardWire.encodeStatus(transfer.manifest.offer.transferID, status: reason.rawValue)
            ) { _ in }
        }
    }

    func cancelIncoming(reason: FileClipboardCancelReason, notifyPeer: Bool) {
        guard let transfer = discardIncoming() else { return }
        if notifyPeer {
            sendFrame(
                .fileCancel,
                FileClipboardWire.encodeStatus(transfer.offer.transferID, status: reason.rawValue)
            ) { _ in }
        }
    }

    func discardIncoming() -> IncomingTransfer? {
        guard let transfer = incoming else { return nil }
        incomingTimer?.cancel()
        incomingTimer = nil
        transfer.fileHandle?.closeFile()
        incoming = nil
        FileClipboardCache.safelyRemoveTransferRoot(transfer.layout.rootURL)
        rememberFinished(transfer.offer.transferID)
        cleanupExpiredCache()
        return transfer
    }

    func sendResult(_ transferID: UUID, _ status: FileClipboardResultStatus) {
        sendFrame(
            .fileResult,
            FileClipboardWire.encodeStatus(transferID, status: status.rawValue)
        ) { _ in }
    }

    func ignoreFinishedOrThrow(_ transferID: UUID) throws {
        guard finishedTransferIDs.contains(transferID) else {
            throw FileClipboardProtocolError.malformedPayload
        }
    }

    func rememberFinished(_ transferID: UUID) {
        finishedTransferIDs.removeAll(where: { $0 == transferID })
        finishedTransferIDs.append(transferID)
        if finishedTransferIDs.count > 32 {
            finishedTransferIDs.removeFirst(finishedTransferIDs.count - 32)
        }
    }

    private func protocolViolation(_ message: String) {
        cancelOutgoing(reason: .superseded, notifyPeer: false)
        cancelIncoming(reason: .superseded, notifyPeer: false)
        onProtocolViolation(message)
    }

    func cleanupExpiredCache() {
        FileClipboardCache.cleanupExpired()
    }
}
