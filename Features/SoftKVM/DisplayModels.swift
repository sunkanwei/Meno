import Foundation

enum DisplayRole: String, Codable, Sendable {
  case builtIn = "built-in"
  case viewSonic = "viewsonic"
  case philips = "philips"
  case unknown
}

enum DisplayTopologyState: String, Codable, Sendable {
  case mac
  case windows
  case unknown
}

enum HorizontalDisplaySide: UInt8, Codable, Equatable, Sendable {
  case left = 1
  case right = 2

  var opposite: HorizontalDisplaySide {
    self == .left ? .right : .left
  }
}

struct DisplayModeRecord: Codable, Sendable {
  let logicalWidth: Int
  let logicalHeight: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let refreshRate: Double
  let isHiDPI: Bool
}

enum FixedDisplayConfiguration {
  static let viewSonicUUID = "7882AFEB-C803-4364-AE43-36A5FD466A6A"
  static let viewSonicEDIDUUID = "5A633BAE-0000-0000-2521-0104B53D2378"
  static let viewSonicVendorID: UInt32 = 23_139
  static let viewSonicModelID: UInt32 = 44_603
  static let viewSonicSerialNumber: UInt32 = 16_843_031
  static let viewSonicActiveHeightMM: CGFloat = 335.664

  static let philipsUUID = "45385DB6-3299-4343-A086-2392289D621A"
  static let philipsEDIDUUID = "410C6FC2-0000-0000-1420-0103803C2278"
  static let philipsVendorID: UInt32 = 16_652
  static let philipsModelID: UInt32 = 49_775
  static let philipsSerialNumber: UInt32 = 85
  static let philipsActiveHeightMM: CGFloat = 335.664

  static func activeHeightMM(vendorID: UInt32, modelID: UInt32) -> CGFloat? {
    switch (vendorID, modelID) {
    case (viewSonicVendorID, viewSonicModelID): viewSonicActiveHeightMM
    case (philipsVendorID, philipsModelID): philipsActiveHeightMM
    default: nil
    }
  }

  static func isProtectedViewSonicMode(_ mode: DisplayModeRecord?) -> Bool {
    guard let mode else {
      return false
    }
    return mode.logicalWidth == 2048
      && mode.logicalHeight == 1152
      && mode.pixelWidth == 4096
      && mode.pixelHeight == 2304
      && mode.isHiDPI
      && (59.0...61.0).contains(mode.refreshRate)
  }
}

struct DisplayRecord: Codable, Sendable {
  let role: DisplayRole
  let runtimeID: UInt32
  let uuid: String?
  let vendorID: UInt32
  let modelID: UInt32
  let serialNumber: UInt32
  let isBuiltIn: Bool
  let isActive: Bool
  let isMain: Bool
  let originX: Int
  let originY: Int
  let width: Int
  let height: Int
  let edidUUID: String?
  let mode: DisplayModeRecord?
}

struct CheckRecord: Sendable {
  let name: String
  let passed: Bool
}

struct ProbeReport: Sendable {
  let passed: Bool
  let topology: DisplayTopologyState
  let displays: [DisplayRecord]
  let checks: [CheckRecord]
}

struct SoftDisconnectState: Codable, Sendable {
  let schemaVersion: Int
  let createdAt: String
  let philips: DisplayRecord
  let topologyPlan: SoftKVMTopologyPlan?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case createdAt
    case philips
    case topologyPlan
    case philipsSide
  }

  init(
    schemaVersion: Int,
    createdAt: String,
    philips: DisplayRecord,
    topologyPlan: SoftKVMTopologyPlan? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.philips = philips
    self.topologyPlan = topologyPlan
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    philips = try container.decode(DisplayRecord.self, forKey: .philips)
    topologyPlan = try container.decodeIfPresent(
      SoftKVMTopologyPlan.self,
      forKey: .topologyPlan
    ) ?? container.decodeIfPresent(HorizontalDisplaySide.self, forKey: .philipsSide).map {
      SoftKVMTopologyPlan(sharedDisplaySide: $0)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(philips, forKey: .philips)
    try container.encodeIfPresent(topologyPlan, forKey: .topologyPlan)
  }

  func withTopologyPlan(_ topologyPlan: SoftKVMTopologyPlan) -> SoftDisconnectState {
    SoftDisconnectState(
      schemaVersion: schemaVersion,
      createdAt: createdAt,
      philips: philips,
      topologyPlan: topologyPlan
    )
  }
}
