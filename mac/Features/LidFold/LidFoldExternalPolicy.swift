import Foundation

struct LidFoldExternalPolicy {
    enum Phase: Equatable {
        case idle
        case closing
        case black(until: TimeInterval)
        case waitingForOpening
    }

    private(set) var phase: Phase = .idle
    private var anchor: Double?
    private var angle: Double = 0
    private var reference: Double = 90
    private var lastMotion: TimeInterval = 0

    mutating func read(angle: Double, reference: Double, now: TimeInterval) {
        self.angle = angle
        self.reference = max(60, reference)
        guard let anchor else { self.anchor = angle; return }
        let change = angle - anchor
        guard abs(change) >= 1 else { return }
        self.anchor = angle
        if change > 0 {
            if angle <= 7 {
                if case .black = phase { return }
                if phase == .waitingForOpening { return }
            }
            // External displays never start an opening animation, including
            // when only one display has finished waking.
            phase = .idle
            return
        }
        guard phase != .waitingForOpening else { return }
        if case .black = phase { return }
        phase = .closing
        lastMotion = now
        if angle <= 7 { didClose(now: now) }
    }

    mutating func didClose(now: TimeInterval) {
        guard phase != .waitingForOpening else { return }
        if case .black = phase { return }
        // This bounds a failed display-sleep handoff without extending it on
        // repeated HID reports or display-configuration notifications.
        phase = .black(until: now + 8)
    }

    mutating func target(now: TimeInterval) -> Double {
        switch phase {
        case .closing:
            guard now - lastMotion < 1.25 else { return 0 }
            let travel = min(1, max(0, (reference - angle) / (reference - 5)))
            return travel * travel * (3 - 2 * travel)
        case .black(let deadline):
            if now < deadline { return 1 }
            phase = .waitingForOpening
            return 0
        case .idle, .waitingForOpening:
            return 0
        }
    }

    mutating func cancel() {
        phase = .idle
        anchor = nil
    }
}
