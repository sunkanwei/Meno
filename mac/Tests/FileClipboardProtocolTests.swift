import Foundation
import XCTest

final class FileClipboardProtocolTests: XCTestCase {
    private let transferID = UUID(uuid: (
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
    ))

    func testOfferGoldenFrameMatchesFrozenProtocol() throws {
        let offer = FileClipboardOffer(
            transferID: transferID,
            entries: [
                FileClipboardEntry(
                    kind: .directory,
                    flags: 0,
                    parentIndex: nil,
                    name: "A",
                    size: 0,
                    modifiedMillis: .min
                ),
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: FileClipboardEntry.hiddenFlag,
                    parentIndex: 0,
                    name: "x.txt",
                    size: 2,
                    modifiedMillis: 1_000
                ),
            ],
            totalFileBytes: 2
        )
        let frame = ClipboardFrame(
            kind: .fileOffer,
            messageID: 0x0102_0304_0506_0708,
            payload: FileClipboardWire.encodeOffer(offer)
        )
        let expected = try XCTUnwrap(Data(hexadecimal: """
            4D454E4F12000000010203040506070800000052
            000102030405060708090A0B0C0D0E0F
            000000020000000000000002
            0100FFFFFFFF00014100000000000000008000000000000000
            0201000000000005782E747874000000000000000200000000000003E8
            """))

        XCTAssertEqual(frame.encoded(), expected)
        XCTAssertEqual(try FileClipboardWire.decodeOffer(frame.payload), offer)
    }

    func testChunkAndAckGoldenPayloads() throws {
        let chunk = FileClipboardChunk(
            transferID: transferID,
            entryIndex: 1,
            offset: 0,
            data: Data([0x41, 0x42])
        )
        let ack = FileClipboardAck(
            transferID: transferID,
            entryIndex: 1,
            nextOffset: 2
        )

        XCTAssertEqual(
            FileClipboardWire.encodeChunk(chunk),
            Data(hexadecimal: "000102030405060708090A0B0C0D0E0F0000000100000000000000004142")
        )
        XCTAssertEqual(
            FileClipboardWire.encodeAck(ack),
            Data(hexadecimal: "000102030405060708090A0B0C0D0E0F000000010000000000000002")
        )
        XCTAssertEqual(try FileClipboardWire.decodeChunk(FileClipboardWire.encodeChunk(chunk)), chunk)
        XCTAssertEqual(try FileClipboardWire.decodeAck(FileClipboardWire.encodeAck(ack)), ack)
    }

    func testFileMessageKindsAndControlPayloadsMatchFrozenProtocol() throws {
        XCTAssertEqual(
            [ClipboardMessageKind.fileOffer, .fileAccept, .fileChunk, .fileComplete,
             .fileResult, .fileCancel, .fileAck].map(\.rawValue),
            [18, 19, 20, 21, 22, 23, 24]
        )
        let idBytes = try XCTUnwrap(Data(hexadecimal: "000102030405060708090A0B0C0D0E0F"))
        var successBytes = idBytes
        successBytes.append(FileClipboardResultStatus.success.rawValue)
        var timeoutBytes = idBytes
        timeoutBytes.append(FileClipboardCancelReason.timeout.rawValue)
        XCTAssertEqual(FileClipboardWire.encodeTransferID(transferID), idBytes)
        XCTAssertEqual(
            FileClipboardWire.encodeStatus(transferID, status: FileClipboardResultStatus.success.rawValue),
            successBytes
        )
        XCTAssertEqual(
            FileClipboardWire.encodeStatus(transferID, status: FileClipboardCancelReason.timeout.rawValue),
            timeoutBytes
        )
    }

    func testHelloCapabilityFiveGoldenTLV() {
        let payload = CompanionHello(
            name: "",
            capabilities: [.textClipboard, .pngClipboard, .fileClipboard],
            driverABI: nil,
            screenWidth: nil,
            screenHeight: nil
        ).encoded()

        XCTAssertEqual(
            [UInt8](payload),
            [1, 0, 0, 2, 0, 6, 0, 1, 0, 2, 0, 5]
        )
    }

    func testOfferRejectsInvalidParentAndSizeSum() {
        let valid = FileClipboardOffer(
            transferID: transferID,
            entries: [
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: nil,
                    name: "a",
                    size: 1,
                    modifiedMillis: .min
                ),
            ],
            totalFileBytes: 1
        )
        var badParent = FileClipboardWire.encodeOffer(valid)
        badParent.replaceSubrange(30..<34, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try FileClipboardWire.decodeOffer(badParent))

        var badSum = FileClipboardWire.encodeOffer(valid)
        badSum.replaceSubrange(20..<28, with: repeatElement(0, count: 8))
        XCTAssertThrowsError(try FileClipboardWire.decodeOffer(badSum))
    }

    func testFixedFileTransferBudgetsAndBoundaryOffers() throws {
        XCTAssertEqual(FileClipboardWire.maximumEntryCount, 20_000)
        XCTAssertEqual(FileClipboardWire.maximumRootCount, 128)
        XCTAssertEqual(FileClipboardWire.maximumDepth, 64)
        XCTAssertEqual(FileClipboardWire.maximumLogicalBytes, 50 * 1_024 * 1_024 * 1_024)

        let maximumOffer = FileClipboardOffer(
            transferID: transferID,
            entries: [
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: nil,
                    name: "a",
                    size: FileClipboardWire.maximumLogicalBytes,
                    modifiedMillis: .min
                ),
            ],
            totalFileBytes: FileClipboardWire.maximumLogicalBytes
        )
        XCTAssertEqual(
            try FileClipboardWire.decodeOffer(FileClipboardWire.encodeOffer(maximumOffer)),
            maximumOffer
        )

        var tooManyEntries = FileClipboardWire.encodeOffer(maximumOffer)
        tooManyEntries.replaceSubrange(
            16..<20,
            with: bigEndianBytes(UInt32(FileClipboardWire.maximumEntryCount + 1))
        )
        XCTAssertThrowsError(try FileClipboardWire.decodeOffer(tooManyEntries))

        let tooManyRoots = FileClipboardOffer(
            transferID: transferID,
            entries: (0...FileClipboardWire.maximumRootCount).map { index in
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: nil,
                    name: "\(index)",
                    size: 0,
                    modifiedMillis: .min
                )
            },
            totalFileBytes: 0
        )
        XCTAssertThrowsError(
            try FileClipboardWire.decodeOffer(FileClipboardWire.encodeOffer(tooManyRoots))
        )

        let tooDeep = FileClipboardOffer(
            transferID: transferID,
            entries: (0...FileClipboardWire.maximumDepth).map { index in
                FileClipboardEntry(
                    kind: .directory,
                    flags: 0,
                    parentIndex: index == 0 ? nil : UInt32(index - 1),
                    name: "d\(index)",
                    size: 0,
                    modifiedMillis: .min
                )
            },
            totalFileBytes: 0
        )
        XCTAssertThrowsError(
            try FileClipboardWire.decodeOffer(FileClipboardWire.encodeOffer(tooDeep))
        )

        var overLogicalBudget = FileClipboardWire.encodeOffer(maximumOffer)
        let over = FileClipboardWire.maximumLogicalBytes + 1
        overLogicalBudget.replaceSubrange(20..<28, with: bigEndianBytes(over))
        overLogicalBudget.replaceSubrange(37..<45, with: bigEndianBytes(over))
        XCTAssertThrowsError(try FileClipboardWire.decodeOffer(overLogicalBudget))
    }

    func testBackslashIsValidButPathSeparatorsAndDotNamesAreNot() {
        XCTAssertTrue(FileClipboardWire.isValidName("a\\b"))
        XCTAssertTrue(FileClipboardWire.isValidName("a:b"))
        XCTAssertFalse(FileClipboardWire.isValidName("a/b"))
        XCTAssertFalse(FileClipboardWire.isValidName("."))
        XCTAssertFalse(FileClipboardWire.isValidName(".."))
        XCTAssertFalse(FileClipboardWire.isValidName("a\0b"))
    }

    func testDestinationMappingHandlesNormalizationAndCaseCollisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let offer = FileClipboardOffer(
            transferID: transferID,
            entries: [
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: nil,
                    name: "é.txt",
                    size: 0,
                    modifiedMillis: .min
                ),
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: nil,
                    name: "e\u{301}.TXT",
                    size: 0,
                    modifiedMillis: .min
                ),
            ],
            totalFileBytes: 0
        )

        let layout = try FileClipboardDestinationMapper.makeLayout(for: offer, rootURL: root)

        XCTAssertEqual(layout.topLevelURLs.map(\.lastPathComponent), ["é.txt", "e\u{301} (2).TXT"])
    }

    func testDestinationMappingContinuesSuffixesWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let offer = FileClipboardOffer(
            transferID: transferID,
            entries: [FileClipboardEntry(
                kind: .directory,
                flags: 0,
                parentIndex: nil,
                name: "folder",
                size: 0,
                modifiedMillis: .min
            )] + (0..<(FileClipboardWire.maximumEntryCount - 1)).map { _ in
                FileClipboardEntry(
                    kind: .regularFile,
                    flags: 0,
                    parentIndex: 0,
                    name: "a.txt",
                    size: 0,
                    modifiedMillis: .min
                )
            },
            totalFileBytes: 0
        )

        let names = try FileClipboardDestinationMapper.makeLayout(for: offer, rootURL: root)
            .itemURLs.dropFirst().map(\.lastPathComponent)

        XCTAssertEqual(Set(names).count, FileClipboardWire.maximumEntryCount - 1)
        XCTAssertEqual(names.first, "a.txt")
        XCTAssertEqual(names.last, "a (19999).txt")
    }

    func testManifestPreservesRootOrderAndSortsOnlyChildren() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        let childB = directory.appendingPathComponent("b.txt")
        let childA = directory.appendingPathComponent("a.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: first.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: childB.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: childA.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try FileClipboardManifestBuilder.build(
            from: [first, directory],
            transferID: transferID
        )

        XCTAssertEqual(manifest.offer.entries.map(\.name), ["first.txt", "folder", "a.txt", "b.txt"])
        XCTAssertEqual(manifest.offer.entries.map(\.parentIndex), [nil, nil, 1, 1])
    }

    func testManifestDetectsRecordedDirectoryChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let recordedModificationDate = Date(timeIntervalSince1970: 2_000)
        try FileManager.default.setAttributes(
            [.modificationDate: recordedModificationDate],
            ofItemAtPath: directory.path
        )
        let manifest = try FileClipboardManifestBuilder.build(
            from: [directory],
            transferID: transferID
        )
        let sourceURL = manifest.sourceURLs[0]
        let entry = manifest.offer.entries[0]
        XCTAssertTrue(FileClipboardManifestBuilder.sourceStillMatches(sourceURL, entry: entry))

        let child = directory.appendingPathComponent("new.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: child.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: directory.path
        )
        XCTAssertFalse(FileClipboardManifestBuilder.sourceStillMatches(sourceURL, entry: entry))
        try FileManager.default.removeItem(at: child)
        try FileManager.default.setAttributes(
            [.modificationDate: recordedModificationDate],
            ofItemAtPath: directory.path
        )
        XCTAssertTrue(FileClipboardManifestBuilder.sourceStillMatches(sourceURL, entry: entry))

        try FileManager.default.removeItem(at: directory)

        XCTAssertFalse(FileClipboardManifestBuilder.sourceStillMatches(sourceURL, entry: entry))
    }
}

private func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
}

private extension Data {
    init?(hexadecimal: String) {
        let cleaned = hexadecimal.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
