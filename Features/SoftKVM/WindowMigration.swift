import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WindowMigrationController {
  private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

  private let displayController: DisplayHardwareController
  private let windowProbe: WindowProbe
  private let stateStore: DisplayStateStore

  init(
    displayController: DisplayHardwareController,
    stateStore: DisplayStateStore
  ) {
    self.displayController = displayController
    self.stateStore = stateStore
    windowProbe = WindowProbe()
  }

  func movePhilipsWindowsToMainDisplay(
    requireWindow: Bool = true
  ) async throws {
    guard AXIsProcessTrusted() else {
      throw DisplayControlError.preflight("尚未授予辅助功能权限")
    }
    guard try await stateStore.windowMigrationState() == nil else {
      throw DisplayControlError.state("已有窗口搬运快照，请先恢复到 Mac")
    }

    let displayReport = displayController.snapshot()
    guard let layout = SoftKVMMacBaseline.resolve(displayReport.displays),
      displayReport.topology == .mac,
      displayReport.passed,
      layout.philips.isActive
    else {
      throw DisplayControlError.preflight("窗口搬运只允许在完整 Mac 三屏基线下执行")
    }
    let philips = layout.philips
    let mainDisplay = layout.mainDisplay

    let windowReport = try await validatedWindowReport()
    let blocked = windowReport.windows.filter {
      $0.assignedDisplayRole == .philips
        && !$0.applicationHidden
        && !$0.minimized
        && !$0.moveCandidate
        && !isIgnoredSystemWindowForDisplaySwitch($0)
    }
    guard blocked.isEmpty else {
      throw DisplayControlError.preflight(
        "Philips 上存在不能安全搬运的可见窗口：\(windowDescriptions(blocked))"
      )
    }
    let movable = windowReport.windows.filter(\.moveCandidate)
    let candidates = movable.filter(\.standardWindow) + movable.filter { !$0.standardWindow }
    if candidates.isEmpty {
      if requireWindow {
        throw DisplayControlError.preflight("Philips 上没有可搬运的普通窗口")
      }
      return
    }
    guard let targetVisibleFrame = visibleFrame(displayID: mainDisplay.runtimeID) else {
      throw DisplayControlError.preflight("无法获取 Mac 主屏幕可用显示区域")
    }
    let sourceFrame = CGRect(
      x: philips.originX,
      y: philips.originY,
      width: philips.width,
      height: philips.height
    )

    var prepared: [(entry: WindowMigrationEntry, element: AXUIElement)] = []
    for candidate in candidates {
      guard let originalFrame = candidate.frame,
        let element = try windowProbe.resolveWindow(
          processID: candidate.processID,
          bundleIdentifier: candidate.bundleIdentifier,
          applicationLaunchTimestamp: candidate.applicationLaunchTimestamp,
          windowIndex: candidate.windowIndex,
          windowIdentifier: candidate.windowIdentifier,
          title: candidate.windowIdentifier == nil ? candidate.title : "",
          expectedRole: candidate.role,
          expectedSubrole: candidate.subrole,
          near: originalFrame
        )
      else {
        throw DisplayControlError.verification(
            "搬运前无法重新定位 \(candidate.applicationName) 的窗口"
        )
      }
      let movedFrame = try mappedFrame(
        originalFrame,
        from: sourceFrame,
        to: targetVisibleFrame,
        canResize: candidate.sizeSettable
      )
      prepared.append((
        WindowMigrationEntry(
          applicationName: candidate.applicationName,
          bundleIdentifier: candidate.bundleIdentifier,
          processID: candidate.processID,
          applicationLaunchTimestamp: candidate.applicationLaunchTimestamp,
          windowIndex: candidate.windowIndex,
          windowIdentifier: candidate.windowIdentifier,
          title: candidate.windowIdentifier == nil ? candidate.title : "",
          role: candidate.role,
          subrole: candidate.subrole,
          originalFrame: originalFrame,
          movedFrame: movedFrame
        ),
        element
      ))
    }

    let state = WindowMigrationState(
      schemaVersion: 1,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      entries: prepared.map(\.entry)
    )
    try await stateStore.save(windowMigrationState: state)
    do {
      for item in prepared {
        try Task.checkCancellation()
        try setFrame(item.entry.movedFrame, for: item.element)
        guard let actual = try await waitForFrame(
          of: item.element,
          inside: targetVisibleFrame
        ), targetVisibleFrame.contains(actual.cgRect, tolerance: 2) else {
          throw DisplayControlError.verification(
            "\(item.entry.applicationName) 的窗口未完整进入 Mac 主屏幕"
          )
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      do {
        try await restoreEntries(state.entries)
        try await stateStore.clearWindowMigrationState()
      } catch let rollbackError {
        throw DisplayControlError.rollback(
          "原错误：\(error)；窗口回滚错误：\(rollbackError)；快照已保留"
        )
      }
      throw error
    }
  }

  func restoreWindows() async throws {
    guard let state = try await stateStore.windowMigrationState() else {
      throw DisplayControlError.state("没有窗口搬运快照")
    }
    let report = displayController.snapshot()
    guard report.topology == .mac, report.passed else {
      throw DisplayControlError.preflight("只允许在完整 Mac 三屏基线下还原窗口")
    }
    try await restoreEntries(state.entries)
    try await stateStore.clearWindowMigrationState()
  }

  func restoreWindowsIfNeeded() async throws {
    guard try await stateStore.windowMigrationState() != nil else { return }
    try await restoreWindows()
  }

  func requireNoVisiblePhilipsWindows() async throws {
    let report = try await validatedWindowReport()
    let remaining = report.windows.filter {
      $0.assignedDisplayRole == .philips
        && !$0.applicationHidden
        && !$0.minimized
        && !isIgnoredSystemWindowForDisplaySwitch($0)
    }
    guard remaining.isEmpty else {
      throw DisplayControlError.verification(
        "切换期间 Philips 上又出现了可见窗口：\(windowDescriptions(remaining))"
      )
    }
  }

  private func restoreEntries(_ entries: [WindowMigrationEntry]) async throws {
    var failures: [String] = []
    for entry in entries {
      do {
        try Task.checkCancellation()
        guard let element = try windowProbe.resolveWindow(
          processID: entry.processID,
          bundleIdentifier: entry.bundleIdentifier,
          applicationLaunchTimestamp: entry.applicationLaunchTimestamp,
          windowIndex: entry.windowIndex,
          windowIdentifier: entry.windowIdentifier,
          title: entry.title,
          expectedRole: entry.role,
          expectedSubrole: entry.subrole,
          near: entry.movedFrame
        ) else {
          continue
        }
        try setFrame(entry.originalFrame, for: element)
        guard let actual = try await waitForFrame(of: element, near: entry.originalFrame),
          actual.isNear(entry.originalFrame, tolerance: 3)
        else {
          throw DisplayControlError.verification("窗口没有恢复原位")
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures.append("\(entry.applicationName)：\(error)")
      }
    }
    guard failures.isEmpty else {
      throw DisplayControlError.verification(
        "部分窗口恢复失败：\(failures.joined(separator: "；"))"
      )
    }
  }

  private func mappedFrame(
    _ frame: WindowFrameRecord,
    from source: CGRect,
    to target: CGRect,
    canResize: Bool
  ) throws -> WindowFrameRecord {
    let width = min(frame.width, target.width)
    let height = min(frame.height, target.height)
    guard canResize || (abs(width - frame.width) < 0.5 && abs(height - frame.height) < 0.5)
    else {
      throw DisplayControlError.preflight("窗口大于 Mac 主屏幕可用区域且不允许调整尺寸")
    }
    let sourceTravelX = max(0, source.width - frame.width)
    let sourceTravelY = max(0, source.height - frame.height)
    let targetTravelX = max(0, target.width - width)
    let targetTravelY = max(0, target.height - height)
    let relativeX = sourceTravelX > 0
      ? ((frame.x - source.minX) / sourceTravelX).displaySwitchClamped(to: 0...1) : 0.5
    let relativeY = sourceTravelY > 0
      ? ((frame.y - source.minY) / sourceTravelY).displaySwitchClamped(to: 0...1) : 0.5
    return WindowFrameRecord(
      x: target.minX + relativeX * targetTravelX,
      y: target.minY + relativeY * targetTravelY,
      width: width,
      height: height
    )
  }

  private func visibleFrame(displayID: UInt32) -> CGRect? {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[Self.screenNumberKey] as? NSNumber)?.uint32Value == displayID
    }), let mainScreen = NSScreen.screens.first(where: {
      ($0.deviceDescription[Self.screenNumberKey] as? NSNumber)?.uint32Value == CGMainDisplayID()
    }) else {
      return nil
    }
    let visible = screen.visibleFrame
    return CGRect(
      x: visible.minX,
      y: mainScreen.frame.maxY - visible.maxY,
      width: visible.width,
      height: visible.height
    )
  }

  private func setFrame(_ frame: WindowFrameRecord, for window: AXUIElement) throws {
    var size = CGSize(width: frame.width, height: frame.height)
    var point = CGPoint(x: frame.x, y: frame.y)
    guard let sizeValue = AXValueCreate(.cgSize, &size),
      let pointValue = AXValueCreate(.cgPoint, &point)
    else {
      throw DisplayControlError.verification("无法构造窗口坐标")
    }
    if isAXAttributeSettable(window, kAXSizeAttribute as CFString) {
      let result = AXUIElementSetAttributeValue(
        window,
        kAXSizeAttribute as CFString,
        sizeValue
      )
      guard result == .success else {
        throw DisplayControlError.verification("设置窗口尺寸失败：\(result.rawValue)")
      }
    }
    let positionResult = AXUIElementSetAttributeValue(
      window,
      kAXPositionAttribute as CFString,
      pointValue
    )
    guard positionResult == .success else {
      throw DisplayControlError.verification("设置窗口位置失败：\(positionResult.rawValue)")
    }
    if isAXAttributeSettable(window, kAXSizeAttribute as CFString) {
      _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
  }

  private func waitForFrame(
    of window: AXUIElement,
    inside target: CGRect? = nil,
    near expected: WindowFrameRecord? = nil
  ) async throws -> WindowFrameRecord? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1.5))
    var latest: WindowFrameRecord?
    while clock.now < deadline {
      latest = windowProbe.frame(of: window)
      if let latest {
        if let target, target.contains(latest.cgRect, tolerance: 2) {
          return latest
        }
        if let expected, latest.isNear(expected, tolerance: 3) {
          return latest
        }
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return latest
  }

  private func validatedWindowReport() async throws -> WindowProbeReport {
    let report = try await windowProbe.run()
    guard report.accessibilityTrusted else {
      throw DisplayControlError.preflight("尚未授予辅助功能权限")
    }
    guard report.failedApplications.isEmpty else {
      throw DisplayControlError.preflight(
        "无法确认这些 APP 的窗口位置：\(report.failedApplications.joined(separator: ", "))"
      )
    }
    let unlocated = report.windows.filter {
      isSupportedMigrationWindow(role: $0.role, subrole: $0.subrole)
        && !$0.applicationHidden && !$0.minimized && $0.frame == nil
    }
    guard unlocated.isEmpty else {
      throw DisplayControlError.preflight(
        "存在无法确认位置的普通窗口：\(windowDescriptions(unlocated))"
      )
    }
    return report
  }

  private func windowDescriptions(_ windows: [WindowProbeRecord]) -> String {
    windows.map {
      let reason: String
      if $0.fullScreen {
        reason = "全屏"
      } else if !$0.positionSettable {
        reason = "位置不可修改"
      } else if !isSupportedMigrationWindow(role: $0.role, subrole: $0.subrole) {
        reason = "系统或非标准窗口"
      } else {
        reason = "无法安全搬运"
      }
      return "\($0.applicationName)（\(reason)）"
    }.joined(separator: ", ")
  }
}
