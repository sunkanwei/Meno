import Foundation

struct MouseControlIdentity: Equatable, Sendable {
    let connectionID: UUID
    let controlID: UInt64
    let routeID: UInt64

    init(connectionID: UUID, controlID: UInt64, routeID: UInt64) {
        precondition(controlID != 0)
        precondition(routeID != 0)
        self.connectionID = connectionID
        self.controlID = controlID
        self.routeID = routeID
    }
}

enum MacInputOwnershipPhase: Equatable, Sendable {
    case local
    case capturing(MouseControlIdentity)
    case acquiring(MouseControlIdentity)
    case remote(MouseControlIdentity)
    case releasing(MouseControlIdentity, returnY: UInt16)
    case recovering(MouseControlIdentity, returnY: UInt16)

    var identity: MouseControlIdentity? {
        switch self {
        case .local:
            nil
        case let .capturing(identity), let .acquiring(identity),
             let .remote(identity), let .releasing(identity, _),
             let .recovering(identity, _):
            identity
        }
    }

    var capturesInput: Bool { identity != nil }

    var canBeginRelease: Bool {
        switch self {
        case .capturing, .acquiring, .remote:
            true
        case .local, .releasing, .recovering:
            false
        }
    }

    var canBeginRecovery: Bool {
        switch self {
        case .capturing, .acquiring, .remote, .releasing:
            true
        case .local, .recovering:
            false
        }
    }

    var canComplete: Bool {
        switch self {
        case .releasing, .recovering:
            true
        case .local, .capturing, .acquiring, .remote:
            false
        }
    }
}

enum MacInputOwnershipEvent: Equatable, Sendable {
    case requestCapture(MouseControlIdentity)
    case captureSucceeded(MouseControlIdentity)
    case captureFailed(MouseControlIdentity)
    case remoteAcquired(MouseControlIdentity)
    case requestRelease(MouseControlIdentity, returnY: UInt16)
    case requestRecovery(MouseControlIdentity, returnY: UInt16)
    case completed(MouseControlIdentity)
}

/// The sole authority for Mac input ownership. Invalid and stale events are
/// rejected instead of being interpreted against the current session.
struct MacInputOwnershipEngine: Equatable, Sendable {
    private(set) var phase: MacInputOwnershipPhase = .local

    var identity: MouseControlIdentity? { phase.identity }
    var controlID: UInt64? { identity?.controlID }
    var capturesInput: Bool { phase.capturesInput }

    @discardableResult
    mutating func apply(_ event: MacInputOwnershipEvent) -> Bool {
        switch (phase, event) {
        case let (.local, .requestCapture(identity)):
            phase = .capturing(identity)
        case let (.capturing(current), .captureSucceeded(identity)) where current == identity:
            phase = .acquiring(identity)
        case let (.capturing(current), .captureFailed(identity)) where current == identity:
            phase = .local
        case let (.acquiring(current), .remoteAcquired(identity)) where current == identity:
            phase = .remote(identity)
        case let (current, .requestRelease(identity, returnY))
            where current.canBeginRelease && current.identity == identity:
            phase = .releasing(identity, returnY: returnY)
        case let (current, .requestRecovery(identity, returnY))
            where current.canBeginRecovery && current.identity == identity:
            phase = .recovering(identity, returnY: returnY)
        case let (current, .completed(identity))
            where current.canComplete && current.identity == identity:
            phase = .local
        default:
            return false
        }
        return true
    }
}
