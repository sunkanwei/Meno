import Foundation

extension CrossScreenMouseController {
    @MainActor
    func setSoftKVMTopologyPlan(_ topologyPlan: SoftKVMTopologyPlan?) {
        let changed = runtimeLock.withCriticalSection {
            guard state.softKVMTopologyPlan != topologyPlan else { return false }
            state.softKVMTopologyPlan = topologyPlan
            return true
        }
        if changed {
            refreshDisplaysAndGeometry()
        }
    }

    @MainActor
    func setEnabled(_ enabled: Bool) {
        runtimeLock.withCriticalSection {
            let wasEnabled = state.enabled
            state.enabled = enabled
            if enabled {
                state.runtimeFailure = nil
                if !wasEnabled { state.entryGate.arm() }
            } else {
                state.disableWindowsRoute()
                state.tapFailure = nil
                state.runtimeFailure = nil
            }
        }
        if enabled {
            refreshDisplaysAndGeometry()
        } else {
            releaseRemote(
                sendRelease: true,
                normalizedY: nil,
                reason: "feature disabled",
                forceStopMicrophone: true
            )
            cancelInputTapRestart()
            localDisplayRoutingTopology.reset()
            stopTapIfUnneededAndLocal()
            publishStatus()
        }
    }

    @MainActor
    @discardableResult
    func setRouteEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
            }
            releaseRemote(sendRelease: true, normalizedY: nil, reason: "soft KVM route disabled")
            return true
        }

        refreshDisplaysAndGeometry(forceWindowsRouteReset: false)
        guard prepareRoute() else {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
            }
            publishStatus()
            return false
        }
        let activeDisplays = CrossScreenDisplay.currentDisplays()
        guard !activeDisplays.isEmpty,
              let sharedDisplayID,
              !activeDisplays.contains(where: { $0.id == sharedDisplayID }) else {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
            }
            Self.logger.error(
                "Windows route refused because the shared display is still active in macOS"
            )
            publishStatus()
            return false
        }
        guard let topologyPlan = runtimeLock.withCriticalSection({
            state.softKVMTopologyPlan
        }) else {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
            }
            publishStatus()
            return false
        }
        let currentGeometry = WindowsDisplayHandoffGeometry.resolve(
            sharedDisplayID: sharedDisplayID,
            topologyPlan: topologyPlan,
            displays: activeDisplays,
            routingOrderIDs: localDisplayRoutingTopology.routingOrderIDs(
                for: activeDisplays
            )
        )
        guard let currentGeometry,
              runtimeLock.withCriticalSection({ state.windowsGeometry == currentGeometry }) else {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
            }
            Self.logger.error(
                "Windows route refused because the display layout changed during validation"
            )
            publishStatus()
            return false
        }
        guard prioritizeInputTapsForRemoteRoute() else {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
            }
            publishStatus()
            return false
        }
        let routeID = UInt64.random(in: 1...UInt64.max)
        let snapshot = KVMRouteSnapshot(
            routeID: routeID,
            sharedDisplayID: sharedDisplayID,
            topologyPlan: topologyPlan,
            geometry: currentGeometry
        )
        let enabledConnectionID = runtimeLock.withCriticalSection { () -> UUID? in
            guard state.windowsGeometry == currentGeometry,
                  state.routeContractSupported,
                  !state.ownership.capturesInput,
                  let connection = state.connection,
                  let screenMetrics = state.remoteScreenMetrics,
                  let route = snapshot.activate(
                      screenMetrics: screenMetrics,
                      configuration: state.displayHandoff.configuration
                ) else {
                state.disableWindowsRoute()
                return nil
            }
            state.enableWindowsRoute(snapshot: snapshot, route: route)
            return connection.id
        }
        guard let enabledConnectionID else {
            publishStatus()
            return false
        }
        Self.logger.notice(
            "Mouse route enabled connection=\(enabledConnectionID.uuidString, privacy: .public) route=\(routeID, privacy: .public) edge=\(currentGeometry.windowsEntryEdge.rawValue, privacy: .public)"
        )
        publishStatus()
        return true
    }

    @MainActor
    func prepareRoute() -> Bool {
        guard routeReadinessFailure == nil else {
            return false
        }
        let backgroundControl = MacCursorOwnership.prepareBackgroundControl()
        guard backgroundControl.succeeded else {
            runtimeLock.withCriticalSection {
                state.disableWindowsRoute()
                state.runtimeFailure = "macOS 无法授权 Meno 在后台控制指针，跨屏路由保持关闭。"
            }
            publishStatus()
            return false
        }
        return true
    }

    @MainActor
    var routeReadinessFailure: String? {
        let stateFailure = runtimeLock.withCriticalSection { () -> String? in
            guard state.enabled else { return "Windows 输入服务已关闭。" }
            guard state.windowsGeometry != nil else {
                return "当前横向显示排列无法建立安全的穿屏入口。"
            }
            if let tapFailure = state.tapFailure { return tapFailure }
            if let runtimeFailure = state.runtimeFailure { return runtimeFailure }
            guard state.connection != nil else { return "正在等待 Windows 输入通道。" }
            guard state.routeContractSupported else {
                return "Windows 输入程序不支持新版穿屏路由，请更新 Windows 端。"
            }
            guard !state.ownership.capturesInput else {
                return "Mac 输入所有权尚未恢复，不能建立新的穿屏路由。"
            }
            return nil
        }
        if let stateFailure { return stateFailure }
        guard inputTapsAreRunning else {
            return "跨屏输入监听当前不可用。"
        }
        return nil
    }

    @MainActor
    func setSoftKVMShortcut(_ shortcut: SoftKVMShortcut) {
        guard shortcut.isValid else { return }
        runtimeLock.withCriticalSection {
            state.softKVMShortcut = shortcut
            state.softKVMShortcutCapture.reset()
        }
    }

    @MainActor
    func setSoftKVMShortcutCaptureEnabled(_ enabled: Bool) {
        runtimeLock.withCriticalSection {
            state.softKVMShortcutCaptureEnabled = enabled
            state.softKVMShortcutCapture.reset()
        }
    }

    @MainActor
    var isLocallyOwned: Bool {
        runtimeLock.withCriticalSection { !state.ownership.capturesInput }
    }

    @MainActor
    var remoteShutdownAvailable: Bool {
        runtimeLock.withCriticalSection {
            state.connection != nil && state.remoteShutdownSupported
        }
    }

    @MainActor
    func sendRemoteShutdown() async -> Bool {
        let connection = runtimeLock.withCriticalSection {
            state.remoteShutdownSupported ? state.connection : nil
        }
        guard let connection else { return false }
        return await withCheckedContinuation { continuation in
            connection.sendRemoteShutdown { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
    }

    @MainActor
    func disableRouteAndResetShortcutCapture() {
        runtimeLock.withCriticalSection {
            state.disableWindowsRoute()
            state.softKVMShortcutCapture.reset()
        }
    }
}
