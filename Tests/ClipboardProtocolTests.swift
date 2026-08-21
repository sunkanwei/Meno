import Foundation
import XCTest

final class ClipboardProtocolTests: XCTestCase {
    func testFrameEncodingMatchesWireFormat() {
        let frame = ClipboardFrame(
            kind: .text,
            messageID: 0x0102_0304_0506_0708,
            payload: Data([0x41, 0x42])
        )

        XCTAssertEqual(
            [UInt8](frame.encoded()),
            [
                0x4D, 0x45, 0x4E, 0x4F,
                0x03, 0x00, 0x00, 0x00,
                0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                0x00, 0x00, 0x00, 0x02,
                0x41, 0x42,
            ]
        )
    }

    func testRemoteShutdownIdentifiersAndFrameBytesAreStable() {
        XCTAssertEqual(CompanionCapability.remoteShutdown.rawValue, 6)
        XCTAssertEqual(ClipboardMessageKind.shutdownRequest.rawValue, 25)

        let frame = ClipboardFrame(
            kind: .shutdownRequest,
            messageID: 0x0102_0304_0506_0708,
            payload: Data()
        )

        XCTAssertEqual(
            [UInt8](frame.encoded()),
            [
                0x4D, 0x45, 0x4E, 0x4F,
                0x19, 0, 0, 0,
                1, 2, 3, 4, 5, 6, 7, 8,
                0, 0, 0, 0,
            ]
        )
    }

    func testMicrophoneIdentifiersAndFirstFrameHeaderAreStable() {
        XCTAssertEqual(CompanionCapability.macMicrophone.rawValue, 8)
        XCTAssertEqual(ClipboardMessageKind.microphonePCM.rawValue, 28)

        let frame = ClipboardFrame(
            kind: .microphonePCM,
            messageID: 1,
            payload: Data(repeating: 0, count: 1_920)
        )

        XCTAssertEqual(
            [UInt8](frame.encoded().prefix(20)),
            [
                0x4D, 0x45, 0x4E, 0x4F,
                0x1C, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 1,
                0, 0, 0x07, 0x80,
            ]
        )
    }

    func testDecoderHandlesSplitAndConsecutiveFrames() throws {
        let first = ClipboardFrame(kind: .ping, messageID: 1, payload: Data()).encoded()
        let second = ClipboardFrame(
            kind: .text,
            messageID: 2,
            payload: Data("你好".utf8)
        ).encoded()
        let combined = first + second
        var decoder = ClipboardFrameDecoder()

        XCTAssertTrue(try decoder.append(combined.prefix(7)).isEmpty)
        let frames = try decoder.append(combined.dropFirst(7))

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].kind, .ping)
        XCTAssertEqual(frames[0].messageID, 1)
        XCTAssertTrue(frames[0].payload.isEmpty)
        XCTAssertEqual(frames[1].kind, .text)
        XCTAssertEqual(frames[1].messageID, 2)
        XCTAssertEqual(String(data: frames[1].payload, encoding: .utf8), "你好")
    }

    func testDecoderRejectsInvalidReservedHeaderBytes() {
        var bytes = [UInt8](
            ClipboardFrame(kind: .ping, messageID: 1, payload: Data()).encoded()
        )
        bytes[6] = 1
        var decoder = ClipboardFrameDecoder()

        XCTAssertThrowsError(try decoder.append(Data(bytes))) { error in
            guard case ClipboardFrameDecoderError.invalidHeader = error else {
                return XCTFail("Expected invalidHeader, got \(error)")
            }
        }
    }

    func testDecoderRejectsOversizedPayloadBeforeReadingBody() {
        var header = Data(ClipboardWire.magic)
        header.append(ClipboardMessageKind.png.rawValue)
        header.append(contentsOf: [0, 0, 0])
        header.append(contentsOf: repeatElement(0, count: 8))
        let oversized = UInt32(ClipboardWire.maximumPayloadSize + 1)
        header.append(UInt8((oversized >> 24) & 0xFF))
        header.append(UInt8((oversized >> 16) & 0xFF))
        header.append(UInt8((oversized >> 8) & 0xFF))
        header.append(UInt8(oversized & 0xFF))
        var decoder = ClipboardFrameDecoder()

        XCTAssertThrowsError(try decoder.append(header)) { error in
            guard case ClipboardFrameDecoderError.payloadTooLarge = error else {
                return XCTFail("Expected payloadTooLarge, got \(error)")
            }
        }
    }

    func testDiscoveryPacketAndNameTruncation() {
        XCTAssertTrue(
            ClipboardWire.isDiscoverPacket(
                ClipboardWire.discoveryPacket(type: 1)
            )
        )
        XCTAssertFalse(
            ClipboardWire.isDiscoverPacket(
                ClipboardWire.discoveryPacket(type: 2, clipboardPort: 45_891, mousePort: 45_892)
            )
        )

        let payload = ClipboardWire.utf8Payload("ab😀中", maximumSize: 7)
        XCTAssertEqual(payload.count, 6)
        XCTAssertEqual(String(data: payload, encoding: .utf8), "ab😀")
    }

    func testDecoderIgnoresUnknownMessageKinds() throws {
        var unknown = Data(ClipboardWire.magic)
        unknown.append(contentsOf: [0xFE, 0, 0, 0])
        unknown.append(contentsOf: repeatElement(0, count: 8))
        unknown.append(contentsOf: [0, 0, 0, 2, 0xAA, 0xBB])
        let known = ClipboardFrame(
            kind: .ping,
            messageID: 2,
            payload: Data()
        ).encoded()
        var decoder = ClipboardFrameDecoder()

        let frames = try decoder.append(unknown + known)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].kind, .ping)
        XCTAssertEqual(frames[0].messageID, 2)
    }

    func testHelloRoundTripIgnoresUnknownFields() throws {
        let hello = CompanionHello(
            name: "Windows",
            capabilities: [.textClipboard, .pngClipboard, .mouseControl],
            driverABI: 4,
            screenWidth: 3_840,
            screenHeight: 2_160
        )
        var payload = hello.encoded()
        payload.append(contentsOf: [99, 0, 1, 0xFF])

        let decoded = try XCTUnwrap(CompanionHello.decode(payload))

        XCTAssertEqual(decoded, hello)
    }

    func testHelloIgnoresUnknownCapabilitiesAndRejectsMalformedKnownFields() throws {
        let payload = Data([
            1, 0, 0,
            2, 0, 4, 0, 3, 0xFF, 0xFF,
            3, 0, 2, 0, 4,
            4, 0, 4, 0, 0, 0x0F, 0,
            5, 0, 4, 0, 0, 0x08, 0x70,
        ])
        let decoded = try XCTUnwrap(CompanionHello.decode(payload))
        XCTAssertEqual(decoded.capabilities, [.mouseControl])

        var duplicateName = payload
        duplicateName.append(contentsOf: [1, 0, 0])
        XCTAssertNil(CompanionHello.decode(duplicateName))

        var truncatedUnknownField = payload
        truncatedUnknownField.append(contentsOf: [99, 0, 2, 0xFF])
        XCTAssertNil(CompanionHello.decode(truncatedUnknownField))
    }

    func testHelloGoldenBytesAreStable() {
        let payload = CompanionHello(
            name: "Win",
            capabilities: [.mouseControl, .keyboardState],
            driverABI: 4,
            screenWidth: 3_840,
            screenHeight: 2_160
        ).encoded()

        XCTAssertEqual(
            [UInt8](payload),
            [
                1, 0, 3, 0x57, 0x69, 0x6E,
                2, 0, 4, 0, 3, 0, 4,
                3, 0, 2, 0, 4,
                4, 0, 4, 0, 0, 0x0F, 0,
                5, 0, 4, 0, 0, 0x08, 0x70,
            ]
        )
    }

    func testAudioPortFieldIsBigEndianAndStrictlyValidated() throws {
        let payload = CompanionHello(
            name: "Mac",
            capabilities: [.macMicrophone],
            driverABI: nil,
            screenWidth: nil,
            screenHeight: nil,
            audioPort: 0xBEEF
        ).encoded()
        XCTAssertEqual([UInt8](payload.suffix(5)), [6, 0, 2, 0xBE, 0xEF])
        XCTAssertEqual(try XCTUnwrap(CompanionHello.decode(payload)).audioPort, 0xBEEF)

        var duplicate = payload
        duplicate.append(contentsOf: [6, 0, 2, 0x12, 0x34])
        XCTAssertNil(CompanionHello.decode(duplicate))

        var zero = payload.dropLast(2)
        zero.append(contentsOf: [0, 0])
        XCTAssertNil(CompanionHello.decode(Data(zero)))

        var wrongLength = payload.dropLast(5)
        wrongLength.append(contentsOf: [6, 0, 1, 1])
        XCTAssertNil(CompanionHello.decode(Data(wrongLength)))
    }

    func testRemoteShutdownHelloCapabilityBytesAreStable() {
        let payload = CompanionHello(
            name: "Win",
            capabilities: [.mouseControl, .remoteShutdown],
            driverABI: 4,
            screenWidth: 3_840,
            screenHeight: 2_160
        ).encoded()

        XCTAssertEqual(
            [UInt8](payload),
            [
                1, 0, 3, 0x57, 0x69, 0x6E,
                2, 0, 4, 0, 3, 0, 6,
                3, 0, 2, 0, 4,
                4, 0, 4, 0, 0, 0x0F, 0,
                5, 0, 4, 0, 0, 0x08, 0x70,
            ]
        )
    }

    func testWindowsOnlineIdentifiersAndEmptyFrameBytesAreStable() {
        XCTAssertEqual(CompanionCapability.windowsOnline.rawValue, 10)
        XCTAssertEqual(ClipboardMessageKind.windowsOnline.rawValue, 30)

        let hello = CompanionHello(
            name: "Mac",
            capabilities: [.windowsOnline],
            driverABI: nil,
            screenWidth: nil,
            screenHeight: nil
        )
        XCTAssertEqual(
            [UInt8](hello.encoded()),
            [
                1, 0, 3, 0x4D, 0x61, 0x63,
                2, 0, 2, 0, 10,
            ]
        )

        let frame = ClipboardFrame(
            kind: .windowsOnline,
            messageID: 0x0102_0304_0506_0708,
            payload: Data()
        )

        XCTAssertEqual(
            [UInt8](frame.encoded()),
            [
                0x4D, 0x45, 0x4E, 0x4F,
                0x1E, 0, 0, 0,
                1, 2, 3, 4, 5, 6, 7, 8,
                0, 0, 0, 0,
            ]
        )
    }

    func testWindowsOnlineRequiresNegotiationEmptyPayloadAndDeliversOnlyOnce() {
        var gate = WindowsOnlineDeliveryGate()
        let windowsOnline: Set<CompanionCapability> = [.windowsOnline]

        XCTAssertEqual(
            gate.receive(
                isReady: false,
                isSendingReady: false,
                negotiatedCapabilities: windowsOnline,
                payload: Data()
            ),
            .reject
        )
        XCTAssertEqual(
            gate.receive(
                isReady: false,
                isSendingReady: true,
                negotiatedCapabilities: [.textClipboard],
                payload: Data()
            ),
            .reject
        )
        XCTAssertEqual(
            gate.receive(
                isReady: false,
                isSendingReady: true,
                negotiatedCapabilities: windowsOnline,
                payload: Data([0])
            ),
            .reject
        )
        XCTAssertEqual(
            gate.receive(
                isReady: false,
                isSendingReady: true,
                negotiatedCapabilities: windowsOnline,
                payload: Data()
            ),
            .waitForReadyWrite
        )
        XCTAssertTrue(gate.readyFrameWasSent())
        XCTAssertFalse(gate.readyFrameWasSent())

        var readyGate = WindowsOnlineDeliveryGate()
        XCTAssertEqual(
            readyGate.receive(
                isReady: true,
                isSendingReady: false,
                negotiatedCapabilities: windowsOnline,
                payload: Data()
            ),
            .notifyNow
        )
        XCTAssertEqual(
            readyGate.receive(
                isReady: true,
                isSendingReady: false,
                negotiatedCapabilities: windowsOnline,
                payload: Data()
            ),
            .reject
        )
    }

    func testDiscoveryUsesFixedRequestAndResponseLayouts() {
        let request = ClipboardWire.discoveryPacket(type: 1)
        let response = ClipboardWire.discoveryPacket(
            type: 2,
            clipboardPort: 0x1234,
            mousePort: 0xABCD
        )

        XCTAssertEqual(
            [UInt8](request),
            [0x4D, 0x45, 0x4E, 0x4F, 1, 0, 0, 0, 0, 0]
        )
        XCTAssertEqual(
            [UInt8](response),
            [0x4D, 0x45, 0x4E, 0x4F, 2, 0, 0x12, 0x34, 0xAB, 0xCD]
        )
        XCTAssertTrue(ClipboardWire.isDiscoverPacket(request))
        XCTAssertFalse(ClipboardWire.isDiscoverPacket(response))
    }
}
