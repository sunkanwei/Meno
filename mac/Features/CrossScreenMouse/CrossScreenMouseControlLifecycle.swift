@preconcurrency import CoreGraphics
import Foundation

extension CrossScreenMouseController {
    private final class TransitionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func markCompleted() {
            lock.withCriticalSection { completed = true }
        }

        var isCompleted: Bool {
            lock.withCriticalSection { completed }
        }
    }

    private struct ReleaseContext {
        let identity: MouseControlIdentity
        let connection: MouseConnection?
    }

    private struct CursorRestoreContext {
        let capture: MacCursorOwnership.CaptureToken?
        let point: CGPoint?
    }

    @MainActor
    func remoteDidAcquire(connectionID: UUID, controlID: UInt64) {
        let acquire = runtimeLock.withCriticalSection {
            () -> (
                identity: MouseControlIdentity?,
                activation: (MouseConnection, KeyboardReport)?
            ) in
            guard let identity = state.ownership.identity,
                  identity.connectionID == connectionID,
                  identity.controlID == controlID,
                  state.ownership.apply(.remoteAcquired(identity)) else {
                return (nil, nil)
            }
            let activation: (MouseConnection, KeyboardReport)?
            if state.keyboardSupported,
               let connection = state.connection,
               let report = state.activateMicrophoneIfPhysicalKeyHeld() {
                activation = (connection, report)
            } else {
                activation = nil
            }
            return (identity, activation)
        }
        guard let identity = acquire.identity else { return }
        if let activation = acquire.activation {
            activation.0.sendKeyboardState(controlID: controlID, activation.1)
        }
        controlTimeoutWorkItem?.cancel()
        controlTimeoutWorkItem = nil
        Self.logger.notice(
            "Mouse control acquired connection=\(identity.connectionID.uuidString, privacy: .public) id=\(controlID, privacy: .public) route=\(identity.routeID, privacy: .public)"
        )
        if acquire.activation != nil { publishMicrophoneActivation(true) }
        publishStatus()
    }

    @MainActor
    func remoteDidRelease(connectionID: UUID, controlID: UInt64) {
        guard let identity = currentIdentity(
            connectionID: connectionID,
            controlID: controlID
        ) else { return }
        completeRelease(
            identity: identity,
            normalizedY: nil,
            reason: "release acknowledged"
        )
    }

    @MainActor
    func remoteDidLeave(
        connectionID: UUID,
        controlID: UInt64,
        normalizedY: UInt16
    ) {
        guard let identity = currentIdentity(
            connectionID: connectionID,
            controlID: controlID
        ) else { return }
        completeRelease(
            identity: identity,
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
        runtimeLock.withCriticalSection {
            state.enabled = false
            state.disableWindowsRoute()
            state.updateConnection(nil, peer: nil)
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
        guard runtimeLock.withCriticalSection({ state.ownership.capturesInput }) else {
            prepareMicrophoneForRemoteRelease(forceStop: forceStopMicrophone)
            stopTapIfUnneededAndLocal()
            publishStatus()
            return
        }
        guard let release = beginRelease(
            normalizedY: normalizedY,
            recovering: restoreImmediately,
            forceStopMicrophone: forceStopMicrophone
        ) else {
            stopTapIfUnneededAndLocal()
            publishStatus()
            return
        }

        controlTimeoutWorkItem?.cancel()
        controlTimeoutWorkItem = nil
        Self.logger.notice(
            "Mouse control releasing connection=\(release.identity.connectionID.uuidString, privacy: .public) id=\(release.identity.controlID, privacy: .public) route=\(release.identity.routeID, privacy: .public) reason=\(reason, privacy: .public)"
        )
        if sendRelease {
            if restoreImmediately {
                release.connection?.abortControl(controlID: release.identity.controlID)
            } else {
                release.connection?.sendReleaseAll(controlID: release.identity.controlID)
            }
        }
        if restoreImmediately {
            completeRelease(
                identity: release.identity,
                normalizedY: normalizedY,
                reason: "immediate local recovery"
            )
        } else {
            scheduleReleaseTimeout(identity: release.identity)
            publishStatus()
        }
    }

    @MainActor
    private func prepareMicrophoneForRemoteRelease(forceStop: Bool) {
        prepareMicrophoneForRemoteReleaseLocked(controlID: nil, forceStop: forceStop)
    }

    private func prepareMicrophoneForRemoteReleaseLocked(
        controlID: UInt64?,
        forceStop: Bool
    ) {
        guard runtimeLock.withCriticalSection({
            controlID == nil || state.ownership.controlID == controlID
        }) else { return }
        let releaseTailStopped = cancelPendingMicrophoneReleaseTail(controlID: controlID)
        let microphoneStopped = runtimeLock.withCriticalSection {
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
        recovering: Bool,
        forceStopMicrophone: Bool
    ) -> ReleaseContext? {
        hidInputTap.performCursorTransition { [weak self] in
            guard let self else { return }
            guard let identity = runtimeLock.withCriticalSection({
                state.ownership.identity
            }) else { return }
            prepareMicrophoneForRemoteReleaseLocked(
                controlID: identity.controlID,
                forceStop: forceStopMicrophone
            )
            runtimeLock.withCriticalSection {
                guard state.ownership.identity == identity else { return }
                let returnY = normalizedY ?? state.lastWindowsNormalizedY
                let event: MacInputOwnershipEvent = recovering
                    ? .requestRecovery(identity, returnY: returnY)
                    : .requestRelease(identity, returnY: returnY)
                _ = state.ownership.apply(event)
                _ = state.keyboard.releaseAll()
            }
        }
        return runtimeLock.withCriticalSection {
            guard let identity = state.ownership.identity else { return nil }
            switch state.ownership.phase {
            case .releasing, .recovering:
                return ReleaseContext(identity: identity, connection: state.connection)
            default:
                return nil
            }
        }
    }

    @MainActor
    private func completeRelease(
        identity: MouseControlIdentity,
        normalizedY: UInt16?,
        reason: String,
        prepareMicrophoneForReturn: Bool = false
    ) {
        guard runtimeLock.withCriticalSection({ state.ownership.identity == identity }) else { return }
        let currentDisplays = CrossScreenDisplay.currentDisplays()
        let completion = TransitionFlag()
        hidInputTap.performCursorTransition { [weak self] in
            guard let self else { return }
            if prepareMicrophoneForReturn {
                prepareMicrophoneForRemoteReleaseLocked(
                    controlID: identity.controlID,
                    forceStop: false
                )
            }
            let restore = transitionToLocalState(
                identity: identity,
                normalizedY: normalizedY,
                currentDisplays: currentDisplays,
                localButtons: currentMouseButtonMask()
            )
            guard let restore else { return }
            completion.markCompleted()
            guard let capture = restore.capture else {
                let location = MacCursorOwnership.currentLocation() ?? restore.point
                runtimeLock.withCriticalSection {
                    state.displayHandoff.resetTracking(at: location)
                }
                return
            }
            let result = MacCursorOwnership.restore(capture, at: restore.point)
            let location = MacCursorOwnership.currentLocation() ?? restore.point
            runtimeLock.withCriticalSection {
                state.displayHandoff.resetTracking(at: location)
            }
            if !result.succeeded {
                Self.logger.error(
                        "Mouse cursor restoration failed connection=\(identity.connectionID.uuidString, privacy: .public) id=\(identity.controlID, privacy: .public) route=\(identity.routeID, privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    self?.setRuntimeFailure("macOS 无法完整恢复本地指针，跨屏鼠标已停止接管。")
                }
            }
        }
        guard completion.isCompleted else { return }
        controlTimeoutWorkItem?.cancel()
        controlTimeoutWorkItem = nil
        Self.logger.notice(
            "Mouse control local connection=\(identity.connectionID.uuidString, privacy: .public) id=\(identity.controlID, privacy: .public) route=\(identity.routeID, privacy: .public) reason=\(reason, privacy: .public)"
        )
        stopTapIfUnneededAndLocal()
        publishStatus()
    }

    private func transitionToLocalState(
        identity: MouseControlIdentity,
        normalizedY: UInt16?,
        currentDisplays: [CrossScreenDisplay],
        localButtons: UInt8
    ) -> CursorRestoreContext? {
        runtimeLock.withCriticalSection {
            guard state.ownership.identity == identity else { return nil }
            let fallbackY: UInt16
            switch state.ownership.phase {
            case let .releasing(_, returnY), let .recovering(_, returnY):
                fallbackY = returnY
            default:
                fallbackY = state.lastWindowsNormalizedY
                _ = state.ownership.apply(.requestRecovery(identity, returnY: fallbackY))
            }
            let cursorReturn = WindowsReturnPointResolver.point(
                session: state.activeRoute?.session,
                windowsNormalizedY: normalizedY ?? fallbackY,
                currentDisplays: currentDisplays
            )
            guard state.ownership.apply(.completed(identity)) else { return nil }
            let restore = CursorRestoreContext(
                capture: state.takeCursorCaptureForRestore(),
                point: cursorReturn?.point
            )
            state.activeRoute = nil
            state.localButtons = localButtons
            state.entryGate.disarm(stabilizationPoint: cursorReturn?.point)
            state.displayHandoff.resetTracking(at: cursorReturn?.point)
            _ = state.keyboard.releaseAll()
            return restore
        }
    }

    @MainActor
    func scheduleAcquireTimeout(identity: MouseControlIdentity) {
        guard runtimeLock.withCriticalSection({
            state.ownership.phase == .acquiring(identity)
        }) else { return }
        scheduleControlTimeout(after: 0.25) { [weak self] in
            guard let self,
                  runtimeLock.withCriticalSection({
                      state.ownership.phase == .acquiring(identity)
                  }) else { return }
            Self.logger.error(
                "Mouse acquire timed out connection=\(identity.connectionID.uuidString, privacy: .public) id=\(identity.controlID, privacy: .public) route=\(identity.routeID, privacy: .public)"
            )
            releaseRemote(
                sendRelease: true,
                normalizedY: nil,
                reason: "acquire timeout"
            )
        }
    }

    @MainActor
    private func scheduleReleaseTimeout(identity: MouseControlIdentity) {
        scheduleControlTimeout(after: 0.55) { [weak self] in
            guard let self,
                  runtimeLock.withCriticalSection({
                      state.ownership.identity == identity
                  }) else { return }
            Self.logger.error(
                "Mouse release acknowledgement timed out connection=\(identity.connectionID.uuidString, privacy: .public) id=\(identity.controlID, privacy: .public) route=\(identity.routeID, privacy: .public)"
            )
            completeRelease(
                identity: identity,
                normalizedY: nil,
                reason: "release lease expired"
            )
        }
    }

    private func currentIdentity(
        connectionID: UUID,
        controlID: UInt64
    ) -> MouseControlIdentity? {
        runtimeLock.withCriticalSection {
            guard let identity = state.ownership.identity,
                  identity.connectionID == connectionID,
                  identity.controlID == controlID else { return nil }
            return identity
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
