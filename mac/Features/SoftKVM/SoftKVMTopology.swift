import Foundation

/// The horizontal route captured from the complete three-display Mac baseline.
/// It remains authoritative while the shared Philips display is disconnected.
struct SoftKVMTopologyPlan: Codable, Equatable, Sendable {
  let sharedDisplaySide: HorizontalDisplaySide

  var localDisplaySide: HorizontalDisplaySide {
    sharedDisplaySide.opposite
  }

  var macEntryEdge: HorizontalDisplaySide {
    sharedDisplaySide
  }

  var windowsEntryEdge: HorizontalDisplaySide {
    sharedDisplaySide.opposite
  }

  static func resolveLegacySnapshot(
    sharedDisplay: DisplayRecord,
    currentMainDisplay: DisplayRecord
  ) throws -> SoftKVMTopologyPlan {
    let tolerance = 2
    if sharedDisplay.originX + sharedDisplay.width <= currentMainDisplay.originX + tolerance {
      return SoftKVMTopologyPlan(sharedDisplaySide: .left)
    }
    if sharedDisplay.originX
      >= currentMainDisplay.originX + currentMainDisplay.width - tolerance
    {
      return SoftKVMTopologyPlan(sharedDisplaySide: .right)
    }
    throw DisplayControlError.state("旧快照无法确定 Philips 位于 Mac 主屏的哪一侧")
  }
}

/// The exact relationship between the two displays that remain on macOS.
/// It is captured only from the complete three-display baseline.
struct SoftKVMRemainingDisplayPlacement: Codable, Equatable, Sendable {
  let mainDisplayRole: DisplayRole
  let localDisplayRole: DisplayRole
  let localOffsetX: Int
  let localOffsetY: Int

  init(mainDisplay: DisplayRecord, localDisplay: DisplayRecord) {
    mainDisplayRole = mainDisplay.role
    localDisplayRole = localDisplay.role
    localOffsetX = localDisplay.originX - mainDisplay.originX
    localOffsetY = localDisplay.originY - mainDisplay.originY
  }

  func targetOrigin(
    mainDisplay: DisplayRecord,
    localDisplay: DisplayRecord,
    topologyPlan: SoftKVMTopologyPlan
  ) -> (x: Int, y: Int)? {
    guard mainDisplay.role == mainDisplayRole,
      localDisplay.role == localDisplayRole,
      (mainDisplayRole == .builtIn && localDisplayRole == .viewSonic)
        || (mainDisplayRole == .viewSonic && localDisplayRole == .builtIn),
      mainDisplay.width > 2,
      mainDisplay.height > 2,
      localDisplay.width > 2,
      localDisplay.height > 2
    else {
      return nil
    }
    let expectedOffsetX = topologyPlan.localDisplaySide == .left
      ? -localDisplay.width
      : mainDisplay.width
    guard ((expectedOffsetX - 2)...(expectedOffsetX + 2)).contains(localOffsetX) else {
      return nil
    }
    let (targetX, xOverflow) = mainDisplay.originX.addingReportingOverflow(localOffsetX)
    let (targetY, yOverflow) = mainDisplay.originY.addingReportingOverflow(localOffsetY)
    guard !xOverflow,
      !yOverflow,
      Int32(exactly: targetX) != nil,
      Int32(exactly: targetY) != nil
    else {
      return nil
    }
    let targetBottom = targetY + localDisplay.height
    let mainBottom = mainDisplay.originY + mainDisplay.height
    guard abs(targetBottom - mainBottom) <= 2 else { return nil }
    return (x: targetX, y: targetY)
  }

  func matches(
    mainDisplay: DisplayRecord,
    localDisplay: DisplayRecord,
    topologyPlan: SoftKVMTopologyPlan
  ) -> Bool {
    guard let target = targetOrigin(
      mainDisplay: mainDisplay,
      localDisplay: localDisplay,
      topologyPlan: topologyPlan
    ) else {
      return false
    }
    return localDisplay.originX == target.x && localDisplay.originY == target.y
  }
}

extension SoftDisconnectState {
  func resolvedTopologyPlan(
    currentMainDisplay: DisplayRecord
  ) throws -> SoftKVMTopologyPlan {
    if let topologyPlan {
      return topologyPlan
    }
    return try SoftKVMTopologyPlan.resolveLegacySnapshot(
      sharedDisplay: philips,
      currentMainDisplay: currentMainDisplay
    )
  }
}

struct SoftKVMMacBaseline: Sendable {
  let viewSonic: DisplayRecord
  let philips: DisplayRecord
  let mainDisplay: DisplayRecord
  let localDisplay: DisplayRecord
  let topologyPlan: SoftKVMTopologyPlan
  let remainingMacDisplayPlacement: SoftKVMRemainingDisplayPlacement

  static func resolve(_ displays: [DisplayRecord]) -> SoftKVMMacBaseline? {
    guard let identities = SoftKVMDisplayIdentities.resolve(displays),
      identities.builtIn.isActive,
      identities.viewSonic.isActive,
      identities.philips.isActive,
      !identities.philips.isMain,
      Set(displays.filter(\.isActive).map(\.runtimeID)) == identities.allRuntimeIDs,
      let mainDisplay = identities.macDisplays.only(where: \.isMain)
    else {
      return nil
    }
    let localDisplay = mainDisplay.role == .builtIn
      ? identities.viewSonic
      : identities.builtIn
    guard let localSide = HorizontalDisplayLayout.side(
      of: localDisplay,
      relativeTo: mainDisplay
    ),
      let sharedSide = HorizontalDisplayLayout.side(
        of: identities.philips,
        relativeTo: mainDisplay
      ),
      localSide == sharedSide.opposite,
      HorizontalDisplayLayout.bottomsAreAligned(
        [identities.builtIn, identities.viewSonic, identities.philips],
        with: mainDisplay
      )
    else {
      return nil
    }
    return SoftKVMMacBaseline(
      viewSonic: identities.viewSonic,
      philips: identities.philips,
      mainDisplay: mainDisplay,
      localDisplay: localDisplay,
      topologyPlan: SoftKVMTopologyPlan(sharedDisplaySide: sharedSide),
      remainingMacDisplayPlacement: SoftKVMRemainingDisplayPlacement(
        mainDisplay: mainDisplay,
        localDisplay: localDisplay
      )
    )
  }
}

/// The two Mac-owned displays in Windows mode, identified independently from
/// their temporary geometry so a broken layout can still be repaired safely.
struct SoftKVMWindowsDisplayPair: Sendable {
  let viewSonic: DisplayRecord
  let mainDisplay: DisplayRecord
  let localDisplay: DisplayRecord

  static func resolve(_ displays: [DisplayRecord]) -> SoftKVMWindowsDisplayPair? {
    guard let identities = SoftKVMDisplayIdentities.resolve(displays),
      identities.builtIn.isActive,
      identities.viewSonic.isActive,
      !identities.philips.isActive,
      !identities.philips.isMain,
      Set(displays.filter(\.isActive).map(\.runtimeID))
        == Set(identities.macDisplays.map(\.runtimeID)),
      let mainDisplay = identities.macDisplays.only(where: \.isMain)
    else {
      return nil
    }
    let localDisplay = mainDisplay.role == .builtIn
      ? identities.viewSonic
      : identities.builtIn
    return SoftKVMWindowsDisplayPair(
      viewSonic: identities.viewSonic,
      mainDisplay: mainDisplay,
      localDisplay: localDisplay
    )
  }
}

/// A repaired Windows-mode layout with a real horizontal seam.
struct SoftKVMWindowsTopology: Sendable {
  let viewSonic: DisplayRecord
  let mainDisplay: DisplayRecord
  let localDisplay: DisplayRecord
  let localDisplaySide: HorizontalDisplaySide

  static func resolve(_ displays: [DisplayRecord]) -> SoftKVMWindowsTopology? {
    guard let pair = SoftKVMWindowsDisplayPair.resolve(displays) else { return nil }
    guard let localDisplaySide = HorizontalDisplayLayout.side(
      of: pair.localDisplay,
      relativeTo: pair.mainDisplay
    ) else {
      return nil
    }
    return SoftKVMWindowsTopology(
      viewSonic: pair.viewSonic,
      mainDisplay: pair.mainDisplay,
      localDisplay: pair.localDisplay,
      localDisplaySide: localDisplaySide
    )
  }
}

private struct SoftKVMDisplayIdentities {
  let builtIn: DisplayRecord
  let viewSonic: DisplayRecord
  let philips: DisplayRecord

  var macDisplays: [DisplayRecord] {
    [builtIn, viewSonic]
  }

  var allRuntimeIDs: Set<UInt32> {
    Set([builtIn.runtimeID, viewSonic.runtimeID, philips.runtimeID])
  }

  static func resolve(_ displays: [DisplayRecord]) -> SoftKVMDisplayIdentities? {
    guard let builtIn = displays.only(where: { $0.role == .builtIn }),
      let viewSonic = displays.only(where: { $0.role == .viewSonic }),
      let philips = displays.only(where: { $0.role == .philips })
    else {
      return nil
    }
    return SoftKVMDisplayIdentities(
      builtIn: builtIn,
      viewSonic: viewSonic,
      philips: philips
    )
  }
}

private extension Collection {
  func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
    let matches = try filter(predicate)
    return matches.count == 1 ? matches[0] : nil
  }
}

private enum HorizontalDisplayLayout {
  private static let tolerance = 2

  static func side(
    of display: DisplayRecord,
    relativeTo mainDisplay: DisplayRecord
  ) -> HorizontalDisplaySide? {
    if isImmediatelyLeft(display, of: mainDisplay) {
      guard verticallyOverlaps(display, mainDisplay) else { return nil }
      return HorizontalDisplaySide.left
    }
    if isImmediatelyLeft(mainDisplay, of: display) {
      guard verticallyOverlaps(display, mainDisplay) else { return nil }
      return HorizontalDisplaySide.right
    }
    return nil
  }

  private static func isImmediatelyLeft(
    _ display: DisplayRecord,
    of mainDisplay: DisplayRecord
  ) -> Bool {
    abs(display.originX + display.width - mainDisplay.originX) <= tolerance
  }

  static func bottomsAreAligned(
    _ displays: [DisplayRecord],
    with reference: DisplayRecord
  ) -> Bool {
    let referenceBottom = reference.originY + reference.height
    return displays.allSatisfy {
      abs($0.originY + $0.height - referenceBottom) <= tolerance
    }
  }

  private static func verticallyOverlaps(
    _ first: DisplayRecord,
    _ second: DisplayRecord
  ) -> Bool {
    let overlap = min(
      first.originY + first.height,
      second.originY + second.height
    ) - max(first.originY, second.originY)
    return overlap > 1
  }
}
