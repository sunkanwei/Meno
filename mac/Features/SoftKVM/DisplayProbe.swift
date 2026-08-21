import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics

typealias GetDisplayListFunction =
  @convention(c) (
    UInt32,
    UnsafeMutablePointer<CGDirectDisplayID>?,
    UnsafeMutablePointer<UInt32>?
  ) -> CGError

typealias CreateDisplayInfoFunction =
  @convention(c) (
    CGDirectDisplayID
  ) -> Unmanaged<CFDictionary>?

typealias ConfigureDisplayEnabledFunction =
  @convention(c) (
    CGDisplayConfigRef?,
    CGDirectDisplayID,
    Bool
  ) -> CGError

final class PrivateDisplaySymbols {
  private static let frameworkPaths: [String?] = [
    nil,
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
  ]

  private let handles: [UnsafeMutableRawPointer]
  private let symbols: [String: UnsafeMutableRawPointer]

  init() {
    handles = Self.frameworkPaths.compactMap { path in
      dlopen(path, RTLD_LAZY | RTLD_LOCAL)
    }

    var resolved: [String: UnsafeMutableRawPointer] = [:]
    for name in [
      "CGSConfigureDisplayEnabled",
      "SLSConfigureDisplayEnabled",
      "CGSGetDisplayList",
      "SLSGetDisplayList",
      "CoreDisplay_DisplayCreateInfoDictionary"
    ] {
      if let address = handles.lazy.compactMap({ dlsym($0, name) }).first {
        resolved[name] = address
      }
    }
    symbols = resolved
  }

  deinit {
    for entry in handles {
      dlclose(entry)
    }
  }

  func firstAllDisplayListFunction() -> (name: String, function: GetDisplayListFunction)? {
    for name in ["CGSGetDisplayList", "SLSGetDisplayList"] {
      guard let address = symbols[name] else {
        continue
      }
      return (name, unsafeBitCast(address, to: GetDisplayListFunction.self))
    }
    return nil
  }

  func createDisplayInfoFunction() -> CreateDisplayInfoFunction? {
    guard let address = symbols["CoreDisplay_DisplayCreateInfoDictionary"] else {
      return nil
    }
    return unsafeBitCast(address, to: CreateDisplayInfoFunction.self)
  }

  func firstConfigureFunction() -> (name: String, function: ConfigureDisplayEnabledFunction)? {
    for name in ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] {
      guard let address = symbols[name] else {
        continue
      }
      return (name, unsafeBitCast(address, to: ConfigureDisplayEnabledFunction.self))
    }
    return nil
  }
}

private struct AllDisplayResult {
  let ids: [CGDirectDisplayID]
  let source: String
  let error: String?
}

@MainActor
final class DisplayProbe {
  private let privateSymbols = PrivateDisplaySymbols()

  func run() -> ProbeReport {
    let onlineIDs = onlineDisplayIDs()
    let onlineIDSet = Set(onlineIDs)
    let allResult = allDisplayIDs(fallback: onlineIDs)

    let displayIDs = allResult.ids.filter { id in
      let isPlaceholder =
        CGDisplayVendorNumber(id) == 0
        && CGDisplayPixelsWide(id) <= 1
        && CGDisplayPixelsHigh(id) <= 1
        && !onlineIDSet.contains(id)
      if isPlaceholder {
        return false
      }
      return true
    }

    let displays =
      displayIDs
      .map { makeDisplayRecord(id: $0) }
      .sorted { lhs, rhs in
        if lhs.role != rhs.role {
          return roleOrder(lhs.role) < roleOrder(rhs.role)
        }
        return lhs.runtimeID < rhs.runtimeID
      }

    let checks = makeChecks(
      displays: displays,
      configureAvailable: privateSymbols.firstConfigureFunction() != nil,
      metadataAvailable: privateSymbols.createDisplayInfoFunction() != nil,
      allListSource: allResult.source,
      allListError: allResult.error
    )

    return ProbeReport(
      passed: checks.allSatisfy(\.passed),
      topology: topologyState(displays),
      displays: displays,
      checks: checks
    )
  }

  private func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
      return []
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
      return []
    }
    return Array(ids.prefix(Int(count)))
  }

  private func allDisplayIDs(fallback: [CGDirectDisplayID]) -> AllDisplayResult {
    guard let resolved = privateSymbols.firstAllDisplayListFunction() else {
      return AllDisplayResult(
        ids: fallback,
        source: "CGGetOnlineDisplayList fallback",
        error: "CGSGetDisplayList and SLSGetDisplayList are unavailable"
      )
    }

    var ids = [CGDirectDisplayID](repeating: 0, count: 64)
    var count: UInt32 = 0
    let result = resolved.function(UInt32(ids.count), &ids, &count)
    guard result == .success, count <= ids.count else {
      return AllDisplayResult(
        ids: fallback,
        source: "CGGetOnlineDisplayList fallback",
        error: "\(resolved.name) returned \(result.rawValue), count=\(count)"
      )
    }
    return AllDisplayResult(
      ids: Array(ids.prefix(Int(count))),
      source: resolved.name,
      error: nil
    )
  }

  private func makeDisplayRecord(id: CGDirectDisplayID) -> DisplayRecord {
    let uuid = displayUUID(id)
    let vendorID = CGDisplayVendorNumber(id)
    let modelID = CGDisplayModelNumber(id)
    let serialNumber = CGDisplaySerialNumber(id)
    let edidUUID = coreDisplayEDIDUUID(id)
    let bounds = CGDisplayBounds(id)

    return DisplayRecord(
      role: role(
        id: id,
        uuid: uuid,
        edidUUID: edidUUID,
        vendorID: vendorID,
        modelID: modelID,
        serialNumber: serialNumber
      ),
      runtimeID: id,
      uuid: uuid,
      vendorID: vendorID,
      modelID: modelID,
      serialNumber: serialNumber,
      isBuiltIn: CGDisplayIsBuiltin(id) != 0,
      isActive: CGDisplayIsActive(id) != 0,
      isMain: id == CGMainDisplayID(),
      originX: Int(bounds.origin.x),
      originY: Int(bounds.origin.y),
      width: Int(bounds.width),
      height: Int(bounds.height),
      edidUUID: edidUUID,
      mode: displayMode(id)
    )
  }

  private func role(
    id: CGDirectDisplayID,
    uuid: String?,
    edidUUID: String?,
    vendorID: UInt32,
    modelID: UInt32,
    serialNumber: UInt32
  ) -> DisplayRole {
    if CGDisplayIsBuiltin(id) != 0 {
      return .builtIn
    }
    if let uuid = uuid?.uppercased() {
      switch uuid {
      case FixedDisplayConfiguration.viewSonicUUID:
        return .viewSonic
      case FixedDisplayConfiguration.philipsUUID:
        return .philips
      default:
        break
      }
    }
    if let edidUUID = edidUUID?.uppercased() {
      switch edidUUID {
      case FixedDisplayConfiguration.viewSonicEDIDUUID:
        return .viewSonic
      case FixedDisplayConfiguration.philipsEDIDUUID:
        return .philips
      default:
        break
      }
    }
    if vendorID == FixedDisplayConfiguration.viewSonicVendorID,
      modelID == FixedDisplayConfiguration.viewSonicModelID,
      serialNumber == FixedDisplayConfiguration.viewSonicSerialNumber
    {
      return .viewSonic
    }
    if vendorID == FixedDisplayConfiguration.philipsVendorID,
      modelID == FixedDisplayConfiguration.philipsModelID,
      serialNumber == FixedDisplayConfiguration.philipsSerialNumber
    {
      return .philips
    }
    return .unknown
  }

  private func displayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
      let value = CFUUIDCreateString(nil, uuid)
    else {
      return nil
    }
    return value as String
  }

  private func displayMode(_ id: CGDirectDisplayID) -> DisplayModeRecord? {
    guard let mode = CGDisplayCopyDisplayMode(id) else {
      return nil
    }
    return DisplayModeRecord(
      logicalWidth: mode.width,
      logicalHeight: mode.height,
      pixelWidth: mode.pixelWidth,
      pixelHeight: mode.pixelHeight,
      refreshRate: mode.refreshRate,
      isHiDPI: mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
    )
  }

  private func coreDisplayEDIDUUID(_ id: CGDirectDisplayID) -> String? {
    guard let createInfo = privateSymbols.createDisplayInfoFunction(),
      let dictionary = createInfo(id)?.takeRetainedValue() as? [String: Any]
    else {
      return nil
    }
    guard let location = dictionary["IODisplayLocation"] as? String else { return nil }
    let service = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return recursiveProperty(service: service, key: "EDID UUID") as? String
  }

  private func recursiveProperty(service: io_registry_entry_t, key: String) -> Any? {
    IORegistryEntrySearchCFProperty(
      service,
      kIOServicePlane,
      key as CFString,
      kCFAllocatorDefault,
      IOOptionBits(kIORegistryIterateRecursively)
    )
  }

  private func makeChecks(
    displays: [DisplayRecord],
    configureAvailable: Bool,
    metadataAvailable: Bool,
    allListSource: String,
    allListError: String?
  ) -> [CheckRecord] {
    let allListAvailable =
      allListError == nil
      && ["CGSGetDisplayList", "SLSGetDisplayList"].contains(allListSource)
    let builtIns = displays.filter { $0.role == .builtIn }
    let viewSonics = displays.filter { $0.role == .viewSonic }
    let philipsDisplays = displays.filter { $0.role == .philips }
    let unknowns = displays.filter { $0.role == .unknown }
    let viewSonic = viewSonics.first
    let philips = philipsDisplays.first
    let baseline = SoftKVMMacBaseline.resolve(displays)
    let supportedMainCount = displays.filter {
      $0.isActive && $0.isMain && ($0.role == .builtIn || $0.role == .viewSonic)
    }.count

    return [
      CheckRecord(name: "configure-symbol", passed: configureAvailable),
      CheckRecord(name: "all-display-list", passed: allListAvailable),
      CheckRecord(name: "built-in-identity", passed: builtIns.count == 1),
      CheckRecord(name: "viewsonic-identity", passed: viewSonics.count == 1),
      CheckRecord(name: "philips-identity", passed: philipsDisplays.count == 1),
      CheckRecord(name: "core-display-metadata", passed: metadataAvailable),
      CheckRecord(
        name: "viewsonic-uuid-identity",
        passed: viewSonic?.uuid?.uppercased() == FixedDisplayConfiguration.viewSonicUUID
      ),
      CheckRecord(
        name: "viewsonic-edid-identity",
        passed: viewSonic?.edidUUID?.uppercased()
          == FixedDisplayConfiguration.viewSonicEDIDUUID
      ),
      CheckRecord(
        name: "viewsonic-basic-identity",
        passed: viewSonic?.vendorID == FixedDisplayConfiguration.viewSonicVendorID
          && viewSonic?.modelID == FixedDisplayConfiguration.viewSonicModelID
          && viewSonic?.serialNumber == FixedDisplayConfiguration.viewSonicSerialNumber
      ),
      CheckRecord(
        name: "philips-uuid-identity",
        passed: philips?.uuid?.uppercased() == FixedDisplayConfiguration.philipsUUID
      ),
      CheckRecord(
        name: "philips-edid-identity",
        passed: philips?.edidUUID?.uppercased() == FixedDisplayConfiguration.philipsEDIDUUID
      ),
      CheckRecord(
        name: "philips-basic-identity",
        passed: philips?.vendorID == FixedDisplayConfiguration.philipsVendorID
          && philips?.modelID == FixedDisplayConfiguration.philipsModelID
          && philips?.serialNumber == FixedDisplayConfiguration.philipsSerialNumber
      ),
      CheckRecord(name: "no-unknown-real-display", passed: unknowns.isEmpty),
      CheckRecord(
        name: "supported-main-display",
        passed: supportedMainCount == 1 && philips?.isMain == false
      ),
      CheckRecord(
        name: "supported-horizontal-layout",
        passed: baseline != nil
      ),
      CheckRecord(
        name: "viewsonic-mode",
        passed: FixedDisplayConfiguration.isProtectedViewSonicMode(viewSonic?.mode)
      ),
      CheckRecord(
        name: "philips-safe-target",
        passed: philips?.isBuiltIn == false && philips?.isMain == false
      ),
      CheckRecord(
        name: "three-active-displays",
        passed: displays.filter(\.isActive).count == 3
      )
    ]
  }

  private func topologyState(_ displays: [DisplayRecord]) -> DisplayTopologyState {
    if let baseline = SoftKVMMacBaseline.resolve(displays),
      FixedDisplayConfiguration.isProtectedViewSonicMode(baseline.viewSonic.mode)
    {
      return .mac
    }
    if let windows = SoftKVMWindowsTopology.resolve(displays),
      FixedDisplayConfiguration.isProtectedViewSonicMode(windows.viewSonic.mode)
    {
      return .windows
    }
    return .unknown
  }

  private func roleOrder(_ role: DisplayRole) -> Int {
    switch role {
    case .builtIn: 0
    case .viewSonic: 1
    case .philips: 2
    case .unknown: 3
    }
  }
}

extension Array {
  func single(where predicate: (Element) throws -> Bool) rethrows -> Element? {
    let matches = try filter(predicate)
    return matches.count == 1 ? matches[0] : nil
  }
}
