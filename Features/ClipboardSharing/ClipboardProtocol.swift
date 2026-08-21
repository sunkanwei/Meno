import Foundation

// MENO wire numbering is append-only: never reorder, reuse, or reinterpret
// published values, and never fill numbering gaps (7). Peers must safely
// ignore capabilities they do not know.
enum CompanionCapability: UInt16, Sendable {
    case textClipboard = 1
    case pngClipboard = 2
    case mouseControl = 3
    case keyboardState = 4
    case fileClipboard = 5
    case remoteShutdown = 6
    case macMicrophone = 8
    case directionalMouseHandoff = 9
    case windowsOnline = 10
    case remoteDiagnostics = 11
}

struct CompanionHello: Equatable, Sendable {
    let name: String
    let capabilities: Set<CompanionCapability>
    let driverABI: UInt16?
    let screenWidth: UInt32?
    let screenHeight: UInt32?
    let audioPort: UInt16?

    init(
        name: String,
        capabilities: Set<CompanionCapability>,
        driverABI: UInt16?,
        screenWidth: UInt32?,
        screenHeight: UInt32?,
        audioPort: UInt16? = nil
    ) {
        self.name = name
        self.capabilities = capabilities
        self.driverABI = driverABI
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.audioPort = audioPort
    }

    func encoded() -> Data {
        var data = Data()
        data.appendField(
            id: 1,
            value: ClipboardWire.utf8Payload(name, maximumSize: ClipboardWire.maximumNameSize)
        )
        var capabilityData = Data()
        for capability in capabilities.sorted(by: { $0.rawValue < $1.rawValue }) {
            capabilityData.appendBigEndian(capability.rawValue)
        }
        data.appendField(id: 2, value: capabilityData)
        if let driverABI {
            var value = Data()
            value.appendBigEndian(driverABI)
            data.appendField(id: 3, value: value)
        }
        if let screenWidth {
            var value = Data()
            value.appendBigEndian(screenWidth)
            data.appendField(id: 4, value: value)
        }
        if let screenHeight {
            var value = Data()
            value.appendBigEndian(screenHeight)
            data.appendField(id: 5, value: value)
        }
        if let audioPort {
            precondition(audioPort != 0)
            var value = Data()
            value.appendBigEndian(audioPort)
            data.appendField(id: 6, value: value)
        }
        return data
    }

    static func decode(_ data: Data) -> CompanionHello? {
        guard data.count <= ClipboardWire.maximumHelloSize else { return nil }
        let bytes = [UInt8](data)
        var offset = 0
        var knownFields = Set<UInt8>()
        var name = ""
        var capabilities = Set<CompanionCapability>()
        var driverABI: UInt16?
        var screenWidth: UInt32?
        var screenHeight: UInt32?
        var audioPort: UInt16?

        while offset < bytes.count {
            guard bytes.count - offset >= 3 else { return nil }
            let fieldID = bytes[offset]
            let length = Int(bytes.readUInt16(at: offset + 1))
            let valueStart = offset + 3
            let valueEnd = valueStart + length
            guard valueEnd <= bytes.count else { return nil }
            if (1...6).contains(fieldID), !knownFields.insert(fieldID).inserted {
                return nil
            }
            let value = Array(bytes[valueStart..<valueEnd])
            switch fieldID {
            case 1:
                guard value.count <= ClipboardWire.maximumNameSize,
                      let decoded = String(bytes: value, encoding: .utf8) else { return nil }
                name = decoded
            case 2:
                guard value.count.isMultiple(of: 2), value.count <= 128 else { return nil }
                for capabilityOffset in stride(from: 0, to: value.count, by: 2) {
                    if let capability = CompanionCapability(
                        rawValue: value.readUInt16(at: capabilityOffset)
                    ) {
                        capabilities.insert(capability)
                    }
                }
            case 3:
                guard value.count == 2 else { return nil }
                driverABI = value.readUInt16(at: 0)
            case 4:
                guard value.count == 4 else { return nil }
                screenWidth = value.readUInt32(at: 0)
            case 5:
                guard value.count == 4 else { return nil }
                screenHeight = value.readUInt32(at: 0)
            case 6:
                guard value.count == 2 else { return nil }
                let port = value.readUInt16(at: 0)
                guard port != 0 else { return nil }
                audioPort = port
            default:
                break
            }
            offset = valueEnd
        }

        return CompanionHello(
            name: name,
            capabilities: capabilities,
            driverABI: driverABI,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            audioPort: audioPort
        )
    }
}

// Append-only wire numbering; gaps (26, 27) must never be filled. New
// features take fresh numbers, and receivers ignore unknown kinds.
enum ClipboardMessageKind: UInt8, Sendable {
    case hello = 1
    case ready = 2
    case text = 3
    case png = 4
    case ping = 5
    case pong = 6
    case mouseEnter = 7
    case mouseMove = 8
    case mouseButton = 9
    case mouseWheel = 10
    case mouseReleaseAll = 11
    case mouseLeave = 12
    case mouseDriverUnavailable = 13
    case keyboardState = 14
    case mouseAcquired = 15
    case mouseReleased = 16
    case mouseControlHeartbeat = 17
    case fileOffer = 18
    case fileAccept = 19
    case fileChunk = 20
    case fileComplete = 21
    case fileResult = 22
    case fileCancel = 23
    case fileAck = 24
    case shutdownRequest = 25
    case microphonePCM = 28
    case directionalMouseEnter = 29
    case windowsOnline = 30
    case diagnosticEvent = 31
}

struct ClipboardFrame: Sendable {
    let kind: ClipboardMessageKind
    let messageID: UInt64
    let payload: Data

    func encoded() -> Data {
        var data = Data(capacity: ClipboardWire.headerSize + payload.count)
        data.append(contentsOf: ClipboardWire.magic)
        data.append(kind.rawValue)
        data.append(contentsOf: [0, 0, 0])
        data.appendBigEndian(messageID)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

enum ClipboardWire {
    static let magic: [UInt8] = [0x4D, 0x45, 0x4E, 0x4F]
    static let discoveryPort: UInt16 = 45_891
    static let headerSize = 20
    static let maximumNameSize = 256
    static let maximumHelloSize = 512
    static let maximumTextSize = 1_048_576
    static let maximumImageSize = 33_554_432
    static let maximumPayloadSize = maximumImageSize
    static let maximumMouseMoveBatch = 16

    static func discoveryPacket(
        type: UInt8,
        clipboardPort: UInt16 = 0,
        mousePort: UInt16 = 0
    ) -> Data {
        var data = Data(magic)
        data.append(type)
        data.append(0)
        data.appendBigEndian(clipboardPort)
        data.appendBigEndian(mousePort)
        return data
    }

    static func isDiscoverPacket(_ data: Data) -> Bool {
        guard data.count == 10 else { return false }
        let bytes = [UInt8](data)
        return Array(bytes[0..<4]) == magic
            && bytes[4] == 1
            && bytes[5...9].allSatisfy({ $0 == 0 })
    }

    static func utf8Payload(_ value: String, maximumSize: Int) -> Data {
        var payload = Data()
        for character in value {
            let encoded = Data(String(character).utf8)
            guard payload.count + encoded.count <= maximumSize else { break }
            payload.append(encoded)
        }
        return payload
    }
}

enum ClipboardFrameDecoderError: LocalizedError {
    case invalidHeader
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "收到的剪贴板协议头无效。"
        case .payloadTooLarge:
            return "收到的剪贴板内容超过大小限制。"
        }
    }
}

struct ClipboardFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [ClipboardFrame] {
        buffer.append(data)
        var frames: [ClipboardFrame] = []

        while buffer.count >= ClipboardWire.headerSize {
            let bytes = [UInt8](buffer.prefix(ClipboardWire.headerSize))
            guard Array(bytes[0..<4]) == ClipboardWire.magic,
                  bytes[5] == 0,
                  bytes[6] == 0,
                  bytes[7] == 0 else {
                throw ClipboardFrameDecoderError.invalidHeader
            }
            let messageID = bytes.readUInt64(at: 8)
            let payloadLength = Int(bytes.readUInt32(at: 16))
            guard payloadLength <= ClipboardWire.maximumPayloadSize else {
                throw ClipboardFrameDecoderError.payloadTooLarge
            }
            let frameSize = ClipboardWire.headerSize + payloadLength
            guard buffer.count >= frameSize else { break }
            guard let kind = ClipboardMessageKind(rawValue: bytes[4]) else {
                buffer.removeSubrange(0..<frameSize)
                continue
            }
            frames.append(
                ClipboardFrame(
                    kind: kind,
                    messageID: messageID,
                    payload: Data(buffer[ClipboardWire.headerSize..<frameSize])
                )
            )
            buffer.removeSubrange(0..<frameSize)
        }

        return frames
    }
}

private extension Data {
    mutating func appendField(id: UInt8, value: Data) {
        precondition(value.count <= Int(UInt16.max))
        append(id)
        appendBigEndian(UInt16(value.count))
        append(value)
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    mutating func appendUUID(_ value: UUID) {
        Swift.withUnsafeBytes(of: value.uuid) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func readUInt16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func readUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in self[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}
