import Foundation
import XCTest

final class FileClipboardTransferTests: XCTestCase {
    func testSenderWaitsForExactAckBeforeReadingNextChunk() throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let source = sourceRoot.appendingPathComponent("large.bin")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: source.path,
                contents: Data(repeating: 0x41, count: FileClipboardWire.maximumChunkSize + 1)
            )
        )
        defer { try? FileManager.default.removeItem(at: sourceRoot) }

        let recorder = FileTransferFrameRecorder()
        let violations = FileTransferSignal<String>()
        let transfer = makeTransfer(recorder: recorder, violations: violations)
        defer { transfer.stop() }

        transfer.sendFiles([source])
        let offerPayload = try XCTUnwrap(recorder.waitFor(kind: .fileOffer))
        let offer = try FileClipboardWire.decodeOffer(offerPayload)
        transfer.receive(kind: .fileAccept, payload: FileClipboardWire.encodeTransferID(offer.transferID))

        let firstPayload = try XCTUnwrap(recorder.waitFor(kind: .fileChunk))
        let first = try FileClipboardWire.decodeChunk(firstPayload)
        XCTAssertEqual(first.offset, 0)
        XCTAssertEqual(first.data.count, FileClipboardWire.maximumChunkSize)
        XCTAssertNil(recorder.waitFor(kind: .fileChunk, timeout: 0.1))

        transfer.receive(
            kind: .fileAck,
            payload: FileClipboardWire.encodeAck(
                FileClipboardAck(
                    transferID: offer.transferID,
                    entryIndex: first.entryIndex,
                    nextOffset: UInt64(first.data.count)
                )
            )
        )
        let secondPayload = try XCTUnwrap(recorder.waitFor(kind: .fileChunk))
        let second = try FileClipboardWire.decodeChunk(secondPayload)
        XCTAssertEqual(second.offset, UInt64(FileClipboardWire.maximumChunkSize))
        XCTAssertEqual(second.data, Data([0x41]))
        XCTAssertNil(violations.wait(timeout: 0.05))
    }

    func testReceiverWritesBeforeAckAndPublishesOnlyAfterComplete() throws {
        let recorder = FileTransferFrameRecorder()
        let violations = FileTransferSignal<String>()
        let published = FileTransferSignal<[URL]>()
        let transfer = FileClipboardTransfer(
            sendFrame: { kind, payload, completion in
                recorder.append(kind: kind, payload: payload)
                completion(true)
            },
            publishFiles: { urls, completion in
                published.send(urls)
                completion(true)
            },
            onProtocolViolation: { violations.send($0) }
        )
        defer { transfer.stop() }
        let transferID = UUID()
        let offer = FileClipboardOffer(
            transferID: transferID,
            entries: [
                FileClipboardEntry(
                    kind: .directory,
                    flags: 0,
                    parentIndex: nil,
                    name: "folder",
                    size: 0,
                    modifiedMillis: .min
                ),
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: 0,
                    name: "a.txt",
                    size: 2,
                    modifiedMillis: 1_000
                ),
            ],
            totalFileBytes: 2
        )

        transfer.receive(kind: .fileOffer, payload: FileClipboardWire.encodeOffer(offer))
        XCTAssertNotNil(recorder.waitFor(kind: .fileAccept))
        XCTAssertNil(published.wait(timeout: 0.05))
        transfer.receive(
            kind: .fileChunk,
            payload: FileClipboardWire.encodeChunk(
                FileClipboardChunk(
                    transferID: transferID,
                    entryIndex: 1,
                    offset: 0,
                    data: Data("OK".utf8)
                )
            )
        )
        let ackPayload = try XCTUnwrap(recorder.waitFor(kind: .fileAck))
        XCTAssertEqual(try FileClipboardWire.decodeAck(ackPayload).nextOffset, 2)
        XCTAssertNil(published.wait(timeout: 0.05))

        transfer.receive(kind: .fileComplete, payload: FileClipboardWire.encodeTransferID(transferID))
        let urls = try XCTUnwrap(published.wait())
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: urls[0].appendingPathComponent("a.txt")), Data("OK".utf8))
        let resultPayload = try XCTUnwrap(recorder.waitFor(kind: .fileResult))
        let (resultID, status): (UUID, FileClipboardResultStatus) = try FileClipboardWire.decodeStatus(
            resultPayload,
            as: FileClipboardResultStatus.self
        )
        XCTAssertEqual(resultID, transferID)
        XCTAssertEqual(status, .success)
        XCTAssertNil(violations.wait(timeout: 0.05))
    }

    func testWrongAckIsProtocolViolation() throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let source = sourceRoot.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data("OK".utf8)))
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let recorder = FileTransferFrameRecorder()
        let violations = FileTransferSignal<String>()
        let transfer = makeTransfer(recorder: recorder, violations: violations)
        defer { transfer.stop() }

        transfer.sendFiles([source])
        let offer = try FileClipboardWire.decodeOffer(
            XCTUnwrap(recorder.waitFor(kind: .fileOffer))
        )
        transfer.receive(kind: .fileAccept, payload: FileClipboardWire.encodeTransferID(offer.transferID))
        let chunk = try FileClipboardWire.decodeChunk(
            XCTUnwrap(recorder.waitFor(kind: .fileChunk))
        )
        transfer.receive(
            kind: .fileAck,
            payload: FileClipboardWire.encodeAck(
                FileClipboardAck(
                    transferID: offer.transferID,
                    entryIndex: chunk.entryIndex,
                    nextOffset: UInt64(chunk.data.count + 1)
                )
            )
        )

        XCTAssertNotNil(violations.wait())
    }

    func testRemoteClipboardContentCancelsOutgoingTransfer() throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let source = sourceRoot.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data("OK".utf8)))
        defer { try? FileManager.default.removeItem(at: sourceRoot) }
        let recorder = FileTransferFrameRecorder()
        let violations = FileTransferSignal<String>()
        let completed = FileTransferSignal<Bool>()
        let transfer = makeTransfer(recorder: recorder, violations: violations)
        defer { transfer.stop() }

        transfer.sendFiles([source])
        let offer = try FileClipboardWire.decodeOffer(
            XCTUnwrap(recorder.waitFor(kind: .fileOffer))
        )
        transfer.remoteContentSuperseded { completed.send(true) }

        XCTAssertEqual(completed.wait(), true)
        let cancel = try XCTUnwrap(recorder.waitFor(kind: .fileCancel))
        let (cancelID, reason): (UUID, FileClipboardCancelReason) = try FileClipboardWire.decodeStatus(
            cancel,
            as: FileClipboardCancelReason.self
        )
        XCTAssertEqual(cancelID, offer.transferID)
        XCTAssertEqual(reason, .superseded)
        transfer.receive(kind: .fileAccept, payload: FileClipboardWire.encodeTransferID(offer.transferID))
        XCTAssertNil(violations.wait(timeout: 0.05))
    }

    private func makeTransfer(
        recorder: FileTransferFrameRecorder,
        violations: FileTransferSignal<String>
    ) -> FileClipboardTransfer {
        FileClipboardTransfer(
            sendFrame: { kind, payload, completion in
                recorder.append(kind: kind, payload: payload)
                completion(true)
            },
            publishFiles: { _, completion in completion(false) },
            onProtocolViolation: { violations.send($0) }
        )
    }
}

private final class FileTransferFrameRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [(ClipboardMessageKind, Data)] = []

    func append(kind: ClipboardMessageKind, payload: Data) {
        condition.lock()
        frames.append((kind, payload))
        condition.broadcast()
        condition.unlock()
    }

    func waitFor(kind: ClipboardMessageKind, timeout: TimeInterval = 2) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = frames.firstIndex(where: { $0.0 == kind }) {
                return frames.remove(at: index).1
            }
            guard condition.wait(until: deadline) else { return nil }
        }
    }
}

private final class FileTransferSignal<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [Value] = []

    func send(_ value: Value) {
        condition.lock()
        values.append(value)
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval = 2) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while values.isEmpty {
            guard condition.wait(until: deadline) else { return nil }
        }
        return values.removeFirst()
    }
}
