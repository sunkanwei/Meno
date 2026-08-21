@preconcurrency import CoreGraphics
import Foundation
import OSLog

@MainActor
final class LocalDisplayPortalTopology {
    private static let baselinePreferenceKey = "LocalDisplayPortalBaseline"
    private let defaults: UserDefaults
    private var activeBaseline: LocalDisplayPortalBaseline?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func routingOrderIDs(for displays: [CrossScreenDisplay]) -> [String]? {
        activeBaseline?.activeRoutingOrderIDs(for: displays)
    }

    @discardableResult
    func reconcile(enabled: Bool, displays: [CrossScreenDisplay]) -> Bool {
        guard enabled else { return restore(displays: displays) }
        let wasInactive = activeBaseline == nil
        let baseline: LocalDisplayPortalBaseline
        let loadedSavedBaseline: Bool
        if let activeBaseline {
            baseline = activeBaseline
            loadedSavedBaseline = false
        } else if let nativeBaseline = LocalDisplayPortalBaseline.resolveNative(
            displays: displays
        ) {
            baseline = nativeBaseline
            loadedSavedBaseline = false
            save(baseline: nativeBaseline)
        } else {
            guard let savedBaseline = loadSavedBaseline() else {
                CrossScreenMouseController.logger.error(
                    "Local display portal refused because no verified bottom-aligned three-display baseline is available"
                )
                return false
            }
            baseline = savedBaseline
            loadedSavedBaseline = true
        }
        guard let origins = baseline.technicalPlacements(for: displays) else {
            if activeBaseline != nil {
                _ = restore(displays: displays)
            }
            CrossScreenMouseController.logger.error(
                "Local display portal refused because active displays do not match the verified baseline"
            )
            return false
        }
        if wasInactive,
           loadedSavedBaseline,
           Self.matches(origins: origins, displays: displays) {
            guard let nativeOrigins = baseline.verifiedOriginalPlacements(
                for: displays
            ) else {
                CrossScreenMouseController.logger.error(
                    "Local display portal refused because the saved native layout is invalid"
                )
                return false
            }
            let nativeOption: CGConfigureOption = displays.count
                == baseline.routingOrderIDs.count ? .permanently : .forSession
            guard Self.apply(origins: nativeOrigins, option: nativeOption) else {
                CrossScreenMouseController.logger.error(
                    "Local display portal could not restore the native base layout"
                )
                return false
            }
            guard Self.apply(origins: origins, option: .forAppOnly) else {
                CrossScreenMouseController.logger.error(
                    "Local display portal could not reapply the temporary technical layout"
                )
                return true
            }
            activeBaseline = baseline
            let scope = nativeOption == .permanently ? "permanent" : "session"
            CrossScreenMouseController.logger.info(
                "Local display portal repaired the native base layout scope=\(scope, privacy: .public)"
            )
            return true
        }
        if Self.matches(origins: origins, displays: displays) {
            if wasInactive { activeBaseline = baseline }
            return false
        }
        guard Self.apply(origins: origins, option: .forAppOnly) else {
            CrossScreenMouseController.logger.error(
                "Local display portal could not apply the technical layout"
            )
            return false
        }
        activeBaseline = baseline
        let activeIDs = Set(displays.map(\.id))
        let order = baseline.routingOrderIDs
            .filter(activeIDs.contains)
            .joined(separator: "->")
        CrossScreenMouseController.logger.info(
            "Local display portal reconciled order=\(order, privacy: .public)"
        )
        return true
    }

    @discardableResult
    func restore(displays: [CrossScreenDisplay] = CrossScreenDisplay.currentDisplays()) -> Bool {
        guard let activeBaseline else {
            return false
        }
        let permanentOrigins = activeBaseline.permanentOriginalPlacements(for: displays)
        let verifiedOrigins = permanentOrigins
            ?? activeBaseline.verifiedOriginalPlacements(for: displays)
        guard let origins = verifiedOrigins
                ?? activeBaseline.originalPlacements(for: displays) else {
            return false
        }
        let option: CGConfigureOption
        let scope: String
        if permanentOrigins != nil {
            option = .permanently
            scope = "permanent"
        } else if verifiedOrigins != nil {
            option = .forSession
            scope = "session"
        } else {
            option = .forAppOnly
            scope = "application"
        }
        guard origins.isEmpty || Self.apply(origins: origins, option: option) else {
            CrossScreenMouseController.logger.error(
                "Local display portal could not restore the native layout"
            )
            return false
        }
        self.activeBaseline = nil
        CrossScreenMouseController.logger.info(
            "Local display portal restored the native layout scope=\(scope, privacy: .public)"
        )
        return true
    }

    private static func matches(
        origins: [LocalDisplayPortalPlacement],
        displays: [CrossScreenDisplay]
    ) -> Bool {
        origins.allSatisfy { origin in
            guard let display = displays.first(where: { $0.id == origin.displayID }) else {
                return false
            }
            return abs(display.frame.minX - CGFloat(origin.x)) < 0.5
                && abs(display.frame.minY - CGFloat(origin.y)) < 0.5
        }
    }

    private func loadSavedBaseline() -> LocalDisplayPortalBaseline? {
        guard let data = defaults.data(forKey: Self.baselinePreferenceKey),
              let baseline = try? JSONDecoder().decode(
                  LocalDisplayPortalBaseline.self,
                  from: data
              ),
              baseline.isValid else {
            return nil
        }
        return baseline
    }

    private func save(baseline: LocalDisplayPortalBaseline) {
        guard let data = try? JSONEncoder().encode(baseline) else { return }
        defaults.set(data, forKey: Self.baselinePreferenceKey)
    }

    private static func apply(
        origins: [LocalDisplayPortalPlacement],
        option: CGConfigureOption
    ) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success,
              let configuration else {
            return false
        }
        for origin in origins {
            guard CGConfigureDisplayOrigin(
                configuration,
                origin.runtimeID,
                origin.x,
                origin.y
            ) == .success else {
                CGCancelDisplayConfiguration(configuration)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(configuration, option) == .success
    }
}

private struct CrossScreenGeometrySnapshot {
    let displays: [CrossScreenDisplay]
    let windows: WindowsDisplayHandoffGeometry?
    let local: HorizontalDisplayHandoffGeometry?
    let sharedDisplayIsVisible: Bool
}

extension CrossScreenMouseController {
    @MainActor
    func refreshDisplaysAndGeometry(forceWindowsRouteReset: Bool = true) {
        let portalEnabled = stateLock.withCriticalSection {
            state.enabled && state.displayHandoff.configuration.enabled
        }
        _ = localDisplayPortalTopology.reconcile(
            enabled: portalEnabled,
            displays: CrossScreenDisplay.currentDisplays()
        )
        let snapshot = resolvedDisplayGeometries()
        let displays = snapshot.displays
        let windowsGeometry = snapshot.windows
        let displayHandoffGeometry = snapshot.local
        let sharedDisplayIsVisible = snapshot.sharedDisplayIsVisible
        let changes = stateLock.withCriticalSection {
            let displayGeometryChanged = state.displayHandoff.geometry
                != displayHandoffGeometry
            let windowsGeometryChanged = state.windowsGeometry != windowsGeometry
            return (
                shouldResetWindowsRoute: forceWindowsRouteReset
                    || windowsGeometryChanged
                    || displayGeometryChanged,
                windowsGeometryChanged: windowsGeometryChanged,
                displayGeometryChanged: displayGeometryChanged,
                sharedDisplayReappeared: state.windowsRouteEnabled
                    && sharedDisplayIsVisible
            )
        }
        if changes.shouldResetWindowsRoute {
            if stateLock.withCriticalSection({ state.mode.capturesInput }) {
                releaseRemote(
                    sendRelease: true,
                    normalizedY: nil,
                    reason: changes.sharedDisplayReappeared
                        ? "shared display reappeared"
                        : "display geometry changed",
                    restoreImmediately: true
                )
            }
            let pointerLocation = MacCursorOwnership.currentLocation()
            stateLock.withCriticalSection {
                state.windowsRouteEnabled = false
                state.updateDisplayGeometries(
                    windows: windowsGeometry,
                    displayHandoff: displayHandoffGeometry,
                    pointerLocation: state.mode.capturesInput ? nil : pointerLocation
                )
            }
            if changes.displayGeometryChanged {
                logDisplayHandoffGeometry(displayHandoffGeometry, displays: displays)
            }
            if changes.windowsGeometryChanged {
                logWindowsGeometry(windowsGeometry)
            }
            if changes.sharedDisplayReappeared {
                Self.logger.error(
                    "Windows route disabled because the shared display reappeared in macOS"
                )
            }
        }
        startTapIfNeeded()
    }

    @MainActor
    private func resolvedDisplayGeometries() -> CrossScreenGeometrySnapshot {
        let displays = CrossScreenDisplay.currentDisplays()
        let portalRoutingOrderIDs = localDisplayPortalTopology.routingOrderIDs(
            for: displays
        )
        let topologyPlan = stateLock.withCriticalSection {
            state.softKVMTopologyPlan
        }
        return CrossScreenGeometrySnapshot(
            displays: displays,
            windows: WindowsDisplayHandoffGeometry.resolve(
                sharedDisplayID: sharedDisplayID,
                topologyPlan: topologyPlan,
                displays: displays,
                allowsPortalRouting: portalRoutingOrderIDs != nil
            ),
            local: portalRoutingOrderIDs.flatMap {
                HorizontalDisplayHandoffGeometry.resolve(
                    displays: displays,
                    routingOrderIDs: $0
                )
            },
            sharedDisplayIsVisible: sharedDisplayID.map { sharedID in
                displays.contains(where: { $0.id == sharedID })
            } ?? false
        )
    }

    @MainActor
    func setDisplayHandoffConfiguration(
        _ configuration: DisplayHandoffConfiguration
    ) {
        // Existing Windows sessions keep their frozen configuration. Updating
        // this state atomically prevents a released session from re-entering
        // with the superseded setting before local ownership is restored.
        let pointerLocation = MacCursorOwnership.currentLocation()
        let transition = stateLock.withCriticalSection {
            () -> (changed: Bool, shouldRecover: Bool) in
            guard state.displayHandoff.updateConfiguration(
                configuration,
                pointerLocation: state.mode.capturesInput ? nil : pointerLocation
            ) else {
                return (false, false)
            }
            return (true, state.mode.capturesInput)
        }
        if transition.shouldRecover {
            recoverLocalImmediately(
                sendRelease: true,
                reason: "display handoff configuration changed"
            )
        }
        if transition.changed {
            refreshDisplaysAndGeometry()
            let description = "enabled=\(configuration.enabled) "
                + "alignment=\(configuration.alignment.rawValue)"
            Self.logger.info(
                "Display handoff configuration changed \(description, privacy: .public)"
            )
        }
    }

    private func logDisplayHandoffGeometry(
        _ geometry: HorizontalDisplayHandoffGeometry?,
        displays: [CrossScreenDisplay]
    ) {
        guard let geometry else {
            let description = displays.map(Self.displayLogDescription).joined(separator: " | ")
            Self.logger.info(
                "Display handoff unavailable displays=\(description, privacy: .public)"
            )
            return
        }
        let displayDescription = geometry.displays.map(Self.displayLogDescription)
            .joined(separator: " | ")
        let seamDescription = geometry.seams.map {
            "\($0.leftDisplay.id)->\($0.rightDisplay.id)@\($0.seamX)"
        }.joined(separator: ",")
        let description = "displays=\(displayDescription) seams=\(seamDescription)"
        Self.logger.info("Display handoff ready \(description, privacy: .public)")
    }

    private func logWindowsGeometry(_ geometry: WindowsDisplayHandoffGeometry?) {
        guard let geometry else {
            Self.logger.info("Windows display handoff unavailable")
            return
        }
        let description = "display=\(geometry.macDisplay.name) "
            + "macEdge=\(geometry.macEdge) windowsEdge=\(geometry.windowsEntryEdge) "
            + "source=three-display-baseline"
        Self.logger.info("Windows display handoff ready \(description, privacy: .public)")
    }

    private static func displayLogDescription(_ display: CrossScreenDisplay) -> String {
        let height = display.physicalHeightMM.map(String.init(describing:)) ?? "unknown"
        return "\(display.name) id=\(display.id) frame=\(display.frame) heightMM=\(height)"
    }
}
