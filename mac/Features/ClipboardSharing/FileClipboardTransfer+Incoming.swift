import Foundation

extension FileClipboardTransfer {
    func receiveOffer(_ payload: Data) throws {
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

    func receiveChunk(_ payload: Data) throws {
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

    func receiveComplete(_ payload: Data) throws {
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

    private func nextIncompleteFile(in transfer: IncomingTransfer) -> Int? {
        for (index, entry) in transfer.offer.entries.enumerated()
        where entry.kind == .regularFile && transfer.receivedBytes[index] < entry.size {
            return index
        }
        return nil
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

    private func finishIncomingWithFailure(_ status: FileClipboardResultStatus) {
        guard let transfer = discardIncoming() else { return }
        sendResult(transfer.offer.transferID, status)
    }
}
