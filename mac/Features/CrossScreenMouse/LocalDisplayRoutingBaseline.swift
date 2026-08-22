import Foundation

/// The verified left-to-right order of the native three-display arrangement.
/// The order remains authoritative while the shared display is owned by
/// Windows and absent from macOS. It never changes the system display layout.
struct LocalDisplayRoutingBaseline: Codable, Equatable, Sendable {
    struct Origin: Codable, Equatable, Sendable {
        let displayID: String
        let x: Int32
        let y: Int32
    }

    private static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mainDisplayID: String
    let routingOrderIDs: [String]
    // Retained only to decode and validate the existing schema-1 preference.
    // These coordinates are never applied to the system display layout.
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
    ) -> LocalDisplayRoutingBaseline? {
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
        return LocalDisplayRoutingBaseline(
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
}
