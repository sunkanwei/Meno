import Foundation
import XCTest

final class RemoteDiagnosticsTests: XCTestCase {
    func testFixedDiagnosticPayloadAndFrameBytes() throws {
        let payload = fixedPayload()

        XCTAssertEqual(payload.count, 79)
        XCTAssertEqual(
            [UInt8](
                ClipboardFrame(
                    kind: .diagnosticEvent,
                    messageID: 0x0102_0304_0506_0708,
                    payload: payload
                ).encoded().prefix(20)
            ),
            [
                0x4D, 0x45, 0x4E, 0x4F,
                0x1F, 0, 0, 0,
                1, 2, 3, 4, 5, 6, 7, 8,
                0, 0, 0, 79,
            ]
        )

        guard case let .event(event) = RemoteDiagnosticPayload.decode(payload) else {
            return XCTFail("Expected a decoded diagnostic event")
        }
        XCTAssertEqual(event.kind, .leaveDecision)
        XCTAssertTrue(event.replayed)
        XCTAssertEqual(event.sourceSequence, 0x0102_0304_0506_0708)
        XCTAssertEqual(event.sourceUptimeMicros, 0x1112_1314_1516_1718)
        XCTAssertEqual(event.controlID, 0x2122_2324_2526_2728)
        XCTAssertEqual(event.fields.stateBefore, 3)
        XCTAssertEqual(event.fields.cursorX, -2)
        XCTAssertEqual(event.fields.boundary, 1)
        XCTAssertEqual(event.fields.processRunID, "00010203-0405-0607-0809-0A0B0C0D0E0F")
        XCTAssertEqual(
            event.fields.recentMotionSamples,
            [
                RemoteDiagnosticMotionSample(
                    ageMicros: 100,
                    cursorX: 10,
                    cursorY: -20,
                    deltaX: 3,
                    deltaY: -4
                )
            ]
        )
    }

    func testUnknownEventsAndFieldsAreIgnored() {
        var unknownEvent = fixedPayload()
        unknownEvent[0] = 0xFE
        XCTAssertEqual(RemoteDiagnosticPayload.decode(unknownEvent), .ignored)

        var unknownField = fixedPayload()
        unknownField.append(contentsOf: [0xFE, 0, 1, 0xAA])
        guard case let .event(event) = RemoteDiagnosticPayload.decode(unknownField) else {
            return XCTFail("Expected the unknown field to be ignored")
        }
        XCTAssertEqual(event.kind, .leaveDecision)
    }

    func testMalformedDiagnosticPayloadsAreRejected() {
        XCTAssertEqual(
            RemoteDiagnosticPayload.decode(Data(repeating: 0, count: 2_049)),
            .invalid
        )

        var invalidFlags = fixedPayload()
        invalidFlags[1] = 2
        XCTAssertEqual(RemoteDiagnosticPayload.decode(invalidFlags), .invalid)

        var duplicateField = fixedPayload()
        duplicateField.append(contentsOf: [1, 0, 1, 3])
        XCTAssertEqual(RemoteDiagnosticPayload.decode(duplicateField), .invalid)

        var truncatedTLV = fixedPayload()
        truncatedTLV.append(contentsOf: [2, 0, 2, 1])
        XCTAssertEqual(RemoteDiagnosticPayload.decode(truncatedTLV), .invalid)
    }

    func testJournalRotatesWithinConfiguredBound() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoRemoteDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RemoteDiagnosticsJournal(
            directoryURL: directory,
            maximumFileSize: 1,
            maximumFileCount: 3
        )
        guard case let .event(baseEvent) = RemoteDiagnosticPayload.decode(fixedPayload()) else {
            return XCTFail("Expected a decoded diagnostic event")
        }

        for sequence in 1...4 {
            let event = RemoteDiagnosticEvent(
                kind: baseEvent.kind,
                replayed: baseEvent.replayed,
                sourceSequence: UInt64(sequence),
                sourceUptimeMicros: baseEvent.sourceUptimeMicros,
                controlID: baseEvent.controlID,
                fields: baseEvent.fields
            )
            journal.record(
                event,
                connectionID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(sequence))
            )
        }
        journal.flush()

        let current = directory.appendingPathComponent("windows.jsonl")
        let first = directory.appendingPathComponent("windows.1.jsonl")
        let second = directory.appendingPathComponent("windows.2.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("windows.3.jsonl").path
            )
        )
        XCTAssertTrue(try String(contentsOf: current, encoding: .utf8).contains("\"sourceSequence\":4"))
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("\"sourceSequence\":3"))
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("\"sourceSequence\":2"))
    }

    func testJournalDeduplicatesReplayedSourceSequence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoRemoteDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RemoteDiagnosticsJournal(directoryURL: directory)
        guard case let .event(event) = RemoteDiagnosticPayload.decode(fixedPayload()) else {
            return XCTFail("Expected a decoded diagnostic event")
        }
        let connectionID = UUID()

        journal.record(event, connectionID: connectionID)
        journal.record(event, connectionID: connectionID)
        journal.flush()

        let content = try String(
            contentsOf: directory.appendingPathComponent("windows.jsonl"),
            encoding: .utf8
        )
        XCTAssertEqual(content.split(separator: "\n").count, 1)
    }

    private func fixedPayload() -> Data {
        Data([
            5, 1,
            1, 2, 3, 4, 5, 6, 7, 8,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
            0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
            1, 0, 1, 3,
            4, 0, 4, 0xFF, 0xFF, 0xFF, 0xFE,
            8, 0, 1, 1,
            12, 0, 16,
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
            18, 0, 16,
            0, 0, 0, 100,
            0, 0, 0, 10,
            0xFF, 0xFF, 0xFF, 0xEC,
            0, 3,
            0xFF, 0xFC,
        ])
    }
}
