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

  func originXForLocalDisplay(
    mainOriginX: Int,
    mainWidth: Int,
    localWidth: Int
  ) -> Int {
    localDisplaySide == .left
      ? mainOriginX - localWidth
      : mainOriginX + mainWidth
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
      localSide == sharedSide.opposite
    else {
      return nil
    }
    return SoftKVMMacBaseline(
      viewSonic: identities.viewSonic,
      philips: identities.philips,
      mainDisplay: mainDisplay,
      localDisplay: localDisplay,
      topologyPlan: SoftKVMTopologyPlan(sharedDisplaySide: sharedSide)
    )
  }
}

struct SoftKVMWindowsTopology: Sendable {
  let viewSonic: DisplayRecord
  let philips: DisplayRecord
  let mainDisplay: DisplayRecord
  let localDisplay: DisplayRecord
  let localDisplaySide: HorizontalDisplaySide

  static func resolve(_ displays: [DisplayRecord]) -> SoftKVMWindowsTopology? {
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
    guard let localDisplaySide = HorizontalDisplayLayout.side(
      of: localDisplay,
      relativeTo: mainDisplay
    ) else {
      return nil
    }
    return SoftKVMWindowsTopology(
      viewSonic: identities.viewSonic,
      philips: identities.philips,
      mainDisplay: mainDisplay,
      localDisplay: localDisplay,
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
  static func side(
    of display: DisplayRecord,
    relativeTo mainDisplay: DisplayRecord
  ) -> HorizontalDisplaySide? {
    if isImmediatelyLeft(display, of: mainDisplay) {
      guard verticallyOverlapsOrTouches(display, mainDisplay) else { return nil }
      return HorizontalDisplaySide.left
    }
    if isImmediatelyLeft(mainDisplay, of: display) {
      guard verticallyOverlapsOrTouches(display, mainDisplay) else { return nil }
      return HorizontalDisplaySide.right
    }
    return nil
  }

  private static func isImmediatelyLeft(
    _ display: DisplayRecord,
    of mainDisplay: DisplayRecord
  ) -> Bool {
    abs(display.originX + display.width - mainDisplay.originX) <= 2
  }

  private static func verticallyOverlapsOrTouches(
    _ first: DisplayRecord,
    _ second: DisplayRecord
  ) -> Bool {
    let overlap = min(
      first.originY + first.height,
      second.originY + second.height
    ) - max(first.originY, second.originY)
    return overlap > 1
      || abs(first.originY + first.height - second.originY) <= 2
      || abs(second.originY + second.height - first.originY) <= 2
  }
}
