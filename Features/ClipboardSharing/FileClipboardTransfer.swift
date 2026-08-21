import Foundation
final class FileClipboardTransfer: @unchecked Sendable {
    typealias FrameSender = @Sendable (ClipboardMessageKind, Data, @escaping @Sendable (Bool) -> Void) -> Void
    typealias FilePublisher = @Sendable ([URL], @escaping @Sendable (Bool) -> Void) -> Void
    typealias ProtocolViolationHandler = @Sendable (String) -> Void

    private enum OutgoingPhase {
        case waitingAccept
        case waitingAck(FileClipboardAck)
        case waitingResult
    }

    private struct OutgoingTransfer {
        let manifest: FileClipboardSourceManifest
        var phase: OutgoingPhase
        var nextEntryIndex = 0
        var currentOffset: UInt64 = 0
        var fileHandle: FileHandle?
    }

    private struct IncomingTransfer {
        let offer: FileClipboardOffer
        let layout: FileClipboardReceiveLayout
        var receivedBytes: [UInt64]
        var fileHandle: FileHandle?
        var isPublishing = false
    }

    private let queue = DispatchQueue(label: "com.sunkanwei.Meno.FileClipboardTransfer")
    private let sendFrame: FrameSender
    private let publishFiles: FilePublisher
    private let onProtocolViolation: ProtocolViolationHandler
    private var outgoing: OutgoingTransfer?
    private var incoming: IncomingTransfer?
    private var outgoingTimer: DispatchSourceTimer?
    private var incomingTimer: DispatchSourceTimer?
    private var finishedTransferIDs: [UUID] = []

    private static let responseTimeout: TimeInterval = 15
    private static let chunkTimeout: TimeInterval = 30

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

    private func beginSending(_ urls: [URL]) {
        cancelOutgoing(reason: .superseded, notifyPeer: true)
        let transferID = UUID()
        let manifest: FileClipboardSourceManifest
        do {
            manifest = try FileClipboardManifestBuilder.build(from: urls, transferID: transferID)
        } catch {
            return
        }
        outgoing = OutgoingTransfer(manifest: manifest, phase: .waitingAccept)
        sendWithTimeout(
            kind: .fileOffer,
            payload: FileClipboardWire.encodeOffer(manifest.offer),
            transferID: transferID,
            delay: Self.responseTimeout,
            expected: .accept
        )
    }

    private enum TimeoutExpectation: Equatable {
        case accept
        case ack(FileClipboardAck)
        case result
    }

    private func sendWithTimeout(
        kind: ClipboardMessageKind,
        payload: Data,
        transferID: UUID,
        delay: TimeInterval,
        expected: TimeoutExpectation
    ) {
        sendFrame(kind, payload) { [weak self] sent in
            self?.queue.async { [weak self] in
                guard let self,
                      outgoing?.manifest.offer.transferID == transferID,
                      timeoutStillApplies(expected) else { return }
                if sent {
                    scheduleOutgoingTimeout(transferID: transferID, delay: delay, expected: expected)
                } else {
                    cancelOutgoing(reason: .timeout, notifyPeer: false)
                }
            }
        }
    }

    private func scheduleOutgoingTimeout(
        transferID: UUID,
        delay: TimeInterval,
        expected: TimeoutExpectation
    ) {
        outgoingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self,
                  outgoing?.manifest.offer.transferID == transferID,
                  timeoutStillApplies(expected) else { return }
            cancelOutgoing(reason: .timeout, notifyPeer: true)
        }
        outgoingTimer = timer
        timer.resume()
    }

    private func timeoutStillApplies(_ expected: TimeoutExpectation) -> Bool {
        guard let phase = outgoing?.phase else { return false }
        switch (expected, phase) {
        case (.accept, .waitingAccept), (.result, .waitingResult):
            return true
        case let (.ack(expected), .waitingAck(actual)):
            return expected == actual
        default:
            return false
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

    private func receiveOffer(_ payload: Data) throws {
        let offer = try FileClipboardWire.decodeOffer(payload)
        if finishedTransferIDs.contains(offer.transferID) { return }
        cancelOutgoing(reason: .superseded, notifyPeer: true)
        cancelIncoming(reason: .superseded, notifyPeer: true)

        let rootURL: URL
        do {
            rootURL = try FileClipboardCache.prepareIncomingTransfer(for: offer)
        } catch FileClipboardManifestError.insufficientSpace {
            sendResult(offer.transferID, .insufficientSpace)
            rememberFinished(offer.transferID)
            return
        } catch {
            sendResult(offer.transferID, .receiveWriteFailed)
            rememberFinished(offer.transferID)
            return
        }

        do {
            let layout = try FileClipboardDestinationMapper.makeLayout(for: offer, rootURL: rootURL)
            try FileClipboardCache.createDestinationSkeleton(offer: offer, layout: layout)
            incoming = IncomingTransfer(
                offer: offer,
                layout: layout,
                receivedBytes: Array(repeating: 0, count: offer.entries.count),
                fileHandle: nil
            )
            scheduleIncomingTimeout(transferID: offer.transferID, delay: Self.chunkTimeout)
            sendFrame(.fileAccept, FileClipboardWire.encodeTransferID(offer.transferID)) { _ in }
        } catch FileClipboardManifestError.insufficientSpace {
            FileClipboardCache.safelyRemoveTransferRoot(rootURL)
            sendResult(offer.transferID, .insufficientSpace)
            rememberFinished(offer.transferID)
        } catch {
            FileClipboardCache.safelyRemoveTransferRoot(rootURL)
            sendResult(offer.transferID, .receiveWriteFailed)
            rememberFinished(offer.transferID)
        }
    }

    private func receiveAccept(_ payload: Data) throws {
        let transferID = try FileClipboardWire.decodeTransferID(payload)
        guard let transfer = outgoing else {
            try ignoreFinishedOrThrow(transferID)
            return
        }
        guard transfer.manifest.offer.transferID == transferID,
              case .waitingAccept = transfer.phase else {
            throw FileClipboardProtocolError.malformedPayload
        }
        outgoingTimer?.cancel()
        outgoingTimer = nil
        outgoing = transfer
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard var transfer = outgoing else { return }
        let entries = transfer.manifest.offer.entries

        while transfer.nextEntryIndex < entries.count {
            let index = transfer.nextEntryIndex
            let entry = entries[index]
            let sourceURL = transfer.manifest.sourceURLs[index]
            guard FileClipboardManifestBuilder.sourceStillMatches(sourceURL, entry: entry) else {
                outgoing = transfer
                cancelOutgoing(reason: .sourceChanged, notifyPeer: true)
                return
            }
            guard entry.kind == .regularFile else {
                transfer.nextEntryIndex += 1
                transfer.currentOffset = 0
                continue
            }
            if entry.size == 0 {
                transfer.nextEntryIndex += 1
                transfer.currentOffset = 0
                continue
            }

            do {
                if transfer.fileHandle == nil {
                    transfer.fileHandle = try FileHandle(forReadingFrom: sourceURL)
                    try transfer.fileHandle?.seek(toOffset: transfer.currentOffset)
                }
                let remaining = entry.size - transfer.currentOffset
                let count = Int(min(UInt64(FileClipboardWire.maximumChunkSize), remaining))
                guard let data = try transfer.fileHandle?.read(upToCount: count),
                      data.count == count else {
                    throw FileClipboardManifestError.sourceUnavailable
                }
                let nextOffset = transfer.currentOffset + UInt64(data.count)
                let ack = FileClipboardAck(
                    transferID: transfer.manifest.offer.transferID,
                    entryIndex: UInt32(index),
                    nextOffset: nextOffset
                )
                transfer.phase = .waitingAck(ack)
                outgoing = transfer
                sendWithTimeout(
                    kind: .fileChunk,
                    payload: FileClipboardWire.encodeChunk(
                        FileClipboardChunk(
                            transferID: ack.transferID,
                            entryIndex: ack.entryIndex,
                            offset: transfer.currentOffset,
                            data: data
                        )
                    ),
                    transferID: ack.transferID,
                    delay: Self.chunkTimeout,
                    expected: .ack(ack)
                )
                return
            } catch {
                transfer.fileHandle?.closeFile()
                outgoing = transfer
                cancelOutgoing(reason: .sourceReadFailed, notifyPeer: true)
                return
            }
        }

        guard zip(transfer.manifest.sourceURLs, entries).allSatisfy({
            FileClipboardManifestBuilder.sourceStillMatches($0, entry: $1)
        }) else {
            outgoing = transfer
            cancelOutgoing(reason: .sourceChanged, notifyPeer: true)
            return
        }
        transfer.phase = .waitingResult
        outgoing = transfer
        let transferID = transfer.manifest.offer.transferID
        sendWithTimeout(
            kind: .fileComplete,
            payload: FileClipboardWire.encodeTransferID(transferID),
            transferID: transferID,
            delay: Self.responseTimeout,
            expected: .result
        )
    }

    private func receiveAck(_ payload: Data) throws {
        let ack = try FileClipboardWire.decodeAck(payload)
        guard var transfer = outgoing else {
            try ignoreFinishedOrThrow(ack.transferID)
            return
        }
        guard transfer.manifest.offer.transferID == ack.transferID,
              case let .waitingAck(expected) = transfer.phase,
              expected == ack else {
            throw FileClipboardProtocolError.malformedPayload
        }
        outgoingTimer?.cancel()
        outgoingTimer = nil
        transfer.currentOffset = ack.nextOffset
        let entry = transfer.manifest.offer.entries[transfer.nextEntryIndex]
        if transfer.currentOffset == entry.size {
            transfer.fileHandle?.closeFile()
            transfer.fileHandle = nil
            let sourceURL = transfer.manifest.sourceURLs[transfer.nextEntryIndex]
            guard FileClipboardManifestBuilder.sourceStillMatches(sourceURL, entry: entry) else {
                outgoing = transfer
                cancelOutgoing(reason: .sourceChanged, notifyPeer: true)
                return
            }
            transfer.nextEntryIndex += 1
            transfer.currentOffset = 0
        }
        outgoing = transfer
        sendNextChunk()
    }

    private func receiveChunk(_ payload: Data) throws {
        let chunk = try FileClipboardWire.decodeChunk(payload)
        guard var transfer = incoming else {
            try ignoreFinishedOrThrow(chunk.transferID)
            return
        }
        guard transfer.offer.transferID == chunk.transferID,
              !transfer.isPublishing,
              Int(chunk.entryIndex) < transfer.offer.entries.count else {
            throw FileClipboardProtocolError.malformedPayload
        }
        let index = Int(chunk.entryIndex)
        let entry = transfer.offer.entries[index]
        guard entry.kind == .regularFile,
              entry.size > 0,
              transfer.receivedBytes[index] == chunk.offset,
              chunk.offset <= entry.size,
              UInt64(chunk.data.count) <= entry.size - chunk.offset,
              nextIncompleteFile(in: transfer) == index else {
            throw FileClipboardProtocolError.malformedPayload
        }

        do {
            if transfer.fileHandle == nil {
                transfer.fileHandle = try FileHandle(forWritingTo: transfer.layout.itemURLs[index])
            }
            try transfer.fileHandle?.seek(toOffset: chunk.offset)
            try transfer.fileHandle?.write(contentsOf: chunk.data)
            let nextOffset = chunk.offset + UInt64(chunk.data.count)
            transfer.receivedBytes[index] = nextOffset
            if nextOffset == entry.size {
                try transfer.fileHandle?.close()
                transfer.fileHandle = nil
            }
            incoming = transfer
            scheduleIncomingTimeout(transferID: chunk.transferID, delay: Self.chunkTimeout)
            sendFrame(
                .fileAck,
                FileClipboardWire.encodeAck(
                    FileClipboardAck(
                        transferID: chunk.transferID,
                        entryIndex: chunk.entryIndex,
                        nextOffset: nextOffset
                    )
                )
            ) { _ in }
        } catch {
            incoming = transfer
            finishIncomingWithFailure(.receiveWriteFailed)
        }
    }

    private func receiveComplete(_ payload: Data) throws {
        let transferID = try FileClipboardWire.decodeTransferID(payload)
        guard var transfer = incoming else {
            try ignoreFinishedOrThrow(transferID)
            return
        }
        guard transfer.offer.transferID == transferID,
              !transfer.isPublishing,
              zip(transfer.offer.entries, transfer.receivedBytes).allSatisfy({ entry, count in
                  entry.kind == .directory ? count == 0 : count == entry.size
              }) else {
            throw FileClipboardProtocolError.malformedPayload
        }
        transfer.fileHandle?.closeFile()
        transfer.fileHandle = nil
        incomingTimer?.cancel()
        incomingTimer = nil
        do {
            try FileClipboardCache.applyMetadata(offer: transfer.offer, layout: transfer.layout)
            try FileClipboardCache.markCompleted(offer: transfer.offer, layout: transfer.layout)
        } catch {
            incoming = transfer
            finishIncomingWithFailure(.receiveWriteFailed)
            return
        }
        transfer.isPublishing = true
        incoming = transfer
        scheduleIncomingTimeout(transferID: transferID, delay: Self.responseTimeout)
        publishFiles(transfer.layout.topLevelURLs) { [weak self] wrote in
            self?.queue.async { [weak self] in
                guard let self,
                      let current = incoming,
                      current.offer.transferID == transferID,
                      current.isPublishing else { return }
                if wrote {
                    incomingTimer?.cancel()
                    incomingTimer = nil
                    sendResult(transferID, .success)
                    rememberFinished(transferID)
                    incoming = nil
                    cleanupExpiredCache()
                } else {
                    finishIncomingWithFailure(.clipboardWriteFailed)
                }
            }
        }
    }

    private func receiveResult(_ payload: Data) throws {
        let (transferID, _): (UUID, FileClipboardResultStatus) = try FileClipboardWire.decodeStatus(
            payload,
            as: FileClipboardResultStatus.self
        )
        guard let transfer = outgoing else {
            try ignoreFinishedOrThrow(transferID)
            return
        }
        guard transfer.manifest.offer.transferID == transferID,
              case .waitingResult = transfer.phase else {
            throw FileClipboardProtocolError.malformedPayload
        }
        outgoingTimer?.cancel()
        outgoingTimer = nil
        transfer.fileHandle?.closeFile()
        outgoing = nil
        rememberFinished(transferID)
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

    private func nextIncompleteFile(in transfer: IncomingTransfer) -> Int? {
        for (index, entry) in transfer.offer.entries.enumerated()
        where entry.kind == .regularFile && transfer.receivedBytes[index] < entry.size {
            return index
        }
        return nil
    }

    private func cancelOutgoing(reason: FileClipboardCancelReason, notifyPeer: Bool) {
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

    private func cancelIncoming(reason: FileClipboardCancelReason, notifyPeer: Bool) {
        guard let transfer = discardIncoming() else { return }
        if notifyPeer {
            sendFrame(
                .fileCancel,
                FileClipboardWire.encodeStatus(transfer.offer.transferID, status: reason.rawValue)
            ) { _ in }
        }
    }

    private func finishIncomingWithFailure(_ status: FileClipboardResultStatus) {
        guard let transfer = discardIncoming() else { return }
        sendResult(transfer.offer.transferID, status)
    }

    private func discardIncoming() -> IncomingTransfer? {
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

    private func scheduleIncomingTimeout(transferID: UUID, delay: TimeInterval) {
        incomingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, incoming?.offer.transferID == transferID else { return }
            cancelIncoming(reason: .timeout, notifyPeer: true)
        }
        incomingTimer = timer
        timer.resume()
    }

    private func sendResult(_ transferID: UUID, _ status: FileClipboardResultStatus) {
        sendFrame(
            .fileResult,
            FileClipboardWire.encodeStatus(transferID, status: status.rawValue)
        ) { _ in }
    }

    private func ignoreFinishedOrThrow(_ transferID: UUID) throws {
        guard finishedTransferIDs.contains(transferID) else {
            throw FileClipboardProtocolError.malformedPayload
        }
    }

    private func rememberFinished(_ transferID: UUID) {
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

    private func cleanupExpiredCache() {
        FileClipboardCache.cleanupExpired()
    }
}
