enum PhilipsInput: UInt8, Sendable {
  case displayPort = 0x0F
  case hdmi2 = 0x12

  var title: String {
    switch self {
    case .displayPort: "DisplayPort"
    case .hdmi2: "HDMI 2"
    }
  }
}

enum PhilipsInputPacket {
  static let dataAddress: UInt32 = 0x51
  private static let inputFeature: UInt8 = 0x60

  static func request(_ input: PhilipsInput? = nil) -> [UInt8] {
    let message: [UInt8] = if let input {
      [0x84, 0x03, inputFeature, 0x00, input.rawValue]
    } else {
      [0x82, 0x01, inputFeature]
    }
    return message + [message.reduce(0x6E ^ UInt8(dataAddress), ^)]
  }

  static func readback(_ reply: [UInt8]) -> UInt8? {
    guard reply.count >= 11,
      reply[0] == 0x6E, reply[1] == 0x88,
      reply[2] == 0x02, reply[3] == 0x00, reply[4] == inputFeature,
      reply.prefix(11).reduce(0x50, ^) == 0
    else {
      return nil
    }
    // Philips returns additional information in the high byte.
    return reply[9]
  }
}
