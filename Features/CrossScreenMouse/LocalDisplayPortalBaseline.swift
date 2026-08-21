@preconcurrency import CoreGraphics
import Foundation

struct LocalDisplayPortalPlacement: Equatable, Sendable {
    let displayID: String
    let runtimeID: CGDirectDisplayID
    let x: Int32
    let y: Int32
}

/// A native three-display arrangement captured before the process applies its
/// private corner portals. The captured order remains authoritative while the
/// shared display is owned by Windows and absent from macOS.
struct LocalDisplayPortalBaseline: Codable, Equatable, Sendable {
    struct Origin: Codable, Equatable, Sendable {
        let displayID: String
        let x: Int32
        let y: Int32
    }

    private static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mainDisplayID: String
    let routingOrderIDs: [String]
    let originalOrigins: [Origin]

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              routingOrderIDs.count == 3,
              Set(routingOrderIDs).count == routingOrderIDs.count,
              routingOrderIDs[1] == mainDisplayID else {
            return false
        }
        let externalIDs = Set(routingOrderIDs.filter { $0 != mainDisplayID })
        return externalIDs == Set([
            FixedDisplayConfiguration.philipsUUID,
            FixedDisplayConfiguration.viewSonicUUID,
        ])
            && Set(originalOrigins.map(\.displayID)) == externalIDs
            && Set(originalOrigins.map(\.displayID)).count == originalOrigins.count
    }

    static func resolveNative(
        displays: [CrossScreenDisplay]
    ) -> LocalDisplayPortalBaseline? {
        let mainDisplays = displays.filter(\.isMain)
        guard displays.count == 3,
              Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({
                  $0.runtimeID != 0 && $0.supportsHorizontalHandoff
              }),
              mainDisplays.count == 1,
              let main = mainDisplays.first else {
            return nil
        }
        let ordered = displays.sorted { $0.frame.minX < $1.frame.minX }
        guard ordered[1].id == main.id,
              Set([ordered[0].id, ordered[2].id]) == Set([
                  FixedDisplayConfiguration.philipsUUID,
                  FixedDisplayConfiguration.viewSonicUUID,
              ]),
              ordered[0].isImmediatelyLeft(of: ordered[1]),
              ordered[1].isImmediatelyLeft(of: ordered[2]),
              displays.allSatisfy({
                  abs($0.frame.maxY - main.frame.maxY) <= 2
              }) else {
            return nil
        }
        return LocalDisplayPortalBaseline(
            schemaVersion: currentSchemaVersion,
            mainDisplayID: main.id,
            routingOrderIDs: ordered.map(\.id),
            originalOrigins: ordered.filter { !$0.isMain }.map {
                Origin(
                    displayID: $0.id,
                    x: Int32($0.frame.minX.rounded()),
                    y: Int32($0.frame.minY.rounded())
                )
            }
        )
    }

    func activeRoutingOrderIDs(
        for displays: [CrossScreenDisplay]
    ) -> [String]? {
        guard isValid, (2...routingOrderIDs.count).contains(displays.count) else {
            return nil
        }
        let activeIDs = Set(displays.map(\.id))
        let order = routingOrderIDs.filter(activeIDs.contains)
        guard order.count == displays.count,
              Set(displays.map(\.id)).count == displays.count,
              activeIDs.contains(mainDisplayID) else {
            return nil
        }
        return order
    }

    func technicalPlacements(
        for displays: [CrossScreenDisplay]
    ) -> [LocalDisplayPortalPlacement]? {
        guard let order = activeRoutingOrderIDs(for: displays),
              displays.allSatisfy({
                  $0.runtimeID != 0 && $0.supportsHorizontalHandoff
              }),
              let main = displays.first(where: {
                  $0.id == mainDisplayID && $0.isMain
              }),
              let mainIndex = order.firstIndex(of: main.id) else {
            return nil
        }
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        return order.enumerated().compactMap { index, displayID in
            guard displayID != main.id, let display = displaysByID[displayID] else {
                return nil
            }
            let isLeft = index < mainIndex
            return LocalDisplayPortalPlacement(
                displayID: display.id,
                runtimeID: display.runtimeID,
                x: Int32((isLeft
                    ? main.frame.minX - display.frame.width
                    : main.frame.maxX).rounded()),
                y: Int32((main.frame.minY - display.frame.height).rounded())
            )
        }
    }

    func originalPlacements(
        for displays: [CrossScreenDisplay]
    ) -> [LocalDisplayPortalPlacement]? {
        guard isValid,
              Set(displays.map(\.id)).count == displays.count else {
            return nil
        }
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        return originalOrigins.compactMap { origin in
            guard let display = displaysByID[origin.displayID],
                  display.runtimeID != 0 else {
                return nil
            }
            return LocalDisplayPortalPlacement(
                displayID: display.id,
                runtimeID: display.runtimeID,
                x: origin.x,
                y: origin.y
            )
        }
    }

    func verifiedOriginalPlacements(
        for displays: [CrossScreenDisplay]
    ) -> [LocalDisplayPortalPlacement]? {
        guard let order = activeRoutingOrderIDs(for: displays),
              let placements = originalPlacements(for: displays),
              placements.count == displays.count - 1 else {
            return nil
        }
        let placementsByID = Dictionary(uniqueKeysWithValues: placements.map {
            ($0.displayID, $0)
        })
        let restoredDisplays = displays.map { display in
            guard let placement = placementsByID[display.id] else {
                return display
            }
            return CrossScreenDisplay(
                id: display.id,
                runtimeID: display.runtimeID,
                name: display.name,
                frame: CGRect(
                    x: CGFloat(placement.x),
                    y: CGFloat(placement.y),
                    width: display.frame.width,
                    height: display.frame.height
                ),
                physicalHeightMM: display.physicalHeightMM,
                isMain: display.isMain,
                rotationDegrees: display.rotationDegrees,
                isMirrored: display.isMirrored
            )
        }
        let orderedDisplays = restoredDisplays.sorted {
            $0.frame.minX < $1.frame.minX
        }
        guard orderedDisplays.map(\.id) == order,
              let main = restoredDisplays.first(where: {
                  $0.id == mainDisplayID && $0.isMain
              }),
              restoredDisplays.allSatisfy(\.supportsHorizontalHandoff),
              zip(orderedDisplays, orderedDisplays.dropFirst()).allSatisfy({ pair in
                  pair.0.isImmediatelyLeft(of: pair.1)
              }),
              restoredDisplays.allSatisfy({
                  abs($0.frame.maxY - main.frame.maxY) <= 2
              }) else {
            return nil
        }
        return placements
    }

    func permanentOriginalPlacements(
        for displays: [CrossScreenDisplay]
    ) -> [LocalDisplayPortalPlacement]? {
        guard displays.count == routingOrderIDs.count else { return nil }
        return verifiedOriginalPlacements(for: displays)
    }
}
