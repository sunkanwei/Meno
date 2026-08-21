import Foundation
import OSLog

enum RemoteDiagnosticEventKind: UInt8, Codable, Sendable {
    case processStarted = 1
    case connectionReady = 2
    case controlEnterReceived = 3
    case controlAcquired = 4
    case leaveDecision = 5
    case controlReleased = 6
    case heartbeatExpired = 7
    case driverUnavailable = 8
    case connectionClosed = 9
    case replayComplete = 10
}

struct RemoteDiagnosticBounds: Codable, Equatable, Sendable {
    let x: Int32
    let y: Int32
    let width: Int32
    let height: Int32
}

struct RemoteDiagnosticMotionSample: Codable, Equatable, Sendable {
    let ageMicros: UInt32
    let cursorX: Int32
    let cursorY: Int32
    let deltaX: Int16
    let deltaY: Int16
}

struct RemoteDiagnosticFields: Codable, Equatable, Sendable {
    var stateBefore: UInt8?
    var stateAfter: UInt8?
    var reason: UInt16?
    var cursorX: Int32?
    var cursorY: Int32?
    var deltaX: Int32?
    var deltaY: Int32?
    var boundary: UInt8?
    var threshold: Int32?
    var driverStatus: UInt8?
    var queueDepth: UInt16?
    var processRunID: String?
    var executableVersion: String?
    var buildID: String?
    var virtualDesktopBounds: RemoteDiagnosticBounds?
    var monitorBounds: RemoteDiagnosticBounds?
    var inputSource: UInt8?
    var recentMotionSamples: [RemoteDiagnosticMotionSample]?
}

struct RemoteDiagnosticEvent: Codable, Equatable, Sendable {
    static let maximumPayloadSize = 2_048
    static let maximumMotionSamples = 16

    let kind: RemoteDiagnosticEventKind
    let replayed: Bool
    let sourceSequence: UInt64
    let sourceUptimeMicros: UInt64
    let controlID: UInt64
    let fields: RemoteDiagnosticFields
}

enum RemoteDiagnosticDecodeResult: Equatable, Sendable {
    case event(RemoteDiagnosticEvent)
    case ignored
    case invalid
}

enum RemoteDiagnosticPayload {
    private static let fixedHeaderSize = 26

    static func decode(_ data: Data) -> RemoteDiagnosticDecodeResult {
        guard data.count >= fixedHeaderSize,
              data.count <= RemoteDiagnosticEvent.maximumPayloadSize else {
            return .invalid
        }
        var cursor = RemoteDiagnosticByteCursor(bytes: [UInt8](data))
        guard let rawKind = cursor.readUInt8(),
              let flags = cursor.readUInt8(),
              flags & 0xFE == 0,
              let sourceSequence = cursor.readUInt64(),
              let sourceUptimeMicros = cursor.readUInt64(),
              let controlID = cursor.readUInt64() else {
            return .invalid
        }
        guard let kind = RemoteDiagnosticEventKind(rawValue: rawKind) else {
            return .ignored
        }

        var fields = RemoteDiagnosticFields()
        var knownFields = Set<UInt8>()
        while !cursor.isAtEnd {
            guard let fieldID = cursor.readUInt8(),
                  let length = cursor.readUInt16(),
                  let value = cursor.readBytes(count: Int(length)) else {
                return .invalid
            }
            if (1...18).contains(fieldID), !knownFields.insert(fieldID).inserted {
                return .invalid
            }
            guard decodeField(fieldID, value: value, into: &fields) else {
                return .invalid
            }
        }

        return .event(
            RemoteDiagnosticEvent(
                kind: kind,
                replayed: flags & 1 != 0,
                sourceSequence: sourceSequence,
                sourceUptimeMicros: sourceUptimeMicros,
                controlID: controlID,
                fields: fields
            )
        )
    }

    private static func decodeField(
        _ fieldID: UInt8,
        value: [UInt8],
        into fields: inout RemoteDiagnosticFields
    ) -> Bool {
        switch fieldID {
        case 1:
            guard value.count == 1 else { return false }
            fields.stateBefore = value[0]
        case 2:
            guard value.count == 1 else { return false }
            fields.stateAfter = value[0]
        case 3:
            guard value.count == 2 else { return false }
            fields.reason = value.readUInt16(at: 0)
        case 4:
            guard let decoded = value.readInt32() else { return false }
            fields.cursorX = decoded
        case 5:
            guard let decoded = value.readInt32() else { return false }
            fields.cursorY = decoded
        case 6:
            guard let decoded = value.readInt32() else { return false }
            fields.deltaX = decoded
        case 7:
            guard let decoded = value.readInt32() else { return false }
            fields.deltaY = decoded
        case 8:
            guard value.count == 1 else { return false }
            fields.boundary = value[0]
        case 9:
            guard let decoded = value.readInt32() else { return false }
            fields.threshold = decoded
        case 10:
            guard value.count == 1 else { return false }
            fields.driverStatus = value[0]
        case 11:
            guard value.count == 2 else { return false }
            fields.queueDepth = value.readUInt16(at: 0)
        case 12:
            guard value.count == 16 else { return false }
            fields.processRunID = uuidString(bytes: value)
        case 13:
            guard value.count <= 64, let decoded = String(bytes: value, encoding: .utf8) else {
                return false
            }
            fields.executableVersion = decoded
        case 14:
            guard value.count <= 64, let decoded = String(bytes: value, encoding: .utf8) else {
                return false
            }
            fields.buildID = decoded
        case 15:
            guard let decoded = value.readBounds() else { return false }
            fields.virtualDesktopBounds = decoded
        case 16:
            guard let decoded = value.readBounds() else { return false }
            fields.monitorBounds = decoded
        case 17:
            guard value.count == 1 else { return false }
            fields.inputSource = value[0]
        case 18:
            guard value.count.isMultiple(of: 16),
                  value.count / 16 <= RemoteDiagnosticEvent.maximumMotionSamples else {
                return false
            }
            fields.recentMotionSamples = stride(from: 0, to: value.count, by: 16).map {
                RemoteDiagnosticMotionSample(
                    ageMicros: value.readUInt32(at: $0),
                    cursorX: Int32(bitPattern: value.readUInt32(at: $0 + 4)),
                    cursorY: Int32(bitPattern: value.readUInt32(at: $0 + 8)),
                    deltaX: Int16(bitPattern: value.readUInt16(at: $0 + 12)),
                    deltaY: Int16(bitPattern: value.readUInt16(at: $0 + 14))
                )
            }
        default:
            break
        }
        return true
    }

    private static func uuidString(bytes: [UInt8]) -> String {
        bytes.enumerated().map { index, byte in
            let separator = [4, 6, 8, 10].contains(index) ? "-" : ""
            return separator + String(format: "%02X", byte)
        }.joined()
    }
}

private struct RemoteDiagnosticByteCursor {
    let bytes: [UInt8]
    private(set) var offset = 0

    var isAtEnd: Bool { offset == bytes.count }

    mutating func readUInt8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard offset <= bytes.count - 2 else { return nil }
        defer { offset += 2 }
        return bytes.readUInt16(at: offset)
    }

    mutating func readUInt64() -> UInt64? {
        guard offset <= bytes.count - 8 else { return nil }
        defer { offset += 8 }
        return bytes.readUInt64(at: offset)
    }

    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0, offset <= bytes.count - count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}

private extension Array where Element == UInt8 {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) << 32 | UInt64(readUInt32(at: offset + 4))
    }

    func readInt32() -> Int32? {
        guard count == 4 else { return nil }
        return Int32(bitPattern: readUInt32(at: 0))
    }

    func readBounds() -> RemoteDiagnosticBounds? {
        guard count == 16 else { return nil }
        return RemoteDiagnosticBounds(
            x: Int32(bitPattern: readUInt32(at: 0)),
            y: Int32(bitPattern: readUInt32(at: 4)),
            width: Int32(bitPattern: readUInt32(at: 8)),
            height: Int32(bitPattern: readUInt32(at: 12))
        )
    }
}

private struct RemoteDiagnosticJournalRecord: Encodable, Sendable {
    let receivedAt: String
    let connectionID: String
    let event: RemoteDiagnosticEvent
}

final class RemoteDiagnosticsJournal: @unchecked Sendable {
    static let shared = RemoteDiagnosticsJournal(
        directoryURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Meno/Diagnostics", isDirectory: true)
    )

    private let directoryURL: URL
    private let maximumFileSize: Int
    private let maximumFileCount: Int
    private let queue = DispatchQueue(
        label: "com.sunkanwei.Meno.RemoteDiagnosticsJournal",
        qos: .utility
    )
    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "RemoteDiagnostics"
    )
    private let encoder: JSONEncoder
    private var seenKeys = Set<String>()
    private var seenKeyOrder: [String] = []
    private static let maximumSeenKeyCount = 4_096

    init(
        directoryURL: URL,
        maximumFileSize: Int = 5 * 1_024 * 1_024,
        maximumFileCount: Int = 5
    ) {
        precondition(maximumFileSize > 0)
        precondition(maximumFileCount > 0)
        self.directoryURL = directoryURL
        self.maximumFileSize = maximumFileSize
        self.maximumFileCount = maximumFileCount
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func record(_ event: RemoteDiagnosticEvent, connectionID: UUID, receivedAt: Date = Date()) {
        let record = RemoteDiagnosticJournalRecord(
            receivedAt: receivedAt.formatted(
                .iso8601.year().month().day().time(includingFractionalSeconds: true)
            ),
            connectionID: connectionID.uuidString,
            event: event
        )
        queue.async { [self] in
            do {
                guard shouldPersist(record.event) else { return }
                var line = try encoder.encode(record)
                line.append(0x0A)
                try append(line)
            } catch {
                logger.error("Unable to persist Windows diagnostics: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private var currentFileURL: URL {
        directoryURL.appendingPathComponent("windows.jsonl")
    }

    private func shouldPersist(_ event: RemoteDiagnosticEvent) -> Bool {
        guard let processRunID = event.fields.processRunID else { return true }
        let key = "\(processRunID):\(event.sourceSequence)"
        guard seenKeys.insert(key).inserted else { return false }
        seenKeyOrder.append(key)
        if seenKeyOrder.count > Self.maximumSeenKeyCount {
            seenKeys.remove(seenKeyOrder.removeFirst())
        }
        return true
    }

    private func archivedFileURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("windows.\(index).jsonl")
    }

    private func append(_ line: Data) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let currentSize = (try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if currentSize > 0, currentSize + line.count > maximumFileSize {
            try rotate()
        }
        if !fileManager.fileExists(atPath: currentFileURL.path) {
            guard fileManager.createFile(atPath: currentFileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: currentFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func rotate() throws {
        let fileManager = FileManager.default
        if maximumFileCount == 1 {
            if fileManager.fileExists(atPath: currentFileURL.path) {
                try fileManager.removeItem(at: currentFileURL)
            }
            return
        }
        let lastArchive = archivedFileURL(maximumFileCount - 1)
        if fileManager.fileExists(atPath: lastArchive.path) {
            try fileManager.removeItem(at: lastArchive)
        }
        if maximumFileCount > 2 {
            for index in stride(from: maximumFileCount - 2, through: 1, by: -1) {
                let source = archivedFileURL(index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(at: source, to: archivedFileURL(index + 1))
            }
        }
        if fileManager.fileExists(atPath: currentFileURL.path) {
            try fileManager.moveItem(at: currentFileURL, to: archivedFileURL(1))
        }
    }
}
