import CoreGraphics

enum CrossScreenEntryGateDecision: Equatable {
    case ready
    case hold(CGPoint?)
}

struct CrossScreenEntryGate: Sendable {
    private static let settlementDuration: Duration = .milliseconds(50)

    private(set) var isArmed = true
    private var rearmNotBefore: ContinuousClock.Instant?
    private var stabilizationPoint: CGPoint?

    mutating func arm() {
        isArmed = true
        rearmNotBefore = nil
        stabilizationPoint = nil
    }

    mutating func disarm(
        at now: ContinuousClock.Instant = .now,
        stabilizationPoint: CGPoint? = nil
    ) {
        isArmed = false
        rearmNotBefore = now.advanced(by: Self.settlementDuration)
        self.stabilizationPoint = stabilizationPoint
    }

    mutating func decision() -> CrossScreenEntryGateDecision {
        decision(now: .now)
    }

    mutating func decision(now: ContinuousClock.Instant) -> CrossScreenEntryGateDecision {
        guard !isArmed else { return .ready }
        guard let rearmNotBefore, now >= rearmNotBefore else {
            return .hold(stabilizationPoint)
        }

        arm()
        return .ready
    }
}
