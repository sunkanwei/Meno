import ApplicationServices
import CoreGraphics
import Foundation

struct WindowFrameRecord: Codable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

  func isNear(_ other: WindowFrameRecord, tolerance: Double) -> Bool {
    abs(x - other.x) <= tolerance
      && abs(y - other.y) <= tolerance
      && abs(width - other.width) <= tolerance
      && abs(height - other.height) <= tolerance
  }
}

struct WindowProbeRecord: Sendable {
  let applicationName: String
  let bundleIdentifier: String?
  let processID: Int32
  let applicationLaunchTimestamp: Double?
  let windowIndex: Int
  let windowIdentifier: String?
  let title: String
  let role: String?
  let subrole: String?
  let frame: WindowFrameRecord?
  let assignedDisplayRole: DisplayRole?
  let applicationHidden: Bool
  let minimized: Bool
  let fullScreen: Bool
  let positionSettable: Bool
  let sizeSettable: Bool
  let coversAssignedDisplay: Bool
  let standardWindow: Bool
  let moveCandidate: Bool
}

struct WindowProbeReport: Sendable {
  let accessibilityTrusted: Bool
  let failedApplications: [String]
  let windows: [WindowProbeRecord]
}

struct OnScreenWindowRecord: Sendable {
  let ownerProcessID: Int32
  let frame: CGRect
}

struct OnScreenWindowSnapshot: Sendable {
  let windows: [OnScreenWindowRecord]
  let unverifiedProcessIDs: Set<Int32>
}

func uninspectableApplicationBlocksDisplaySwitch(
  processID: Int32,
  onScreenWindowSnapshot: OnScreenWindowSnapshot?,
  protectedDisplayFrame: CGRect?
) -> Bool {
  guard let onScreenWindowSnapshot, let protectedDisplayFrame,
    !onScreenWindowSnapshot.unverifiedProcessIDs.contains(processID)
  else {
    return true
  }
  return onScreenWindowSnapshot.windows.contains {
    guard $0.ownerProcessID == processID else { return false }
    let intersection = $0.frame.intersection(protectedDisplayFrame)
    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
  }
}

func isIgnoredSystemWindowForDisplaySwitch(bundleIdentifier: String?) -> Bool {
  bundleIdentifier == "com.apple.notificationcenterui"
}

func isFinderDesktopShellWindow(
  bundleIdentifier: String?,
  title: String,
  role: String?,
  subrole: String?,
  positionSettable: Bool,
  sizeSettable: Bool,
  coversAssignedDisplay: Bool
) -> Bool {
  bundleIdentifier == "com.apple.finder"
    && title.isEmpty
    && role == (kAXWindowRole as String)
    && !isSupportedMigrationWindow(role: role, subrole: subrole)
    && !positionSettable
    && !sizeSettable
    && coversAssignedDisplay
}

func isIgnoredSystemWindowForDisplaySwitch(_ window: WindowProbeRecord) -> Bool {
  isIgnoredSystemWindowForDisplaySwitch(bundleIdentifier: window.bundleIdentifier)
    || isFinderDesktopShellWindow(
      bundleIdentifier: window.bundleIdentifier,
      title: window.title,
      role: window.role,
      subrole: window.subrole,
      positionSettable: window.positionSettable,
      sizeSettable: window.sizeSettable,
      coversAssignedDisplay: window.coversAssignedDisplay
    )
}

func isSupportedMigrationWindow(role: String?, subrole: String?) -> Bool {
  role == (kAXWindowRole as String)
    && (subrole == (kAXStandardWindowSubrole as String)
      || subrole == (kAXDialogSubrole as String))
}

func isAXAttributeSettable(
  _ element: AXUIElement,
  _ attribute: CFString
) -> Bool {
  var settable = DarwinBoolean(false)
  return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
    && settable.boolValue
}

extension CGRect {
  func contains(_ other: CGRect, tolerance: CGFloat) -> Bool {
    other.minX >= minX - tolerance
      && other.minY >= minY - tolerance
      && other.maxX <= maxX + tolerance
      && other.maxY <= maxY + tolerance
  }
}

extension Comparable {
  func displaySwitchClamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
