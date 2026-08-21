import Foundation

struct CutAttempt: Equatable, Sendable {
    let token: UInt64
    let finderPID: Int32
    let baselinePasteboardChangeCount: Int
    let sourceURLs: [URL]
    let confirmationDeadline: Date
}

struct CutSession: Equatable, Sendable {
    let finderPID: Int32
    let pasteboardChangeCount: Int
    let sourceURLs: [URL]
    let expiresAt: Date
}

struct CutHealthSnapshot: Equatable, Sendable {
    let finderPID: Int32?
    let pasteboardChangeCount: Int
    let sourcesExist: Bool
    let checkedAt: Date
}

enum CutPhase: Equatable, Sendable {
    case idle
    case awaitingCopy(CutAttempt)
    case armed(CutSession)
}

struct CutStateMachine: Sendable {
    static let confirmationTimeout: TimeInterval = 1.5
    static let sessionTimeout: TimeInterval = 10 * 60
    static let maximumHealthAge: TimeInterval = 1.0

    private(set) var phase: CutPhase = .idle
    private var nextToken: UInt64 = 0

    var hasArmedSession: Bool {
        if case .armed = phase { return true }
        return false
    }

    @discardableResult
    mutating func beginCopy(
        finderPID: Int32,
        baselinePasteboardChangeCount: Int,
        sourceURLs: [URL],
        now: Date
    ) -> CutAttempt? {
        let normalizedSources = sourceURLs.normalizedFileURLs()
        guard !normalizedSources.isEmpty else {
            cancel()
            return nil
        }

        nextToken &+= 1
        let attempt = CutAttempt(
            token: nextToken,
            finderPID: finderPID,
            baselinePasteboardChangeCount: baselinePasteboardChangeCount,
            sourceURLs: normalizedSources,
            confirmationDeadline: now.addingTimeInterval(Self.confirmationTimeout)
        )
        phase = .awaitingCopy(attempt)
        return attempt
    }

    @discardableResult
    mutating func confirmCopy(
        token: UInt64,
        finderPID: Int32,
        pasteboardChangeCount: Int,
        copiedURLs: [URL],
        sourcesExist: Bool,
        now: Date
    ) -> Bool {
        guard case let .awaitingCopy(attempt) = phase,
              attempt.token == token,
              attempt.finderPID == finderPID,
              now <= attempt.confirmationDeadline,
              pasteboardChangeCount != attempt.baselinePasteboardChangeCount,
              sourcesExist,
              copiedURLs.normalizedFileURLs() == attempt.sourceURLs else {
            if case let .awaitingCopy(current) = phase, current.token == token {
                phase = .idle
            }
            return false
        }

        phase = .armed(
            CutSession(
                finderPID: finderPID,
                pasteboardChangeCount: pasteboardChangeCount,
                sourceURLs: attempt.sourceURLs,
                expiresAt: now.addingTimeInterval(Self.sessionTimeout)
            )
        )
        return true
    }

    mutating func cancel() {
        phase = .idle
    }

    @discardableResult
    mutating func invalidateIfNeeded(health: CutHealthSnapshot, now: Date) -> Bool {
        guard case let .armed(session) = phase else { return false }
        guard isValid(session: session, health: health, now: now) else {
            phase = .idle
            return true
        }
        return false
    }

    mutating func consumeForMove(health: CutHealthSnapshot, now: Date) -> CutSession? {
        guard case let .armed(session) = phase,
              isValid(session: session, health: health, now: now) else {
            phase = .idle
            return nil
        }
        phase = .idle
        return session
    }

    private func isValid(session: CutSession, health: CutHealthSnapshot, now: Date) -> Bool {
        health.finderPID == session.finderPID
            && health.pasteboardChangeCount == session.pasteboardChangeCount
            && health.sourcesExist
            && now <= session.expiresAt
            && now.timeIntervalSince(health.checkedAt) >= 0
            && now.timeIntervalSince(health.checkedAt) <= Self.maximumHealthAge
    }
}
