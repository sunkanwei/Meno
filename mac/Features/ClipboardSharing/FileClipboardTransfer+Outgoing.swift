import Foundation

extension FileClipboardTransfer {
    private enum TimeoutExpectation: Equatable {
        case accept
        case ack(FileClipboardAck)
        case result
    }

    func beginSending(_ urls: [URL]) {
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

    func receiveAccept(_ payload: Data) throws {
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

    func receiveAck(_ payload: Data) throws {
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

    func receiveResult(_ payload: Data) throws {
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
}
