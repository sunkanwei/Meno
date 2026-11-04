import XCTest

final class PhilipsInputPacketTests: XCTestCase {
    private let hdmi2Reply: [UInt8] = [0x6E, 0x88, 0x02, 0, 0x60, 0, 0x20, 0x0E, 0x22, 0x12, 0xCA]

    func testRequestsMatchDDCFrames() {
        XCTAssertEqual(PhilipsInputPacket.request(), [0x82, 0x01, 0x60, 0xDC])
        XCTAssertEqual(PhilipsInputPacket.request(.displayPort), [0x84, 0x03, 0x60, 0, 0x0F, 0xD7])
        XCTAssertEqual(PhilipsInputPacket.request(.hdmi2), [0x84, 0x03, 0x60, 0, 0x12, 0xCA])
    }

    func testReadbackUsesLowByteAndAcceptsAnUnlistedCurrentInput() {
        let dpReply: [UInt8] = [0x6E, 0x88, 0x02, 0, 0x60, 0, 0x20, 0x0E, 0x2F, 0x0F, 0xDA]
        let hdmi1Reply: [UInt8] = [0x6E, 0x88, 0x02, 0, 0x60, 0, 0x20, 0x0E, 0x22, 0x11, 0xC9]
        XCTAssertEqual(PhilipsInputPacket.readback(hdmi2Reply + [0]), PhilipsInput.hdmi2.rawValue)
        XCTAssertEqual(PhilipsInputPacket.readback(dpReply), PhilipsInput.displayPort.rawValue)
        XCTAssertEqual(PhilipsInputPacket.readback(hdmi1Reply), 0x11)
    }

    func testRejectsTruncatedCorruptOrUnrelatedReplies() {
        XCTAssertNil(PhilipsInputPacket.readback(Array(hdmi2Reply.dropLast())))
        var corrupt = hdmi2Reply
        corrupt[10] ^= 1
        XCTAssertNil(PhilipsInputPacket.readback(corrupt))

        var wrongFeature = hdmi2Reply
        wrongFeature[4] ^= 1
        wrongFeature[10] ^= 1
        XCTAssertNil(PhilipsInputPacket.readback(wrongFeature))

        var rejected = hdmi2Reply
        rejected[3] = 1
        rejected[10] ^= 1
        XCTAssertNil(PhilipsInputPacket.readback(rejected))
    }
}
