import Foundation

extension CrossScreenMouseController {
    @MainActor
    func setSoftKVMTopologyPlan(_ topologyPlan: SoftKVMTopologyPlan?) {
        let changed = stateLock.withCriticalSection {
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
        stateLock.withCriticalSection {
            let wasEnabled = state.enabled
            state.enabled = enabled
            if enabled {
                state.runtimeFailure = nil
                if !wasEnabled { state.entryGate.arm() }
            } else {
                state.windowsRouteEnabled = false
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
            _ = localDisplayPortalTopology.restore()
            stopTapIfUnneededAndLocal()
            publishStatus()
        }
    }

    @MainActor
    @discardableResult
    func setRouteEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            stateLock.withCriticalSection { state.windowsRouteEnabled = false }
            releaseRemote(sendRelease: true, normalizedY: nil, reason: "soft KVM route disabled")
            return true
        }

        refreshDisplaysAndGeometry(forceWindowsRouteReset: false)
        guard prepareRoute() else {
            stateLock.withCriticalSection { state.windowsRouteEnabled = false }
            publishStatus()
            return false
        }
        let activeDisplays = CrossScreenDisplay.currentDisplays()
        guard !activeDisplays.isEmpty,
              let sharedDisplayID,
              !activeDisplays.contains(where: { $0.id == sharedDisplayID }) else {
            stateLock.withCriticalSection { state.windowsRouteEnabled = false }
            Self.logger.error(
                "Windows route refused because the shared display is still active in macOS"
            )
            publishStatus()
            return false
        }
        let currentGeometry = WindowsDisplayHandoffGeometry.resolve(
            sharedDisplayID: sharedDisplayID,
            topologyPlan: stateLock.withCriticalSection {
                state.softKVMTopologyPlan
            },
            displays: activeDisplays,
            allowsPortalRouting: localDisplayPortalTopology.routingOrderIDs(
                for: activeDisplays
            ) != nil
        )
        guard let currentGeometry,
              stateLock.withCriticalSection({ state.windowsGeometry == currentGeometry }) else {
            stateLock.withCriticalSection { state.windowsRouteEnabled = false }
            Self.logger.error(
                "Windows route refused because the display layout changed during validation"
            )
            publishStatus()
            return false
        }
        guard prioritizeInputTapsForRemoteRoute() else {
            stateLock.withCriticalSection { state.windowsRouteEnabled = false }
            publishStatus()
            return false
        }
        stateLock.withCriticalSection {
            state.windowsRouteEnabled = true
            state.entryGate.arm()
        }
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
            stateLock.withCriticalSection {
                state.windowsRouteEnabled = false
                state.runtimeFailure = "macOS 无法授权 Meno 在后台控制指针，跨屏路由保持关闭。"
            }
            publishStatus()
            return false
        }
        return true
    }

    @MainActor
    var routeReadinessFailure: String? {
        let stateFailure = stateLock.withCriticalSection { () -> String? in
            guard state.enabled else { return "Windows 输入服务已关闭。" }
            guard state.windowsGeometry != nil else {
                return "当前横向显示排列无法建立安全的穿屏入口。"
            }
            if let tapFailure = state.tapFailure { return tapFailure }
            if let runtimeFailure = state.runtimeFailure { return runtimeFailure }
            guard state.connection != nil else { return "正在等待 Windows 输入通道。" }
            guard state.directionalHandoffSupported else {
                return "Windows 输入程序不支持左右穿屏，请更新 Windows 端。"
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
        stateLock.withCriticalSection {
            state.softKVMShortcut = shortcut
            state.softKVMShortcutCapture.reset()
        }
    }

    @MainActor
    func setSoftKVMShortcutCaptureEnabled(_ enabled: Bool) {
        stateLock.withCriticalSection {
            state.softKVMShortcutCaptureEnabled = enabled
            state.softKVMShortcutCapture.reset()
        }
    }

    @MainActor
    var isLocallyOwned: Bool {
        stateLock.withCriticalSection { !state.mode.capturesInput }
    }

    @MainActor
    var remoteShutdownAvailable: Bool {
        stateLock.withCriticalSection {
            state.connection != nil && state.remoteShutdownSupported
        }
    }

    @MainActor
    func sendRemoteShutdown() async -> Bool {
        let connection = stateLock.withCriticalSection {
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
        stateLock.withCriticalSection {
            state.windowsRouteEnabled = false
            state.softKVMShortcutCapture.reset()
        }
    }
}
