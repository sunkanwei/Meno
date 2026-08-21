import Foundation
import XCTest

final class WakeOnLANTests: XCTestCase {
    func testConfiguredWindowsTargetUsesConfirmedEthernetMACAddress() throws {
        let target = try XCTUnwrap(WakeOnLANTarget(macAddress: "A0-AD-9F-B5-A4-57"))

        XCTAssertEqual(target, .windows)
        XCTAssertEqual(WakeOnLANTarget(macAddress: "A0:AD:9F:B5:A4:57"), .windows)
    }

    func testMagicPacketHasStandardPrefixAndSixteenMACCopies() {
        let packet = WakeOnLANTarget.windows.magicPacket

        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual([UInt8](packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        for copy in 0..<16 {
            let offset = 6 + copy * 6
            XCTAssertEqual(
                [UInt8](packet[offset..<(offset + 6)]),
                [0xA0, 0xAD, 0x9F, 0xB5, 0xA4, 0x57]
            )
        }
    }

    func testTargetRejectsInvalidAndMulticastAddresses() {
        XCTAssertNil(WakeOnLANTarget(macAddress: "A0-AD-9F-B5-A4"))
        XCTAssertNil(WakeOnLANTarget(macAddress: "A-AD-9F-B5-A4-57"))
        XCTAssertNil(WakeOnLANTarget(macAddress: "A0--AD-9F-B5-A4-57"))
        XCTAssertNil(WakeOnLANTarget(macAddress: "00-00-00-00-00-00"))
        XCTAssertNil(WakeOnLANTarget(macAddress: "01-00-5E-00-00-01"))
    }
}
