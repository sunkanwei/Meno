import Foundation

extension CrossScreenMouseController {
    func sendNetworkAction(_ action: CrossScreenMouseNetworkAction) {
        switch action {
        case let .enter(
            connection,
            identity,
            normalizedY,
            residualX,
            entryEdge,
            returnOpeningY
        ):
            connection.sendEnter(
                controlID: identity.controlID,
                routeID: identity.routeID,
                normalizedY: normalizedY,
                residualX: residualX,
                entryEdge: entryEdge,
                returnOpeningY: returnOpeningY
            )
        case let .move(connection, controlID, deltaX, deltaY):
            connection.sendMove(controlID: controlID, dx: deltaX, dy: deltaY)
        case let .button(connection, controlID, button, isPressed):
            connection.sendButton(controlID: controlID, button, down: isPressed)
        case let .wheel(connection, controlID, inputLines):
            connection.sendWheel(controlID: controlID, inputLines)
        case let .keyboard(connection, controlID, reports, overflowed):
            let activationKey = microphoneReleaseTailActivationKey()
                ?? runtimeLock.withCriticalSection {
                    state.microphoneActivationHeld ? state.microphoneActivationKey : nil
                }
            let outboundReports: [KeyboardReport]
            if let activationKey {
                outboundReports = reports.map { report in
                    activationKey.preservingPressed(in: report)
                }
            } else {
                outboundReports = reports
            }
            if overflowed || outboundReports.contains(where: \.overflowed) {
                logKeyboardOverflowIfNeeded()
            }
            for report in outboundReports {
                connection.sendKeyboardState(controlID: controlID, report)
            }
        }
    }

    private func logKeyboardOverflowIfNeeded() {
        let now = ContinuousClock.now
        let shouldLog = runtimeLock.withCriticalSection { () -> Bool in
            if let lastKeyboardOverflowLog,
               lastKeyboardOverflowLog.duration(to: now) < .seconds(10) {
                return false
            }
            lastKeyboardOverflowLog = now
            return true
        }
        guard shouldLog else { return }
        Self.logger.warning(
            "Keyboard state exceeds six ordinary keys; sending the stable first six"
        )
    }
}
