import Foundation

@MainActor
extension SoftKVMCoordinator {
    func beginDisable() {
        perform(status: .switchingToMac) { [weak self] operationID in
            guard let self else { return }
            try await returnToMacIfNeeded(operationID: operationID)
            try requireCurrentOperation(operationID)
            guard updateState({ $0.completeDisable(operationID: operationID) }) else {
                return
            }
            setMouseServiceEnabled(false)
            onEnabledStateChanged(false)
        }
    }

    func beginForceShutdown(onFailure: @escaping (String) -> Void) {
        guard canForceShutdownWindows else {
            onFailure(SoftKVMCoordinatorError.remoteShutdownUnavailable.localizedDescription)
            return
        }
        remoteShutdownInProgress = true
        perform(
            status: .switchingToMac,
            onFailure: onFailure,
            onFinish: { [weak self] in self?.remoteShutdownInProgress = false }
        ) { [weak self] operationID in
            guard let self else { return }
            try requireCurrentOperation(operationID)
            guard await crossScreenMouse.sendRemoteShutdown() else {
                throw SoftKVMCoordinatorError.remoteShutdownSendFailed
            }
            try requireCurrentOperation(operationID)
            let clock = ContinuousClock()
            let displaySwitchDeadline = clock.now.advanced(by: .seconds(3))
            crossScreenMouse.prepareForSystemTransition()
            do {
                if !preparedState {
                    try await displaySwitch.prepareState()
                    try requireCurrentOperation(operationID)
                    preparedState = true
                }
                try await clock.sleep(until: displaySwitchDeadline)
                try requireCurrentOperation(operationID)
                try await displaySwitch.toMac()
                try requireCurrentOperation(operationID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw SoftKVMCoordinatorError.remoteShutdownReturnToMacFailed(
                    error.localizedDescription
                )
            }
            setStatus(stableMacStatus(), operationID: operationID)
        }
    }

    func switchToWindows() {
        guard let expectedReadiness = readiness else {
            setStatus(stableMacStatus())
            return
        }
        perform(status: .switchingToWindows) { [weak self] operationID in
            guard let self else { return }
            try requireCurrentOperation(operationID)
            try requireInputPermissions()
            guard await waitForLocalOwnership() else {
                throw SoftKVMCoordinatorError.inputStillHeld
            }
            try requireCurrentOperation(operationID)
            guard await SoftKVMInputQuiescence.wait(for: shortcut) else {
                throw SoftKVMCoordinatorError.inputStillHeld
            }
            try requireCurrentOperation(operationID)
            guard readiness == expectedReadiness else {
                throw SoftKVMCoordinatorError.staleWindowsConnection
            }
            guard crossScreenMouse.prepareRoute() else {
                throw SoftKVMCoordinatorError.routeUnavailable
            }

            try await displaySwitch.toWindows()
            try requireCurrentOperation(operationID)
            guard stateMachine.routeMayBeEnabled else {
                await updateStatusAfterFailure(
                    "系统会话当前不允许接管输入。",
                    operationID: operationID
                )
                return
            }
            guard readiness == expectedReadiness else {
                setStatus(
                    .windowsWaiting(
                        reason: SoftKVMCoordinatorError.staleWindowsConnection.localizedDescription
                    ),
                    operationID: operationID
                )
                return
            }
            guard applyRouteEnabled(true) else {
                setStatus(
                    .windowsWaiting(reason: routeUnavailableReason),
                    operationID: operationID
                )
                return
            }
            setStatus(
                .windowsReady(remoteName: expectedReadiness.remoteName),
                operationID: operationID
            )
        }
    }

    func switchToMac() {
        perform(status: .switchingToMac) { [weak self] operationID in
            guard let self else { return }
            try await returnToMacIfNeeded(operationID: operationID)
            try requireCurrentOperation(operationID)
            setStatus(stableMacStatus(), operationID: operationID)
        }
    }

    func recoverToMac() {
        perform(status: .switchingToMac) { [weak self] operationID in
            guard let self else { return }
            crossScreenMouse.prepareForSystemTransition()
            guard await SoftKVMInputQuiescence.wait(for: shortcut) else {
                throw SoftKVMCoordinatorError.inputStillHeld
            }
            try requireCurrentOperation(operationID)
            try await displaySwitch.recover()
            try requireCurrentOperation(operationID)
            setStatus(stableMacStatus(), operationID: operationID)
        }
    }

    func refresh(allowAutomaticRecovery: Bool) {
        perform(status: .checking) { [weak self] operationID in
            guard let self else { return }
            var inspection = try await inspectPreparedState(operationID: operationID)
            if inspection.hasTransaction
                || (inspection.report.topology == .mac && inspection.hasRecoveryState) {
                guard allowAutomaticRecovery else {
                    setStatus(
                        .recoveryNeeded(reason: "检测到未完成事务，请恢复到 Mac。"),
                        operationID: operationID
                    )
                    return
                }
                try await displaySwitch.recover()
                try requireCurrentOperation(operationID)
                inspection = try await displaySwitch.inspect()
                try requireCurrentOperation(operationID)
            }
            applyStableInspection(inspection, operationID: operationID)
        }
    }

    private func returnToMacIfNeeded(operationID: UInt64) async throws {
        try requireCurrentOperation(operationID)
        if !(await waitForLocalOwnership()) {
            try requireCurrentOperation(operationID)
            crossScreenMouse.prepareForSystemTransition()
        }
        try requireCurrentOperation(operationID)
        guard await SoftKVMInputQuiescence.wait(for: shortcut) else {
            throw SoftKVMCoordinatorError.inputStillHeld
        }
        try requireCurrentOperation(operationID)
        let inspection = try await inspectPreparedState(operationID: operationID)
        if inspection.report.topology == .mac, !inspection.hasRecoveryState {
            return
        }
        try await displaySwitch.toMac()
        try requireCurrentOperation(operationID)
    }

    private func inspectPreparedState(
        operationID: UInt64
    ) async throws -> DisplaySwitchInspection {
        try requireCurrentOperation(operationID)
        if !preparedState {
            try await displaySwitch.prepareState()
            try requireCurrentOperation(operationID)
            preparedState = true
        }
        try await displaySwitch.stabilizeWindowsTopology()
        try requireCurrentOperation(operationID)
        let inspection = try await displaySwitch.inspect()
        try requireCurrentOperation(operationID)
        return inspection
    }

    private func applyStableInspection(
        _ inspection: DisplaySwitchInspection,
        operationID: UInt64
    ) {
        guard stateMachine.isCurrentOperation(operationID) else { return }
        crossScreenMouse.setSoftKVMTopologyPlan(inspection.topologyPlan)
        switch inspection.report.topology {
        case .mac:
            guard inspection.report.passed,
                  inspection.topologyPlan != nil,
                  !inspection.hasRecoveryState else {
                setStatus(
                    .recoveryNeeded(reason: "Mac 显示拓扑或窗口恢复状态尚未收敛。"),
                    operationID: operationID
                )
                applyRouteEnabled(false)
                return
            }
            setStatus(stableMacStatus(), operationID: operationID)
            applyRouteEnabled(false)
        case .windows:
            guard inspection.hasSoftDisconnectState,
                  inspection.topologyPlan != nil,
                  !inspection.hasTransaction else {
                setStatus(
                    .recoveryNeeded(reason: "Windows 两屏拓扑缺少有效的 Philips 恢复快照。"),
                    operationID: operationID
                )
                applyRouteEnabled(false)
                return
            }
            guard stateMachine.routeMayBeEnabled else {
                setStatus(
                    .windowsWaiting(reason: "Mac 用户会话当前未激活。"),
                    operationID: operationID
                )
                applyRouteEnabled(false)
                return
            }
            guard let readiness else {
                setStatus(
                    .windowsWaiting(reason: stateMachine.mouseUnavailableReason),
                    operationID: operationID
                )
                applyRouteEnabled(false)
                return
            }

            setStatus(.switchingToWindows, operationID: operationID)
            guard applyRouteEnabled(true) else {
                setStatus(
                    .windowsWaiting(reason: routeUnavailableReason),
                    operationID: operationID
                )
                return
            }
            setStatus(
                .windowsReady(remoteName: readiness.remoteName),
                operationID: operationID
            )
        case .unknown:
            setStatus(
                .recoveryNeeded(reason: "当前显示拓扑不是安全的 Mac 或 Windows 终态。"),
                operationID: operationID
            )
            applyRouteEnabled(false)
        }
    }

    private func requireInputPermissions() throws {
        guard AccessibilityPermission.canReadAccessibility,
              AccessibilityPermission.canPostEvents else {
            throw SoftKVMCoordinatorError.permission("尚未授予完整辅助功能权限。")
        }
        guard AccessibilityPermission.canListenToKeyboard else {
            throw SoftKVMCoordinatorError.permission("尚未授予输入监听权限。")
        }
    }

    private func waitForLocalOwnership(
        timeout: Duration = .milliseconds(800)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            if crossScreenMouse.isLocallyOwned { return true }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return false
            }
        }
        return crossScreenMouse.isLocallyOwned
    }

    private func stableMacStatus() -> SoftKVMStatus {
        if let readiness {
            if let failure = crossScreenMouse.routeReadinessFailure {
                return .macWaiting(reason: failure)
            }
            return .macReady(remoteName: readiness.remoteName)
        }
        return .macWaiting(reason: stateMachine.mouseUnavailableReason)
    }

    private var routeUnavailableReason: String {
        crossScreenMouse.routeReadinessFailure
            ?? SoftKVMCoordinatorError.routeUnavailable.localizedDescription
    }

    private func perform(
        status pendingStatus: SoftKVMStatus,
        onFailure: ((String) -> Void)? = nil,
        onFinish: (() -> Void)? = nil,
        operation: @escaping @MainActor (UInt64) async throws -> Void
    ) {
        guard !stateMachine.operationInProgress else { return }
        nextOperationID &+= 1
        let operationID = nextOperationID
        guard updateState({
            $0.beginOperation(id: operationID, status: pendingStatus)
        }) else { return }
        applyRouteEnabled(false)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation(operationID)
                try requireCurrentOperation(operationID)
            } catch is CancellationError {
                guard stateMachine.isCurrentOperation(operationID) else { return }
                setStatus(
                    .recoveryNeeded(reason: "操作已取消，保留恢复状态。"),
                    operationID: operationID
                )
                applyRouteEnabled(false)
                await updateStatusAfterFailure(
                    "操作已取消，保留恢复状态。",
                    operationID: operationID
                )
            } catch {
                guard stateMachine.isCurrentOperation(operationID) else { return }
                Self.logger.error(
                    "Soft KVM operation failed: \(error.localizedDescription, privacy: .public)"
                )
                setStatus(
                    .recoveryNeeded(reason: error.localizedDescription),
                    operationID: operationID
                )
                applyRouteEnabled(false)
                await updateStatusAfterFailure(
                    error.localizedDescription,
                    operationID: operationID
                )
                onFailure?(error.localizedDescription)
            }
            guard updateState({ $0.finishOperation(id: operationID) }) else { return }
            operationTask = nil
            onFinish?()
        }
    }

    private func updateStatusAfterFailure(
        _ reason: String,
        operationID: UInt64
    ) async {
        guard stateMachine.isCurrentOperation(operationID) else { return }
        do {
            let inspection = try await inspectPreparedState(operationID: operationID)
            switch inspection.report.topology {
            case .mac where inspection.report.passed && !inspection.hasRecoveryState:
                setStatus(stableMacStatus(), operationID: operationID)
            case .windows where inspection.hasSoftDisconnectState && !inspection.hasTransaction:
                setStatus(.windowsWaiting(reason: reason), operationID: operationID)
            case .mac, .windows, .unknown:
                setStatus(.recoveryNeeded(reason: reason), operationID: operationID)
            }
        } catch is CancellationError {
            return
        } catch {
            setStatus(
                .recoveryNeeded(reason: "\(reason)；状态复核失败：\(error.localizedDescription)"),
                operationID: operationID
            )
        }
    }

    private func setStatus(_ status: SoftKVMStatus, operationID: UInt64? = nil) {
        updateState { $0.setStatus(status, operationID: operationID) }
    }

    private func requireCurrentOperation(_ operationID: UInt64) throws {
        guard !Task.isCancelled,
              stateMachine.isCurrentOperation(operationID) else {
            throw CancellationError()
        }
    }
}
