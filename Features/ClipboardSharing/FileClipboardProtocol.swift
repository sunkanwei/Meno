import Foundation

enum FileClipboardEntryKind: UInt8, Sendable {
    case directory = 1
    case regularFile = 2
}

struct FileClipboardEntry: Equatable, Sendable {
    static let hiddenFlag: UInt8 = 1

    let kind: FileClipboardEntryKind
    let flags: UInt8
    let parentIndex: UInt32?
    let name: String
    let size: UInt64
    let modifiedMillis: Int64

    var isHidden: Bool { flags & Self.hiddenFlag != 0 }
}

struct FileClipboardOffer: Equatable, Sendable {
    let transferID: UUID
    let entries: [FileClipboardEntry]
    let totalFileBytes: UInt64
}

struct FileClipboardChunk: Equatable, Sendable {
    let transferID: UUID
    let entryIndex: UInt32
    let offset: UInt64
    let data: Data
}

struct FileClipboardAck: Equatable, Sendable {
    let transferID: UUID
    let entryIndex: UInt32
    let nextOffset: UInt64
}

enum FileClipboardResultStatus: UInt8, Sendable {
    case success = 0
    case invalidManifest = 1
    case insufficientSpace = 2
    case receiveWriteFailed = 3
    case clipboardWriteFailed = 4
    case superseded = 5
}

enum FileClipboardCancelReason: UInt8, Sendable {
    case localClipboardChanged = 1
    case sourceChanged = 2
    case sourceReadFailed = 3
    case superseded = 4
    case timeout = 5
}

enum FileClipboardProtocolError: LocalizedError {
    case malformedPayload
    case invalidManifest

    var errorDescription: String? {
        "收到的文件剪贴板消息无效。"
    }
}

enum FileClipboardWire {
    static let maximumOfferSize = 16 * 1_024 * 1_024
    static let maximumChunkSize = 512 * 1_024
    static let maximumEntryCount = 20_000
    static let maximumRootCount = 128
    static let maximumDepth = 64
    static let maximumNameSize = 1_024
    static let maximumLogicalBytes: UInt64 = 50 * 1_024 * 1_024 * 1_024
    static let unknownModifiedMillis = Int64.min

    static func encodeOffer(_ offer: FileClipboardOffer) -> Data {
        precondition(!offer.transferID.isZero)
        precondition(!offer.entries.isEmpty && offer.entries.count <= maximumEntryCount)
        precondition(offer.totalFileBytes <= maximumLogicalBytes)
        var data = Data()
        data.appendUUID(offer.transferID)
        data.appendBigEndian(UInt32(offer.entries.count))
        data.appendBigEndian(offer.totalFileBytes)
        for entry in offer.entries {
            let name = Data(entry.name.utf8)
            precondition(!name.isEmpty && name.count <= maximumNameSize)
            data.append(entry.kind.rawValue)
            data.append(entry.flags)
            data.appendBigEndian(entry.parentIndex ?? UInt32.max)
            data.appendBigEndian(UInt16(name.count))
            data.append(name)
            data.appendBigEndian(entry.size)
            data.appendBigEndian(UInt64(bitPattern: entry.modifiedMillis))
        }
        precondition(data.count <= maximumOfferSize)
        return data
    }

    static func decodeOffer(_ data: Data) throws -> FileClipboardOffer {
        guard data.count <= maximumOfferSize else {
            throw FileClipboardProtocolError.invalidManifest
        }
        var cursor = FileClipboardCursor(data)
        guard let transferID = cursor.readUUID(), !transferID.isZero,
              let entryCountValue = cursor.readUInt32(),
              let totalFileBytes = cursor.readUInt64() else {
            throw FileClipboardProtocolError.malformedPayload
        }
        let entryCount = Int(entryCountValue)
        guard (1...maximumEntryCount).contains(entryCount) else {
            throw FileClipboardProtocolError.invalidManifest
        }

        var entries: [FileClipboardEntry] = []
        entries.reserveCapacity(entryCount)
        var depths: [Int] = []
        depths.reserveCapacity(entryCount)
        var rootCount = 0
        var calculatedBytes: UInt64 = 0

        for index in 0..<entryCount {
            guard let kindRaw = cursor.readUInt8(),
                  let kind = FileClipboardEntryKind(rawValue: kindRaw),
                  let flags = cursor.readUInt8(),
                  let rawParent = cursor.readUInt32(),
                  let nameLength = cursor.readUInt16() else {
                throw FileClipboardProtocolError.malformedPayload
            }
            let length = Int(nameLength)
            guard (1...maximumNameSize).contains(length),
                  let nameData = cursor.readData(count: length),
                  let name = String(data: nameData, encoding: .utf8),
                  nameData == Data(name.utf8),
                  isValidName(name),
                  let size = cursor.readUInt64(),
                  let modifiedBits = cursor.readUInt64() else {
                throw FileClipboardProtocolError.invalidManifest
            }

            let parentIndex: UInt32?
            let depth: Int
            if rawParent == UInt32.max {
                parentIndex = nil
                depth = 1
                rootCount += 1
            } else {
                guard rawParent < UInt32(index),
                      entries[Int(rawParent)].kind == .directory else {
                    throw FileClipboardProtocolError.invalidManifest
                }
                parentIndex = rawParent
                depth = depths[Int(rawParent)] + 1
            }
            guard depth <= maximumDepth,
                  kind != .directory || size == 0 else {
                throw FileClipboardProtocolError.invalidManifest
            }
            if kind == .regularFile {
                let (sum, overflow) = calculatedBytes.addingReportingOverflow(size)
                guard !overflow else { throw FileClipboardProtocolError.invalidManifest }
                calculatedBytes = sum
            }
            entries.append(
                FileClipboardEntry(
                    kind: kind,
                    flags: flags,
                    parentIndex: parentIndex,
                    name: name,
                    size: size,
                    modifiedMillis: Int64(bitPattern: modifiedBits)
                )
            )
            depths.append(depth)
        }

        guard cursor.isAtEnd,
              (1...maximumRootCount).contains(rootCount),
              calculatedBytes == totalFileBytes,
              calculatedBytes <= maximumLogicalBytes else {
            throw FileClipboardProtocolError.invalidManifest
        }
        return FileClipboardOffer(
            transferID: transferID,
            entries: entries,
            totalFileBytes: totalFileBytes
        )
    }

    static func encodeTransferID(_ transferID: UUID) -> Data {
        precondition(!transferID.isZero)
        var data = Data()
        data.appendUUID(transferID)
        return data
    }

    static func decodeTransferID(_ data: Data) throws -> UUID {
        var cursor = FileClipboardCursor(data)
        guard let transferID = cursor.readUUID(), !transferID.isZero, cursor.isAtEnd else {
            throw FileClipboardProtocolError.malformedPayload
        }
        return transferID
    }

    static func encodeChunk(_ chunk: FileClipboardChunk) -> Data {
        precondition(!chunk.transferID.isZero)
        precondition((1...maximumChunkSize).contains(chunk.data.count))
        var data = encodeTransferID(chunk.transferID)
        data.appendBigEndian(chunk.entryIndex)
        data.appendBigEndian(chunk.offset)
        data.append(chunk.data)
        return data
    }

    static func decodeChunk(_ data: Data) throws -> FileClipboardChunk {
        var cursor = FileClipboardCursor(data)
        guard let transferID = cursor.readUUID(), !transferID.isZero,
              let entryIndex = cursor.readUInt32(),
              let offset = cursor.readUInt64(),
              cursor.remainingCount > 0,
              cursor.remainingCount <= maximumChunkSize,
              let bytes = cursor.readData(count: cursor.remainingCount),
              cursor.isAtEnd else {
            throw FileClipboardProtocolError.malformedPayload
        }
        return FileClipboardChunk(
            transferID: transferID,
            entryIndex: entryIndex,
            offset: offset,
            data: bytes
        )
    }

    static func encodeAck(_ ack: FileClipboardAck) -> Data {
        var data = encodeTransferID(ack.transferID)
        data.appendBigEndian(ack.entryIndex)
        data.appendBigEndian(ack.nextOffset)
        return data
    }

    static func decodeAck(_ data: Data) throws -> FileClipboardAck {
        var cursor = FileClipboardCursor(data)
        guard let transferID = cursor.readUUID(), !transferID.isZero,
              let entryIndex = cursor.readUInt32(),
              let nextOffset = cursor.readUInt64(), cursor.isAtEnd else {
            throw FileClipboardProtocolError.malformedPayload
        }
        return FileClipboardAck(
            transferID: transferID,
            entryIndex: entryIndex,
            nextOffset: nextOffset
        )
    }

    static func encodeStatus(_ transferID: UUID, status: UInt8) -> Data {
        var data = encodeTransferID(transferID)
        data.append(status)
        return data
    }

    static func decodeStatus<T: RawRepresentable>(
        _ data: Data,
        as type: T.Type
    ) throws -> (UUID, T) where T.RawValue == UInt8 {
        var cursor = FileClipboardCursor(data)
        guard let transferID = cursor.readUUID(), !transferID.isZero,
              let rawValue = cursor.readUInt8(), let value = T(rawValue: rawValue),
              cursor.isAtEnd else {
            throw FileClipboardProtocolError.malformedPayload
        }
        return (transferID, value)
    }

    static func transferIDPrefix(_ data: Data) -> UUID? {
        var cursor = FileClipboardCursor(data)
        guard let id = cursor.readUUID(), !id.isZero else { return nil }
        return id
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("\0")
            && !name.contains("/")
            && !Data(name.utf8).isEmpty
            && Data(name.utf8).count <= maximumNameSize
    }
}

private struct FileClipboardCursor {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    var remainingCount: Int { bytes.count - offset }
    var isAtEnd: Bool { offset == bytes.count }

    mutating func readUInt8() -> UInt8? {
        guard remainingCount >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard remainingCount >= 2 else { return nil }
        defer { offset += 2 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    mutating func readUInt32() -> UInt32? {
        guard remainingCount >= 4 else { return nil }
        var value: UInt32 = 0
        for byte in bytes[offset..<(offset + 4)] { value = (value << 8) | UInt32(byte) }
        offset += 4
        return value
    }

    mutating func readUInt64() -> UInt64? {
        guard remainingCount >= 8 else { return nil }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] { value = (value << 8) | UInt64(byte) }
        offset += 8
        return value
    }

    mutating func readUUID() -> UUID? {
        guard let data = readData(count: 16) else { return nil }
        let b = [UInt8](data)
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, remainingCount >= count else { return nil }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }
}

private extension UUID {
    var isZero: Bool {
        Swift.withUnsafeBytes(of: uuid) { bytes in
            bytes.allSatisfy { $0 == 0 }
        }
    }
}
