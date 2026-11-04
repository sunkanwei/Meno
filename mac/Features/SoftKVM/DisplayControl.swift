import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class DisplayHardwareController {
  private let probe = DisplayProbe()
  private let symbols = PrivateDisplaySymbols()

  func snapshot() -> ProbeReport {
    probe.run()
  }

  func philipsDisplayLocation() throws -> String {
    let displays = probe.run().displays
    guard let philips = displays.single(where: { $0.role == .philips }) else {
      throw DisplayControlError.preflight("找不到唯一的飞利浦显示器")
    }
    try requireSafePhilips(philips)
    guard let location = probe.displayLocation(philips.runtimeID) else {
      throw DisplayControlError.privateAPI("无法定位飞利浦的 HDMI 控制接口")
    }
    return location
  }

  func requireBetterDisplayStopped() throws {
    let running = NSWorkspace.shared.runningApplications.contains { application in
      application.bundleIdentifier?.hasPrefix("pro.betterdisplay.") == true
        || application.bundleURL?.lastPathComponent.caseInsensitiveCompare("BetterDisplay.app")
          == .orderedSame
    }
    if running {
      throw DisplayControlError.betterDisplayRunning
    }
  }

  func requireAccessibility() throws {
    guard AXIsProcessTrusted() else {
      throw DisplayControlError.preflight("尚未授予辅助功能权限")
    }
  }

  func setPhilipsEnabled(runtimeID: UInt32, enabled: Bool) throws {
    let current = probe.run()
    guard let philips = current.displays.single(where: { $0.role == .philips }),
      philips.runtimeID == runtimeID
    else {
      throw DisplayControlError.verification("Philips 运行时 ID 已变化")
    }
    try requireSafePhilips(philips)
    guard let resolved = symbols.firstConfigureFunction() else {
      throw DisplayControlError.privateAPI("CGS/SLSConfigureDisplayEnabled 不可用")
    }

    var configuration: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&configuration)
    guard beginResult == .success, configuration != nil else {
      throw DisplayControlError.privateAPI(
        "CGBeginDisplayConfiguration 返回 \(beginResult.rawValue)"
      )
    }
    let configureResult = resolved.function(configuration, runtimeID, enabled)
    guard configureResult == .success else {
      CGCancelDisplayConfiguration(configuration)
      throw DisplayControlError.privateAPI(
        "\(resolved.name)(ID \(runtimeID), enabled=\(enabled)) 返回 \(configureResult.rawValue)"
      )
    }
    let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard completeResult == .success else {
      throw DisplayControlError.privateAPI(
        "CGCompleteDisplayConfiguration(.forSession) 返回 \(completeResult.rawValue)"
      )
    }
  }

  func setDisplayOrigin(runtimeID: UInt32, x: Int, y: Int) throws {
    guard let originX = Int32(exactly: x),
      let originY = Int32(exactly: y)
    else {
      throw DisplayControlError.verification("显示器坐标超出系统支持范围")
    }
    let current = probe.run()
    guard let display = current.displays.single(where: { $0.runtimeID == runtimeID }),
      display.isActive,
      !display.isMain,
      display.role == .builtIn || display.role == .viewSonic
    else {
      throw DisplayControlError.verification("待恢复位置的 Mac 显示器身份或状态已变化")
    }

    var configuration: CGDisplayConfigRef?
    let beginResult = CGBeginDisplayConfiguration(&configuration)
    guard beginResult == .success, configuration != nil else {
      throw DisplayControlError.privateAPI(
        "CGBeginDisplayConfiguration 返回 \(beginResult.rawValue)"
      )
    }
    let configureResult = CGConfigureDisplayOrigin(
      configuration,
      runtimeID,
      originX,
      originY
    )
    guard configureResult == .success else {
      CGCancelDisplayConfiguration(configuration)
      throw DisplayControlError.privateAPI(
        "CGConfigureDisplayOrigin(ID \(runtimeID)) 返回 \(configureResult.rawValue)"
      )
    }
    let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
    guard completeResult == .success else {
      throw DisplayControlError.privateAPI(
        "CGCompleteDisplayConfiguration(.forSession) 返回 \(completeResult.rawValue)"
      )
    }
  }

  func requireSafePhilips(_ display: DisplayRecord) throws {
    let uuidMatches = display.uuid?.uppercased() == FixedDisplayConfiguration.philipsUUID
    let edidMatches = display.edidUUID?.uppercased() == FixedDisplayConfiguration.philipsEDIDUUID
    let stableMetadataIsSafe = display.isActive
      ? uuidMatches && edidMatches
      : (display.uuid == nil || uuidMatches) && (display.edidUUID == nil || edidMatches)

    guard stableMetadataIsSafe,
      display.vendorID == FixedDisplayConfiguration.philipsVendorID,
      display.modelID == FixedDisplayConfiguration.philipsModelID,
      display.serialNumber == FixedDisplayConfiguration.philipsSerialNumber,
      !display.isBuiltIn,
      !display.isMain
    else {
      throw DisplayControlError.preflight("目标不满足 Philips 硬件白名单或安全条件")
    }
  }

  func requireProtectedViewSonic(_ display: DisplayRecord) throws {
    guard display.uuid?.uppercased() == FixedDisplayConfiguration.viewSonicUUID,
      display.edidUUID?.uppercased() == FixedDisplayConfiguration.viewSonicEDIDUUID,
      display.vendorID == FixedDisplayConfiguration.viewSonicVendorID,
      display.modelID == FixedDisplayConfiguration.viewSonicModelID,
      display.serialNumber == FixedDisplayConfiguration.viewSonicSerialNumber,
      display.isActive,
      FixedDisplayConfiguration.isProtectedViewSonicMode(display.mode)
    else {
      throw DisplayControlError.verification(
        "ViewSonic 硬件身份或 2048×1152 HiDPI 60Hz 保护断言失败"
      )
    }
  }

  nonisolated func identityMatches(_ current: DisplayRecord, _ saved: DisplayRecord) -> Bool {
    guard current.vendorID == saved.vendorID,
      current.modelID == saved.modelID,
      current.serialNumber == saved.serialNumber
    else {
      return false
    }
    if let currentUUID = current.uuid, let savedUUID = saved.uuid,
      currentUUID.caseInsensitiveCompare(savedUUID) != .orderedSame
    {
      return false
    }
    if let currentEDID = current.edidUUID, let savedEDID = saved.edidUUID,
      currentEDID.caseInsensitiveCompare(savedEDID) != .orderedSame
    {
      return false
    }
    return true
  }
}
