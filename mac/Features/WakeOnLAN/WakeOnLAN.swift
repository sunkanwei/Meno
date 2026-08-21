import Darwin
import Foundation

struct WakeOnLANTarget: Equatable, Sendable {
    let macAddress: [UInt8]

    init?(macAddress: String) {
        let octets = macAddress.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == ":" || $0 == "-" }
        )
        guard octets.count == 6,
              octets.allSatisfy({ $0.count == 2 }) else {
            return nil
        }

        let bytes = octets.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6,
              !bytes.allSatisfy({ $0 == 0 }),
              bytes[0] & 1 == 0 else {
            return nil
        }
        self.macAddress = bytes
    }

    var magicPacket: Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macAddress)
        }
        return packet
    }

    static let windows = WakeOnLANTarget(macAddress: "A0-AD-9F-B5-A4-57")!
}

enum WakeOnLANError: LocalizedError {
    case socketUnavailable(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case let .socketUnavailable(message):
            "无法创建局域网开机连接：\(message)"
        case let .sendFailed(message):
            "无法把开机请求发送到局域网：\(message)"
        }
    }
}

enum WakeOnLANSender {
    private static let defaultPort: UInt16 = 9
    private static let sendCount = 3

    static func sendMagicPacket(to target: WakeOnLANTarget) throws {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            throw WakeOnLANError.socketUnavailable(currentErrnoDescription())
        }
        defer { _ = close(socketFD) }

        var broadcastEnabled: Int32 = 1
        guard setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_BROADCAST,
            &broadcastEnabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw WakeOnLANError.socketUnavailable(currentErrnoDescription())
        }

        let packet = target.magicPacket
        let destinations = broadcastDestinations()
        var sentAtLeastOnce = false
        var lastFailure: String?

        for _ in 0..<sendCount {
            for destination in destinations {
                do {
                    try send(packet, socketFD: socketFD, destination: destination)
                    sentAtLeastOnce = true
                } catch {
                    lastFailure = error.localizedDescription
                }
            }
        }

        guard sentAtLeastOnce else {
            throw WakeOnLANError.sendFailed(lastFailure ?? "没有可用的局域网接口。")
        }
    }

    private static func send(
        _ packet: Data,
        socketFD: Int32,
        destination: in_addr_t
    ) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = defaultPort.bigEndian
        address.sin_addr = in_addr(s_addr: destination)

        let sent = packet.withUnsafeBytes { packetBytes in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        socketFD,
                        packetBytes.baseAddress,
                        packet.count,
                        0,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        if sent == packet.count {
            return
        }
        if sent >= 0 {
            throw WakeOnLANError.sendFailed("魔术封包未完整发送。")
        }
        throw WakeOnLANError.sendFailed(currentErrnoDescription())
    }

    private static func broadcastDestinations() -> [in_addr_t] {
        var destinations: Set<in_addr_t> = [in_addr_t(INADDR_BROADCAST)]
        var firstInterface: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstInterface) == 0, let firstInterface else {
            return Array(destinations)
        }
        defer { freeifaddrs(firstInterface) }

        var interface: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = interface {
            interface = current.pointee.ifa_next
            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_BROADCAST) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  let netmask = current.pointee.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }

            let ipv4Address = UnsafeRawPointer(address)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
            let ipv4Netmask = UnsafeRawPointer(netmask)
                .assumingMemoryBound(to: sockaddr_in.self)
                .pointee
            destinations.insert(ipv4Address.sin_addr.s_addr | ~ipv4Netmask.sin_addr.s_addr)
        }
        return Array(destinations)
    }

    private static func currentErrnoDescription() -> String {
        String(cString: strerror(errno))
    }
}
