import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WindowProbe {
  private struct ApplicationSnapshot: Sendable {
    let name: String
    let bundleIdentifier: String?
    let processID: pid_t
    let launchTimestamp: Double?
    let hidden: Bool
    let reportsReadFailure: Bool
  }

  func run() async throws -> WindowProbeReport {
    try Task.checkCancellation()
    let trusted = AXIsProcessTrusted()
    guard trusted else {
      return WindowProbeReport(
        accessibilityTrusted: false,
        failedApplications: [],
        windows: []
      )
    }

    let activeDisplays = DisplayProbe().run().displays.filter(\.isActive)
    let applications: [ApplicationSnapshot] = NSWorkspace.shared.runningApplications.compactMap {
      application in
      guard !application.isTerminated, application.processIdentifier != getpid() else {
        return nil
      }
      return ApplicationSnapshot(
        name: application.localizedName ?? "PID \(application.processIdentifier)",
        bundleIdentifier: application.bundleIdentifier,
        processID: application.processIdentifier,
        launchTimestamp: application.launchDate?.timeIntervalSince1970,
        hidden: application.isHidden,
        reportsReadFailure: application.activationPolicy == .regular
      )
    }
    let task = Task.detached(priority: .userInitiated) {
      try Self.scan(applications: applications, displays: activeDisplays)
    }
    return try await withTaskCancellationHandler {
      let report = try await task.value
      try Task.checkCancellation()
      return report
    } onCancel: {
      task.cancel()
    }
  }

  nonisolated private static func scan(
    applications: [ApplicationSnapshot],
    displays: [DisplayRecord]
  ) throws -> WindowProbeReport {
    var records: [WindowProbeRecord] = []
    var uninspectableApplications: [ApplicationSnapshot] = []
    for application in applications {
      try Task.checkCancellation()
      let element = AXUIElementCreateApplication(application.processID)
      guard let windows = copyWindows(from: element) else {
        if application.reportsReadFailure {
          uninspectableApplications.append(application)
        }
        continue
      }
      for (index, window) in windows.enumerated() {
        try Task.checkCancellation()
        records.append(
          record(
            window: window,
            index: index,
            application: application,
            displays: displays
          )
        )
      }
    }
    let failedApplications: [String]
    if uninspectableApplications.isEmpty {
      failedApplications = []
    } else {
      let onScreenWindowSnapshot = currentOnScreenWindows()
      let protectedDisplayFrame = displays.first(where: {
        $0.role == .philips && $0.isActive
      }).map(displayFrame)
      failedApplications = uninspectableApplications.compactMap { application in
        uninspectableApplicationBlocksDisplaySwitch(
          processID: application.processID,
          onScreenWindowSnapshot: onScreenWindowSnapshot,
          protectedDisplayFrame: protectedDisplayFrame
        ) ? application.name : nil
      }
    }
    records.sort {
      if $0.assignedDisplayRole != $1.assignedDisplayRole {
        return displayOrder($0.assignedDisplayRole) < displayOrder($1.assignedDisplayRole)
      }
      if $0.applicationName != $1.applicationName {
        return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
      }
      return $0.windowIndex < $1.windowIndex
    }
    return WindowProbeReport(
      accessibilityTrusted: true,
      failedApplications: failedApplications.sorted(),
      windows: records
    )
  }

  func resolveWindow(
    processID: pid_t,
    bundleIdentifier: String?,
    applicationLaunchTimestamp: Double?,
    windowIndex: Int,
    windowIdentifier: String?,
    title: String,
    expectedRole: String? = nil,
    expectedSubrole: String? = nil,
    near frame: WindowFrameRecord? = nil
  ) throws -> AXUIElement? {
    guard let runningApplication = NSRunningApplication(processIdentifier: processID),
      !runningApplication.isTerminated,
      bundleIdentifier == nil || runningApplication.bundleIdentifier == bundleIdentifier
    else {
      return nil
    }
    if let expectedLaunch = applicationLaunchTimestamp {
      guard let actualLaunch = runningApplication.launchDate?.timeIntervalSince1970,
        abs(actualLaunch - expectedLaunch) < 0.5
      else {
        return nil
      }
    }

    let application = AXUIElementCreateApplication(processID)
    guard let windows = Self.copyWindows(from: application) else {
      throw DisplayControlError.verification("无法读取 PID \(processID) 的窗口列表")
    }
    let typeMatches = windows.filter {
      (expectedRole == nil || Self.stringAttribute($0, kAXRoleAttribute as CFString) == expectedRole)
        && (expectedSubrole == nil
          || Self.stringAttribute($0, kAXSubroleAttribute as CFString) == expectedSubrole)
    }
    if let windowIdentifier, !windowIdentifier.isEmpty {
      let matches = typeMatches.filter {
        Self.stringAttribute($0, kAXIdentifierAttribute as CFString) == windowIdentifier
      }
      if let frame {
        return matches.min {
          Self.frameDistance(Self.windowFrame($0), frame)
            < Self.frameDistance(Self.windowFrame($1), frame)
        }
      }
      return matches.single(where: { _ in true })
    }
    if windows.indices.contains(windowIndex) {
      let window = windows[windowIndex]
      let currentTitle = Self.stringAttribute(window, kAXTitleAttribute as CFString) ?? ""
      let typeMatchesExpected =
        (expectedRole == nil
          || Self.stringAttribute(window, kAXRoleAttribute as CFString) == expectedRole)
        && (expectedSubrole == nil
          || Self.stringAttribute(window, kAXSubroleAttribute as CFString) == expectedSubrole)
      if typeMatchesExpected, let frame,
         Self.windowFrame(window)?.isNear(frame, tolerance: 8) == true {
        return window
      }
      if typeMatchesExpected, frame == nil, currentTitle == title {
        return window
      }
    }
    let titleMatches = typeMatches.filter {
      Self.stringAttribute($0, kAXTitleAttribute as CFString) ?? "" == title
    }
    guard let frame else {
      return titleMatches.single(where: { _ in true })
    }
    let nearbyTitleMatches = titleMatches.filter {
      Self.windowFrame($0)?.isNear(frame, tolerance: 8) == true
    }
    if let closest = nearbyTitleMatches.min(by: {
      Self.frameDistance(Self.windowFrame($0), frame)
        < Self.frameDistance(Self.windowFrame($1), frame)
    }) {
      return closest
    }
    return typeMatches.single(where: {
      Self.windowFrame($0)?.isNear(frame, tolerance: 8) == true
    })
  }

  func frame(of window: AXUIElement) -> WindowFrameRecord? {
    Self.windowFrame(window)
  }

  nonisolated private static func record(
    window: AXUIElement,
    index: Int,
    application: ApplicationSnapshot,
    displays: [DisplayRecord]
  ) -> WindowProbeRecord {
    let role = stringAttribute(window, kAXRoleAttribute as CFString)
    let subrole = stringAttribute(window, kAXSubroleAttribute as CFString)
    let frame = windowFrame(window)
    let assignment = frame.flatMap { assignedDisplay(for: $0, displays: displays) }
    let minimized = boolAttribute(window, kAXMinimizedAttribute as CFString) ?? false
    let fullScreen = boolAttribute(window, "AXFullScreen" as CFString) ?? false
    let positionSettable = isAXAttributeSettable(window, kAXPositionAttribute as CFString)
    let sizeSettable = isAXAttributeSettable(window, kAXSizeAttribute as CFString)
    let standardWindow = role == (kAXWindowRole as String)
      && subrole == (kAXStandardWindowSubrole as String)
    let moveCandidate = assignment?.role == .philips
      && !application.hidden
      && !minimized
      && !fullScreen
      && isSupportedMigrationWindow(role: role, subrole: subrole)
      && positionSettable
      && frame != nil
    return WindowProbeRecord(
      applicationName: application.name,
      bundleIdentifier: application.bundleIdentifier,
      processID: application.processID,
      applicationLaunchTimestamp: application.launchTimestamp,
      windowIndex: index,
      windowIdentifier: stringAttribute(window, kAXIdentifierAttribute as CFString),
      title: stringAttribute(window, kAXTitleAttribute as CFString) ?? "",
      role: role,
      subrole: subrole,
      frame: frame,
      assignedDisplayRole: assignment?.role,
      applicationHidden: application.hidden,
      minimized: minimized,
      fullScreen: fullScreen,
      positionSettable: positionSettable,
      sizeSettable: sizeSettable,
      coversAssignedDisplay: frame.flatMap { windowFrame in
        assignment.map { framesMatch(windowFrame.cgRect, displayFrame($0), tolerance: 2) }
      } ?? false,
      standardWindow: standardWindow,
      moveCandidate: moveCandidate
    )
  }

  nonisolated private static func copyWindows(
    from application: AXUIElement
  ) -> [AXUIElement]? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      application,
      kAXWindowsAttribute as CFString,
      &value
    )
    if result == .noValue {
      return []
    }
    guard result == .success else {
      return nil
    }
    return value as? [AXUIElement]
  }

  nonisolated private static func currentOnScreenWindows() -> OnScreenWindowSnapshot? {
    guard let entries = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return nil
    }
    var records: [OnScreenWindowRecord] = []
    var unverifiedProcessIDs: Set<Int32> = []
    for entry in entries {
      guard let ownerProcessID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
        return nil
      }
      guard let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue else {
        unverifiedProcessIDs.insert(ownerProcessID)
        continue
      }
      guard alpha > 0 else {
        continue
      }
      guard let bounds = entry[kCGWindowBounds as String] as? [String: NSNumber] else {
        unverifiedProcessIDs.insert(ownerProcessID)
        continue
      }
      var frame = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
        frame.origin.x.isFinite,
        frame.origin.y.isFinite,
        frame.width.isFinite,
        frame.height.isFinite,
        frame.width > 0,
        frame.height > 0
      else {
        unverifiedProcessIDs.insert(ownerProcessID)
        continue
      }
      records.append(OnScreenWindowRecord(ownerProcessID: ownerProcessID, frame: frame))
    }
    return OnScreenWindowSnapshot(
      windows: records,
      unverifiedProcessIDs: unverifiedProcessIDs
    )
  }

  nonisolated private static func stringAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
  ) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return value as? String
  }

  nonisolated private static func boolAttribute(
    _ element: AXUIElement,
    _ attribute: CFString
  ) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
      return nil
    }
    return (value as? NSNumber)?.boolValue
  }

  nonisolated private static func windowFrame(
    _ element: AXUIElement
  ) -> WindowFrameRecord? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      kAXPositionAttribute as CFString,
      &positionValue
    ) == .success,
      AXUIElementCopyAttributeValue(
        element,
        kAXSizeAttribute as CFString,
        &sizeValue
      ) == .success,
      let positionValue,
      let sizeValue,
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    let position = unsafeDowncast(positionValue, to: AXValue.self)
    let dimensions = unsafeDowncast(sizeValue, to: AXValue.self)
    guard AXValueGetType(position) == .cgPoint,
      AXValueGetType(dimensions) == .cgSize,
      AXValueGetValue(position, .cgPoint, &point),
      AXValueGetValue(dimensions, .cgSize, &size),
      point.x.isFinite,
      point.y.isFinite,
      size.width.isFinite,
      size.height.isFinite,
      size.width > 0,
      size.height > 0
    else {
      return nil
    }
    return WindowFrameRecord(x: point.x, y: point.y, width: size.width, height: size.height)
  }

  nonisolated private static func assignedDisplay(
    for frame: WindowFrameRecord,
    displays: [DisplayRecord]
  ) -> DisplayRecord? {
    displays.max {
      intersectionArea(frame.cgRect, display: $0) < intersectionArea(frame.cgRect, display: $1)
    }.flatMap { intersectionArea(frame.cgRect, display: $0) > 0 ? $0 : nil }
  }

  nonisolated private static func intersectionArea(
    _ window: CGRect,
    display: DisplayRecord
  ) -> CGFloat {
    let displayRect = displayFrame(display)
    let intersection = window.intersection(displayRect)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }

  nonisolated private static func displayFrame(_ display: DisplayRecord) -> CGRect {
    CGRect(
      x: display.originX,
      y: display.originY,
      width: display.width,
      height: display.height
    )
  }

  nonisolated private static func framesMatch(
    _ lhs: CGRect,
    _ rhs: CGRect,
    tolerance: CGFloat
  ) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
      && abs(lhs.minY - rhs.minY) <= tolerance
      && abs(lhs.width - rhs.width) <= tolerance
      && abs(lhs.height - rhs.height) <= tolerance
  }

  nonisolated private static func displayOrder(_ role: DisplayRole?) -> Int {
    switch role {
    case .philips: 0
    case .viewSonic: 1
    case .builtIn: 2
    case .unknown: 3
    case nil: 4
    }
  }

  nonisolated private static func frameDistance(
    _ lhs: WindowFrameRecord?,
    _ rhs: WindowFrameRecord
  ) -> Double {
    guard let lhs else {
      return .greatestFiniteMagnitude
    }
    return abs(lhs.x - rhs.x) + abs(lhs.y - rhs.y)
      + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
  }
}
