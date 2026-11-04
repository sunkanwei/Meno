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
                nextFileIndex: nextDataEntry(in: offer, from: 0),
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
        guard var transfer = incoming, transfer.offer.transferID == chunk.transferID else {
            try ignoreFinishedOrThrow(chunk.transferID)
            return
        }
        guard !transfer.isPublishing,
              let index = transfer.nextFileIndex,
              Int(chunk.entryIndex) == index else {
            throw FileClipboardProtocolError.malformedPayload
        }
        let entry = transfer.offer.entries[index]
        guard transfer.currentOffset == chunk.offset,
              chunk.offset <= entry.size,
              UInt64(chunk.data.count) <= entry.size - chunk.offset else {
            throw FileClipboardProtocolError.malformedPayload
        }

        do {
            if transfer.fileHandle == nil {
                transfer.fileHandle = try FileHandle(forWritingTo: transfer.layout.itemURLs[index])
            }
            try transfer.fileHandle?.seek(toOffset: chunk.offset)
            try transfer.fileHandle?.write(contentsOf: chunk.data)
            let nextOffset = chunk.offset + UInt64(chunk.data.count)
            transfer.currentOffset = nextOffset
            if nextOffset == entry.size {
                try transfer.fileHandle?.close()
                transfer.fileHandle = nil
                transfer.nextFileIndex = nextDataEntry(in: transfer.offer, from: index + 1)
                transfer.currentOffset = 0
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
        guard var transfer = incoming, transfer.offer.transferID == transferID else {
            try ignoreFinishedOrThrow(transferID)
            return
        }
        guard !transfer.isPublishing,
              transfer.nextFileIndex == nil else {
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
        publishFiles(transfer.layout.topLevelURLs) { [weak self, root = transfer.layout.rootURL] wrote in
            // The publisher updates clipboard protection before reporting success.
            FileClipboardCache.finishPublication(at: root)
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

    private func nextDataEntry(in offer: FileClipboardOffer, from index: Int) -> Int? {
        offer.entries[index...].firstIndex { $0.kind == .regularFile && $0.size > 0 }
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
        guard let transfer = discardIncoming(keepPendingPublication: false) else { return }
        sendResult(transfer.offer.transferID, status)
    }
}
