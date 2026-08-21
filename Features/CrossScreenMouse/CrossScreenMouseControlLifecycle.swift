@preconcurrency import CoreGraphics
import Foundation

extension CrossScreenMouseController {
    private struct ReleaseContext {
        let controlID: UInt64
        let connection: MouseConnection?
    }

    private struct CursorRestoreContext {
        let capture: MacCursorOwnership.CaptureToken?
        let point: CGPoint?
        let mappingMethod: WindowsVerticalMappingMethod?
        let physicalOffsetMM: CGFloat?
    }

    @MainActor
    func remoteDidAcquire(controlID: UInt64) {
        let acquire = inputEventLock.withCriticalSection {
            let result = stateLock.withCriticalSection {
                () -> (
                    startedAt: ContinuousClock.Instant?,
                    activation: (MouseConnection, KeyboardReport)?
                ) in
                guard case .acquiring(controlID) = state.mode else { return (nil, nil) }
                state.mode = .remote(controlID)
                let activation: (MouseConnection, KeyboardReport)?
                if state.keyboardSupported,
                   let connection = state.connection,
                   let report = state.activateMicrophoneIfPhysicalKeyHeld() {
                    activation = (connection, report)
                } else {
                    activation = nil
                }
                return (state.controlStartedAt, activation)
            }
            if let activation = result.activation {
                activation.0.sendKeyboardState(controlID: controlID, activation.1)
            }
            return (startedAt: result.startedAt, activated: result.activation != nil)
        }
        guard let startedAt = acquire.startedAt else {
            Self.logger.info("Ignored stale mouse acquired id=\(controlID, privacy: .public)")
            return
        }
        controlTimeoutWorkItem?.cancel()
        controlTimeoutWorkItem = nil
        let milliseconds = Int(
            (startedAt.duration(to: .now).crossScreenTimeInterval * 1_000).rounded()
        )
        Self.logger.info(
            "Mouse control acquired id=\(controlID, privacy: .public) rttMs=\(milliseconds)"
        )
        if acquire.activated {
            publishMicrophoneActivation(true)
        }
        publishStatus()
    }

    @MainActor
    func remoteDidRelease(controlID: UInt64) {
        completeRelease(
            controlID: controlID,
            normalizedY: nil,
            reason: "release acknowledged"
        )
    }

    @MainActor
    func remoteDidLeave(controlID: UInt64, normalizedY: UInt16) {
        completeRelease(
            controlID: controlID,
            normalizedY: normalizedY,
            reason: "Windows left remote screen",
            prepareMicrophoneForReturn: true
        )
    }

    @MainActor
    func prepareForSystemTransition(forceStopMicrophone: Bool = false) {
        disableRouteAndResetShortcutCapture()
        recoverLocalImmediately(
            sendRelease: true,
            reason: "system transition",
            forceStopMicrophone: forceStopMicrophone
        )
    }

    @MainActor
    func stopForApplicationExit() {
        cancelInputTapRestart()
        releaseRemote(
            sendRelease: true,
            normalizedY: nil,
            reason: "application exit",
            restoreImmediately: true,
            forceStopMicrophone: true
        )
        stateLock.withCriticalSection {
            state.enabled = false
            state.windowsRouteEnabled = false
            state.updateConnection(
                nil,
                peer: nil
            )
            state.tapFailure = nil
            state.runtimeFailure = nil
            state.softKVMShortcutCapture.reset()
        }
        stopInputTaps()
        localDisplayPortalTopology.restore()
    }

    @MainActor
    func recoverLocalImmediately(
        sendRelease: Bool,
        reason: String,
        forceStopMicrophone: Bool = false
    ) {
        releaseRemote(
            sendRelease: sendRelease,
            normalizedY: nil,
            reason: reason,
            restoreImmediately: true,
            forceStopMicrophone: forceStopMicrophone
        )
    }

    @MainActor
    func releaseRemote(
        sendRelease: Bool,
        normalizedY: UInt16?,
        reason: String,
        restoreImmediately: Bool = false,
        forceStopMicrophone: Bool = false
    ) {
        let currentMode = stateLock.withCriticalSection { state.mode }
        if case let .releasing(controlID, _) = currentMode {
            prepareMicrophoneForRemoteRelease(forceStop: forceStopMicrophone)
            if restoreImmediately {
                if sendRelease {
                    let connection = stateLock.withCriticalSection { state.connection }
                    connection?.abortControl(controlID: controlID)
                }
                completeRelease(
                    controlID: controlID,
                    normalizedY: normalizedY,
                    reason: "immediate local recovery"
                )
            } else {
                stopTapIfUnneededAndLocal()
                publishStatus()
            }
            return
        }
        guard currentMode.capturesInput else {
            prepareMicrophoneForRemoteRelease(forceStop: forceStopMicrophone)
            stopTapIfUnneededAndLocal()
            publishStatus()
            return
        }
        guard let release = beginRelease(
            normalizedY: normalizedY,
            forceStopMicrophone: forceStopMicrophone
        ) else {
            stopTapIfUnneededAndLocal()
            publishStatus()
            return
        }

        controlTimeoutWorkItem?.cancel()
        controlTimeoutWorkItem = nil
        Self.logger.info(
            "Mouse control releasing id=\(release.controlID, privacy: .public) reason=\(reason, privacy: .public)"
        )
        if sendRelease {
            if restoreImmediately {
                release.connection?.abortControl(controlID: release.controlID)
            } else {
                release.connection?.sendReleaseAll(controlID: release.controlID)
            }
        }
        if restoreImmediately {
            completeRelease(
                controlID: release.controlID,
                normalizedY: normalizedY,
                reason: "immediate local recovery"
            )
        } else {
            scheduleReleaseTimeout(controlID: release.controlID)
            publishStatus()
        }
    }

    @MainActor
    private func prepareMicrophoneForRemoteRelease(forceStop: Bool) {
        inputEventLock.withCriticalSection {
            prepareMicrophoneForRemoteReleaseLocked(
                controlID: nil,
                forceStop: forceStop
            )
        }
    }

    private func prepareMicrophoneForRemoteReleaseLocked(
        controlID: UInt64?,
        forceStop: Bool
    ) {
        guard stateLock.withCriticalSection({
            controlID == nil || state.mode.controlID == controlID
        }) else { return }
        let releaseTailStopped = cancelPendingMicrophoneReleaseTail(controlID: controlID)
        let microphoneStopped = stateLock.withCriticalSection {
            forceStop
                ? state.releaseMicrophoneActivation()
                : state.preserveMicrophoneActivationWhileReturningToMac()
        }
        if releaseTailStopped || microphoneStopped {
            requestMicrophoneActivationUpdate()
        }
    }

    @MainActor
    private func beginRelease(
        normalizedY: UInt16?,
        forceStopMicrophone: Bool
    ) -> ReleaseContext? {
        hidInputTap.performCursorTransition { [weak self] in
            guard let self else { return }
            inputEventLock.withCriticalSection {
                let controlID = stateLock.withCriticalSection {
                    state.mode.controlID
                }
                guard let controlID else { return }
                prepareMicrophoneForRemoteReleaseLocked(
                    controlID: controlID,
                    forceStop: forceStopMicrophone
                )
                stateLock.withCriticalSection {
                    guard state.mode.controlID == controlID else { return }
                    state.mode = .releasing(
                        controlID,
                        normalizedY ?? state.lastWindowsNormalizedY
                    )
                    _ = state.keyboard.releaseAll()
                }
            }
        }
        return stateLock.withCriticalSection {
            guard case let .releasing(controlID, _) = state.mode else { return nil }
            return ReleaseContext(controlID: controlID, connection: state.connection)
        }
    }

    @MainActor
    private func completeRelease(
        controlID: UInt64,
        normalizedY: UInt16?,
        reason: String,
        prepareMicrophoneForReturn: Bool = false
    ) {
        let shouldComplete = stateLock.withCriticalSection {
            state.mode.controlID == controlID
        }
        guard shouldComplete else {
            Self.logger.info("Ignored stale mouse release id=\(controlID, privacy: .public)")
            return
        }
        let currentDisplays = CrossScreenDisplay.currentDisplays()
        hidInputTap.performCursorTransition { [weak self] in
            guard let self else { return }
            inputEventLock.withCriticalSection {
                if prepareMicrophoneForReturn {
                    prepareMicrophoneForRemoteReleaseLocked(
                        controlID: controlID,
                        forceStop: false
                    )
                }
                let localButtons = currentMouseButtonMask()
                let restore = transitionToLocalState(
                    controlID: controlID,
                    normalizedY: normalizedY,
                    currentDisplays: currentDisplays,
                    localButtons: localButtons
                )
                guard let restore else { return }
                guard let capture = restore.capture else {
                    let actualPointerLocation = MacCursorOwnership.currentLocation() ?? restore.point
                    stateLock.withCriticalSection {
                        state.displayHandoff.resetTracking(at: actualPointerLocation)
                    }
                    return
                }
                let result = MacCursorOwnership.restore(capture, at: restore.point)
                let actualPointerLocation = MacCursorOwnership.currentLocation() ?? restore.point
                stateLock.withCriticalSection {
                    state.displayHandoff.resetTracking(at: actualPointerLocation)
                }
                let resultDescription = "id=\(controlID) "
                    + "background=\(result.backgroundControl.logValue) "
                    + "suppress=\(result.suppressionError?.rawValue ?? -1) "
                    + "warp=\(result.warpError?.rawValue ?? 0) "
                    + "associate=\(result.associationError.rawValue) "
                    + "show=\(result.showError.rawValue) "
                    + "cursor=visible "
                    + "mapping=\(restore.mappingMethod?.rawValue ?? "none") "
                    + "offsetMM=\(restore.physicalOffsetMM.map(String.init(describing:)) ?? "none")"
                Self.logger.info(
                    "Mouse cursor restored \(resultDescription, privacy: .public)"
                )
                if !result.succeeded {
                    Task { @MainActor [weak self] in
                        self?.setRuntimeFailure("macOS 无法完整恢复本地指针，跨屏鼠标已停止接管。")
                    }
                }
            }
        }
        controlTimeoutWorkItem?.cancel()
        controlTimeoutWorkItem = nil
        Self.logger.info(
            "Mouse control local id=\(controlID, privacy: .public) reason=\(reason, privacy: .public)"
        )
        stopTapIfUnneededAndLocal()
        publishStatus()
    }

    private func transitionToLocalState(
        controlID: UInt64,
        normalizedY: UInt16?,
        currentDisplays: [CrossScreenDisplay],
        localButtons: UInt8
    ) -> CursorRestoreContext? {
        stateLock.withCriticalSection {
            guard state.mode.controlID == controlID else { return nil }
            let returnNormalizedY: UInt16
            if case let .releasing(_, releaseY) = state.mode {
                returnNormalizedY = normalizedY ?? releaseY
            } else {
                returnNormalizedY = normalizedY ?? state.lastWindowsNormalizedY
            }
            let cursorReturn = WindowsReturnPointResolver.point(
                session: state.windowsSession,
                windowsNormalizedY: returnNormalizedY,
                currentDisplays: currentDisplays
            )
            state.displayHandoff.resetTracking(at: cursorReturn?.point)
            let restore = CursorRestoreContext(
                capture: state.takeCursorCaptureForRestore(),
                point: cursorReturn?.point,
                mappingMethod: cursorReturn?.method,
                physicalOffsetMM: cursorReturn?.physicalOffsetMM
            )
            state.mode = .local
            state.windowsSession = nil
            state.localButtons = localButtons
            state.controlStartedAt = nil
            state.entryGate.disarm(stabilizationPoint: cursorReturn?.point)
            _ = state.keyboard.releaseAll()
            return restore
        }
    }

    @MainActor
    func scheduleAcquireTimeout(controlID: UInt64) {
        guard stateLock.withCriticalSection({
            if case .acquiring(controlID) = state.mode { return true }
            return false
        }) else { return }
        scheduleControlTimeout(after: 0.25) { [weak self] in
            guard let self,
                  stateLock.withCriticalSection({
                      if case .acquiring(controlID) = state.mode { return true }
                      return false
                  }) else { return }
            Self.logger.error("Mouse acquire timed out id=\(controlID, privacy: .public)")
            releaseRemote(
                sendRelease: true,
                normalizedY: nil,
                reason: "acquire timeout"
            )
        }
    }

    @MainActor
    private func scheduleReleaseTimeout(controlID: UInt64) {
        scheduleControlTimeout(after: 0.55) { [weak self] in
            guard let self,
                  stateLock.withCriticalSection({ state.mode.controlID == controlID }) else {
                return
            }
            Self.logger.error(
                "Mouse release acknowledgement timed out id=\(controlID, privacy: .public)"
            )
            completeRelease(
                controlID: controlID,
                normalizedY: nil,
                reason: "release lease expired"
            )
        }
    }

    @MainActor
    private func scheduleControlTimeout(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        controlTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor in action() }
        }
        controlTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
