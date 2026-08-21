@preconcurrency import CoreGraphics

extension CrossScreenMouseController {
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        inputEventLock.withCriticalSection {
            handleSerialized(type: type, event: event)
        }
    }

    private func handleSerialized(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.withCriticalSection {
                state.displayHandoff.resetTracking(at: nil)
            }
            return false
        }
        let microphoneActivationChanged = stateLock.withCriticalSection {
            state.observePendingMicrophonePhysicalRelease()
        }
        if microphoneActivationChanged {
            requestMicrophoneActivationUpdate()
        }
        let location = event.location
        let action = stateLock.withCriticalSection {
            Self.decideInputAction(
                type: type,
                event: event,
                location: location,
                state: &state
            )
        }

        if case let .send(.enter(_, controlID, _, _, _, _)) = action,
           !captureCursor(controlID: controlID) {
            return false
        }
        return performInputAction(action, type: type, event: event)
    }

    private static func decideInputAction(
        type: CGEventType,
        event: CGEvent,
        location: CGPoint,
        state: inout CrossScreenMouseState
    ) -> CrossScreenMouseAction {
        if isKeyboardEvent(type),
           !CrossScreenInputRouting.shouldHandleKeyboard(
               capturesInput: state.mode.capturesInput,
               localKeyboardCaptureRequired: state.localKeyboardCaptureRequired
           ) {
            return .none
        }
        if CrossScreenInputRouting.isAutomationMarkedPointerEvent(
            type: type,
            event: event
        ) {
            state.displayHandoff.resetTracking(at: nil)
            return .none
        }
        if state.softKVMShortcutCaptureEnabled {
            switch state.softKVMShortcutCapture.handle(
                type: type,
                event: event,
                shortcut: state.softKVMShortcut
            ) {
            case .trigger:
                _ = state.keyboard.releaseAll()
                return .toggleSoftKVM
            case .swallow:
                return .swallow
            case .none:
                break
            }
        }
        if state.mode.capturesInput,
           CrossScreenInputRouting.isEmergencyRelease(type: type, event: event) {
            return .emergencyRelease
        }
        switch state.mode {
        case .local:
            return localModeAction(
                type: type,
                event: event,
                location: location,
                state: &state
            )
        case let .acquiring(controlID), let .remote(controlID):
            return remoteModeAction(
                type: type,
                event: event,
                controlID: controlID,
                state: &state
            )
        case .releasing:
            return .swallow
        }
    }

    private static func localModeAction(
        type: CGEventType,
        event: CGEvent,
        location: CGPoint,
        state: inout CrossScreenMouseState
    ) -> CrossScreenMouseAction {
        state.updateLocalButtons(type: type, event: event)
        let deltaX = movementDeltaX(event)
        switch state.entryGate.decision() {
        case .ready:
            break
        case let .hold(stabilizationPoint):
            guard handlesLocalDisplayBoundary(
                type: type,
                localButtons: state.localButtons
            ), let stabilizationPoint else {
                return .none
            }
            state.displayHandoff.resetTracking(at: stabilizationPoint)
            return .stabilizeDisplayHandoff(stabilizationPoint)
        }
        let displayHandoffDecision = state.displayHandoffDecision(
            type: type,
            location: location,
            movementDeltaX: deltaX
        )
        if case let .handoff(handoff) = displayHandoffDecision {
            return .displayHandoff(handoff)
        }
        if case let .stabilize(point) = displayHandoffDecision {
            return .stabilizeDisplayHandoff(point)
        }
        if case let .wall(wall) = displayHandoffDecision {
            return .displayHandoffWall(wall)
        }
        return windowsEntryAction(
            type: type,
            location: location,
            deltaX: deltaX,
            state: &state
        )
    }

    private static func windowsEntryAction(
        type: CGEventType,
        location: CGPoint,
        deltaX: CGFloat,
        state: inout CrossScreenMouseState
    ) -> CrossScreenMouseAction {
        guard state.windowsRouteEnabled,
              let windowsGeometry = state.windowsGeometry,
              let remoteScreenMetrics = state.remoteScreenMetrics else {
            return .none
        }
        guard allowsAutomaticDisplayHandoff(
            type: type,
            localButtons: state.localButtons
        ) else { return .none }
        guard state.runtimeFailure == nil,
              let connection = state.connection,
              windowsGeometry.containsWindowsSeam(atY: location.y) else {
            return .none
        }
        guard let residualX = windowsGeometry.crossingResidualX(
            locationX: location.x,
            deltaX: deltaX
        ) else { return .none }
        guard let session = windowsGeometry.session(
            screenMetrics: remoteScreenMetrics,
            configuration: state.displayHandoff.configuration
        ) else {
            return .none
        }
        let mapping = session.entryMapping(macY: location.y)
        let normalizedY = mapping.normalizedY
        let controlID = UInt64.random(in: 1...UInt64.max)
        state.mode = .acquiring(controlID)
        state.windowsSession = session
        state.lastWindowsNormalizedY = normalizedY
        state.controlStartedAt = .now
        state.movementScaler.reset()
        let scaledResidual = state.movementScaler.convert(dx: Double(residualX), dy: 0)
        logWindowsEntry(
            controlID: controlID,
            session: session,
            mapping: mapping,
            movementScaler: state.movementScaler
        )
        return .send(.enter(
            connection: connection,
            controlID: controlID,
            normalizedY: normalizedY,
            residualX: scaledResidual.dx,
            entryEdge: session.windowsEntryEdge,
            returnOpeningY: session.windowsReturnOpeningY
        ))
    }

    private static func logWindowsEntry(
        controlID: UInt64,
        session: WindowsDisplayHandoffSession,
        mapping: WindowsVerticalMapping,
        movementScaler: MouseMovementScaler
    ) {
        let physicalOffset = mapping.physicalOffsetMM.map(String.init(describing:)) ?? "none"
        let movementMethod = movementScaler.usesPhysicalScreenSize ? "physical" : "pixels"
        let opening = session.windowsReturnOpeningY
        let entryDescription = "id=\(controlID) display=\(session.macDisplay.id) "
            + "macEdge=\(session.macEdge) windowsEdge=\(session.windowsEntryEdge) "
            + "alignment=\(session.configuration.alignment.rawValue) "
            + "method=\(mapping.method.rawValue) offsetMM=\(physicalOffset) "
            + "normalizedY=\(mapping.normalizedY) "
            + "returnOpeningY=\(opening.lowerBound)...\(opening.upperBound) "
            + "movement=\(movementMethod) scaleX=\(movementScaler.scaleX) "
            + "scaleY=\(movementScaler.scaleY)"
        Self.logger.info(
            "Windows display handoff enter \(entryDescription, privacy: .public)"
        )
    }

    private static func remoteModeAction(
        type: CGEventType,
        event: CGEvent,
        controlID: UInt64,
        state: inout CrossScreenMouseState
    ) -> CrossScreenMouseAction {
        if isKeyboardEvent(type) {
            guard state.keyboardSupported else { return .none }
            guard case .remote = state.mode,
                  state.runtimeFailure == nil,
                  let connection = state.connection else {
                return .swallow
            }
            return keyboardAction(
                type: type,
                event: event,
                connection: connection,
                controlID: controlID,
                state: &state
            )
        }
        guard let connection = state.connection else { return .none }
        if isMovement(type) {
            let scaled = state.movementScaler.convert(
                dx: Double(movementDeltaX(event)),
                dy: Double(movementDeltaY(event))
            )
            return .send(.move(
                connection: connection,
                controlID: controlID,
                deltaX: scaled.dx,
                deltaY: scaled.dy
            ))
        }
        if let change = mouseButtonChange(type: type, event: event) {
            return .send(.button(
                connection: connection,
                controlID: controlID,
                button: change.button,
                isPressed: change.isPressed
            ))
        }
        if type == .scrollWheel {
            return .send(.wheel(
                connection: connection,
                controlID: controlID,
                inputLines: wheelInputLines(event)
            ))
        }
        return .none
    }

    private func captureCursor(controlID: UInt64) -> Bool {
        let capture = MacCursorOwnership.capture()
        guard let captureToken = capture.token else {
            let didReset = stateLock.withCriticalSection { () -> Bool in
                guard state.mode.controlID == controlID else { return false }
                state.mode = .local
                state.windowsSession = nil
                _ = state.takeCursorCaptureForRestore()
                state.controlStartedAt = nil
                return true
            }
            guard didReset else { return false }
            let captureErrors = "background=\(capture.backgroundControl.logValue) "
                + "hide=\(capture.hideError?.rawValue ?? -1) "
                + "detach=\(capture.detachError?.rawValue ?? -1) "
                + "rollbackAssociate=\(capture.rollbackAssociationError?.rawValue ?? -1) "
                + "rollbackShow=\(capture.rollbackShowError?.rawValue ?? -1)"
            let failureDescription = "id=\(controlID) errors=\(captureErrors)"
            Self.logger.error(
                "Mouse cursor capture failed \(failureDescription, privacy: .public)"
            )
            Task { @MainActor [weak self] in
                self?.setRuntimeFailure("macOS 无法接管本地指针，跨屏鼠标已安全留在 Mac。")
            }
            return false
        }
        let didAcceptCapture = stateLock.withCriticalSection { () -> Bool in
            guard state.mode.controlID == controlID else { return false }
            state.didCaptureCursor(captureToken)
            return true
        }
        guard didAcceptCapture else {
            let restore = MacCursorOwnership.restore(captureToken, at: nil)
            let resultDescription = "id=\(controlID) restored=\(restore.succeeded)"
            Self.logger.info(
                "Mouse cursor capture superseded \(resultDescription, privacy: .public)"
            )
            if !restore.succeeded {
                Task { @MainActor [weak self] in
                    self?.setRuntimeFailure("macOS 无法完整恢复本地指针，跨屏鼠标已停止接管。")
                }
            }
            return false
        }
        Self.logger.info(
            "Mouse control acquiring id=\(controlID, privacy: .public) cursor=hidden detach=0"
        )
        Task { @MainActor [weak self] in
            self?.scheduleAcquireTimeout(controlID: controlID)
            self?.publishStatus()
        }
        return true
    }

    private func performInputAction(
        _ action: CrossScreenMouseAction,
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        switch action {
        case .none:
            return stateLock.withCriticalSection {
                state.mode.capturesInput && !isKeyboardEvent(type)
            }
        case let .displayHandoff(handoff):
            let warpError = MacCursorOwnership.warpLocalCursor(
                to: handoff.targetPoint
            )
            guard warpError == .success else {
                stateLock.withCriticalSection {
                    state.displayHandoff.observe(location: event.location)
                }
                let targetPoint = "\(handoff.targetPoint.x),\(handoff.targetPoint.y)"
                let failureDescription = "target=\(targetPoint) error=\(warpError.rawValue)"
                Self.logger.error(
                    "Display handoff cursor warp failed \(failureDescription, privacy: .public)"
                )
                return false
            }
            handoff.apply(to: event)
            logDisplayHandoff(handoff)
            return false
        case let .stabilizeDisplayHandoff(point):
            event.location = point
            event.setDoubleValueField(.mouseEventDeltaX, value: 0)
            event.setDoubleValueField(.mouseEventDeltaY, value: 0)
            return false
        case let .displayHandoffWall(wall):
            wall.apply(to: event)
            if wall.beginsContact {
                let crossingPoint = "\(wall.crossingPoint.x),\(wall.crossingPoint.y)"
                let retainedPoint = "\(wall.retainedPoint.x),\(wall.retainedPoint.y)"
                let description = "source=\(wall.sourceDisplayID) "
                    + "destination=\(wall.destinationDisplayID) "
                    + "direction=\(wall.direction.rawValue) "
                    + "crossing=\(crossingPoint) retained=\(retainedPoint)"
                Self.logger.info(
                    "Display handoff wall \(description, privacy: .public)"
                )
            }
            return false
        case .swallow:
            return true
        case let .send(networkAction):
            sendNetworkAction(networkAction)
            return true
        case let .sendAndActivateMicrophone(networkAction):
            cancelPendingMicrophoneReleaseTail()
            requestMicrophoneActivationUpdate()
            sendNetworkAction(networkAction)
            return true
        case let .sendAndBeginMicrophoneReleaseTail(networkAction, connection, controlID):
            beginMicrophoneReleaseTail(
                preserving: networkAction,
                connection: connection,
                controlID: controlID
            )
            return true
        case .emergencyRelease:
            Task { @MainActor [weak self] in
                self?.releaseRemote(
                    sendRelease: true,
                    normalizedY: nil,
                    reason: "emergency release"
                )
            }
            return true
        case .toggleSoftKVM:
            requestSoftKVMToggle()
            return true
        }
    }

    private func logDisplayHandoff(_ handoff: HorizontalDisplayHandoff) {
        let crossingPoint = "\(handoff.crossingPoint.x),\(handoff.crossingPoint.y)"
        let targetPoint = "\(handoff.targetPoint.x),\(handoff.targetPoint.y)"
        let handoffDescription = "source=\(handoff.sourceDisplayID) "
            + "destination=\(handoff.destinationDisplayID) "
            + "direction=\(handoff.direction.rawValue) "
            + "crossing=\(crossingPoint) "
            + "alignment=\(handoff.alignment.rawValue) "
            + "offsetMM=\(handoff.physicalOffsetMM) "
            + "target=\(targetPoint)"
        Self.logger.info(
            "Display handoff \(handoffDescription, privacy: .public)"
        )
    }

    private static func keyboardAction(
        type: CGEventType,
        event: CGEvent,
        connection: MouseConnection,
        controlID: UInt64,
        state: inout CrossScreenMouseState
    ) -> CrossScreenMouseAction {
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return .swallow
        }

        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = MacKeyboardMapping.windowsModifiers(
            previous: state.keyboard.modifiers,
            changedKeyCode: type == .flagsChanged ? keyCode : nil,
            eventFlags: event.flags.rawValue
        )
        if type == .flagsChanged, keyCode == MacKeyboardMapping.capsLockKeyCode {
            _ = state.keyboard.setModifiers(modifiers)
            let reports = state.keyboard.capsLockReports()
            return .send(.keyboard(
                connection: connection,
                controlID: controlID,
                reports: reports,
                overflowed: reports.contains(where: \.overflowed)
            ))
        }

        var changed = state.keyboard.setModifiers(modifiers)
        if type == .keyDown || type == .keyUp {
            let usage = MacKeyboardMapping.usage(forKeyCode: keyCode)
                ?? MacKeyboardMapping.usage(
                    forSpecialFunctionKey: specialFunctionKeyScalar(event)
                )
            if let usage {
                changed = state.keyboard.setUsage(
                    usage,
                    pressed: type == .keyDown
                ) || changed
            }
        }
        guard changed else { return .swallow }
        let microphoneActivationChanged = state.updateMicrophoneActivation()
        let report = state.keyboard.report
        let networkAction = CrossScreenMouseNetworkAction.keyboard(
            connection: connection,
            controlID: controlID,
            reports: [report],
            overflowed: report.overflowed
        )
        if microphoneActivationChanged {
            if state.microphoneActivationHeld {
                return .sendAndActivateMicrophone(networkAction)
            }
            return .sendAndBeginMicrophoneReleaseTail(
                networkAction,
                connection,
                controlID
            )
        }
        return .send(networkAction)
    }
}
