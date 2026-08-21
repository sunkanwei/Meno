import Foundation

struct ConnectionReadinessGate: Sendable {
    private enum Phase: Sendable {
        case waitingForHello
        case sendingReady
        case ready
        case closed
    }

    private var phase: Phase = .waitingForHello

    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    var isSendingReady: Bool {
        if case .sendingReady = phase { return true }
        return false
    }

    var isHandshakePending: Bool {
        switch phase {
        case .waitingForHello, .sendingReady: true
        case .ready, .closed: false
        }
    }

    mutating func beginHello() -> Bool {
        guard case .waitingForHello = phase else { return false }
        phase = .sendingReady
        return true
    }

    mutating func readyFrameWasSent() -> Bool {
        guard case .sendingReady = phase else { return false }
        phase = .ready
        return true
    }

    mutating func close() {
        phase = .closed
    }
}

enum WindowsOnlineDelivery: Equatable, Sendable {
    case notifyNow
    case waitForReadyWrite
    case reject
}

struct WindowsOnlineDeliveryGate: Sendable {
    private var didReceiveWindowsOnline = false
    private var notificationPending = false

    mutating func receive(
        isReady: Bool,
        isSendingReady: Bool,
        negotiatedCapabilities: Set<CompanionCapability>,
        payload: Data
    ) -> WindowsOnlineDelivery {
        guard negotiatedCapabilities.contains(.windowsOnline),
              payload.isEmpty,
              !didReceiveWindowsOnline else {
            return .reject
        }

        if isReady {
            didReceiveWindowsOnline = true
            return .notifyNow
        }
        if isSendingReady {
            didReceiveWindowsOnline = true
            notificationPending = true
            return .waitForReadyWrite
        }
        return .reject
    }

    mutating func readyFrameWasSent() -> Bool {
        guard notificationPending else { return false }
        notificationPending = false
        return true
    }
}

enum IncomingConnectionAdmission {
    static func allows(
        serviceEnabled: Bool,
        systemIsSleeping: Bool,
        serverMatches: Bool,
        slotIsOccupied: Bool
    ) -> Bool {
        serviceEnabled && !systemIsSleeping && serverMatches && !slotIsOccupied
    }
}
