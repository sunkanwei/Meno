@preconcurrency import CoreGraphics
import Foundation

@MainActor
final class LocalDisplayRoutingTopology {
    // Keep the existing key so installations upgraded from the portal-based
    // implementation retain their already verified native routing baseline.
    private static let baselinePreferenceKey = "LocalDisplayPortalBaseline"
    private let defaults: UserDefaults
    private var activeBaseline: LocalDisplayRoutingBaseline?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func routingOrderIDs(for displays: [CrossScreenDisplay]) -> [String]? {
        activeBaseline?.activeRoutingOrderIDs(for: displays)
    }

    func reset() {
        activeBaseline = nil
    }

    func reconcile(enabled: Bool, displays: [CrossScreenDisplay]) {
        guard enabled else {
            activeBaseline = nil
            return
        }
        if displays.count == 3 {
            guard let nativeBaseline = LocalDisplayRoutingBaseline.resolveNative(
                displays: displays
            ) else {
                activeBaseline = nil
                CrossScreenMouseController.logger.error(
                    "Local display routing refused because the complete layout is not the verified native arrangement"
                )
                return
            }
            let changed = activeBaseline != nativeBaseline
            if changed { save(baseline: nativeBaseline) }
            activeBaseline = nativeBaseline
            return
        }
        if let activeBaseline,
           activeBaseline.activeRoutingOrderIDs(for: displays) != nil {
            return
        }
        let baseline: LocalDisplayRoutingBaseline?
        if let savedBaseline = loadSavedBaseline(),
           savedBaseline.activeRoutingOrderIDs(for: displays) != nil {
            baseline = savedBaseline
        } else {
            baseline = nil
        }
        guard let baseline else {
            activeBaseline = nil
            CrossScreenMouseController.logger.error(
                "Local display routing refused because no verified native three-display baseline is available"
            )
            return
        }
        activeBaseline = baseline
    }

    private func loadSavedBaseline() -> LocalDisplayRoutingBaseline? {
        guard let data = defaults.data(forKey: Self.baselinePreferenceKey),
              let baseline = try? JSONDecoder().decode(
                  LocalDisplayRoutingBaseline.self,
                  from: data
              ),
              baseline.isValid else {
            return nil
        }
        return baseline
    }

    private func save(baseline: LocalDisplayRoutingBaseline) {
        guard let data = try? JSONEncoder().encode(baseline) else { return }
        defaults.set(data, forKey: Self.baselinePreferenceKey)
    }
}

private struct CrossScreenGeometrySnapshot {
    let windows: WindowsDisplayHandoffGeometry?
    let local: HorizontalDisplayHandoffGeometry?
    let sharedDisplayIsVisible: Bool
}

extension CrossScreenMouseController {
    @MainActor
    func refreshDisplaysAndGeometry(forceWindowsRouteReset: Bool = true) {
        let displays = CrossScreenDisplay.currentDisplays()
        let featureState = runtimeLock.withCriticalSection {
            (
                enabled: state.enabled,
                localHandoffEnabled: state.enabled
                    && state.displayHandoff.configuration.enabled
            )
        }
        localDisplayRoutingTopology.reconcile(
            enabled: featureState.enabled,
            displays: displays
        )
        let snapshot = resolvedDisplayGeometries(
            displays: displays,
            localHandoffEnabled: featureState.localHandoffEnabled
        )
        let windowsGeometry = snapshot.windows
        let displayHandoffGeometry = snapshot.local
        let sharedDisplayIsVisible = snapshot.sharedDisplayIsVisible
        let changes = runtimeLock.withCriticalSection {
            let displayGeometryChanged = state.displayHandoff.geometry
                != displayHandoffGeometry
            let windowsGeometryChanged = state.windowsGeometry != windowsGeometry
            return (
                shouldResetWindowsRoute: forceWindowsRouteReset
                    || windowsGeometryChanged
                    || displayGeometryChanged,
                sharedDisplayReappeared: state.windowsRouteEnabled
                    && sharedDisplayIsVisible
            )
        }
        if changes.shouldResetWindowsRoute {
            if runtimeLock.withCriticalSection({ state.ownership.capturesInput }) {
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
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
                state.updateDisplayGeometries(
                    windows: windowsGeometry,
                    displayHandoff: displayHandoffGeometry,
                    pointerLocation: state.ownership.capturesInput ? nil : pointerLocation
                )
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
    private func resolvedDisplayGeometries(
        displays: [CrossScreenDisplay],
        localHandoffEnabled: Bool
    ) -> CrossScreenGeometrySnapshot {
        let routingOrderIDs = localDisplayRoutingTopology.routingOrderIDs(
            for: displays
        )
        let topologyPlan = runtimeLock.withCriticalSection {
            state.softKVMTopologyPlan
        }
        return CrossScreenGeometrySnapshot(
            windows: WindowsDisplayHandoffGeometry.resolve(
                sharedDisplayID: sharedDisplayID,
                topologyPlan: topologyPlan,
                displays: displays,
                routingOrderIDs: routingOrderIDs
            ),
            local: localHandoffEnabled ? routingOrderIDs.flatMap {
                HorizontalDisplayHandoffGeometry.resolve(
                    displays: displays,
                    routingOrderIDs: $0
                )
            } : nil,
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
        let transition = runtimeLock.withCriticalSection {
            () -> (changed: Bool, shouldRecover: Bool) in
            guard state.displayHandoff.updateConfiguration(
                configuration,
                pointerLocation: state.ownership.capturesInput ? nil : pointerLocation
            ) else {
                return (false, false)
            }
            return (true, state.ownership.capturesInput)
        }
        if transition.shouldRecover {
            recoverLocalImmediately(
                sendRelease: true,
                reason: "display handoff configuration changed"
            )
        }
        if transition.changed {
            refreshDisplaysAndGeometry()
        }
    }
}
