import Foundation

struct MouseOutboundFrameSpec: Sendable {
    let kind: ClipboardMessageKind
    let payload: Data
    let controlID: UInt64?
}

enum MouseMailboxSubmission: Equatable, Sendable {
    case ignored
    case queued
    case scheduleDrain
    case failed
}

struct MouseOutboundMailbox: Sendable {
    private struct Point: Equatable, Sendable {
        var x: Int32
        var y: Int32
    }

    private struct Movement: Sendable {
        let controlID: UInt64
        let start: Point
        var target: Point
        let maximumX: Int32
        let entryEdge: HorizontalDisplaySide
        var endsWithEdgeProbe: Bool

        var frames: [MouseOutboundFrameSpec] {
            let samples: [MouseMoveSample]
            if endsWithEdgeProbe {
                var result = MousePayload.split(dx: 0, dy: target.y - start.y)
                let edgeProbeX: Int32
                switch entryEdge {
                case .left:
                    edgeProbeX = start.x > 0 ? -start.x : -1
                case .right:
                    edgeProbeX = start.x < maximumX ? maximumX - start.x : 1
                }
                result.append(contentsOf: MousePayload.split(dx: edgeProbeX, dy: 0))
                samples = result
            } else {
                samples = MousePayload.split(
                    dx: target.x - start.x,
                    dy: target.y - start.y
                )
            }
            return samples.chunks(ofCount: ClipboardWire.maximumMouseMoveBatch).map {
                MouseOutboundFrameSpec(
                    kind: .mouseMove,
                    payload: MousePayload.move(controlID: controlID, samples: Array($0)),
                    controlID: controlID
                )
            }
        }
    }

    private struct Session: Sendable {
        let controlID: UInt64
        let maximumX: Int32
        let maximumY: Int32
        let returnOpeningY: ClosedRange<Int32>
        var position: Point
        let entryEdge: HorizontalDisplaySide
        var buttons: UInt8 = 0
        var recentMovedTowardEdge = false
        var keyboardReport = KeyboardReport.released
        var acceptingInput = true
        var waitingForLeave = false
    }

    private enum Item: Sendable {
        case frames([MouseOutboundFrameSpec])
        case movement(Movement)
        case heartbeat(
            controlID: UInt64,
            keyboardReport: KeyboardReport?,
            frames: [MouseOutboundFrameSpec]
        )

        var frames: [MouseOutboundFrameSpec] {
            switch self {
            case let .frames(frames), let .heartbeat(_, _, frames): frames
            case let .movement(movement): movement.frames
            }
        }

        func belongs(to controlID: UInt64) -> Bool {
            switch self {
            case let .movement(movement): movement.controlID == controlID
            case let .heartbeat(itemControlID, _, _): itemControlID == controlID
            case let .frames(frames): frames.contains { $0.controlID == controlID }
            }
        }
    }

    private let maximumItems: Int
    private var items: [Item] = []
    private var screenMetrics: MouseScreenMetrics?
    private var session: Session?
    private var ready = false
    private var keyboardSupported = false
    private var drainScheduled = false
    private var failed = false
    private var wheelAccumulator = MouseWheelAccumulator()
    private var lastWheelInputAt: ContinuousClock.Instant?

    init(maximumItems: Int = 16) {
        precondition(maximumItems > 0)
        self.maximumItems = maximumItems
        items.reserveCapacity(maximumItems)
    }

    mutating func activate(
        screenMetrics: MouseScreenMetrics,
        keyboardSupported: Bool
    ) {
        self.screenMetrics = screenMetrics
        self.keyboardSupported = keyboardSupported
        ready = true
        failed = false
    }

    mutating func deactivate() {
        ready = false
        failed = false
        screenMetrics = nil
        session = nil
        items.removeAll(keepingCapacity: true)
        drainScheduled = false
        resetWheel()
    }

    mutating func enqueueConnectionFrame(
        kind: ClipboardMessageKind,
        payload: Data
    ) -> MouseMailboxSubmission {
        guard ready else { return .ignored }
        return append(.frames([
            MouseOutboundFrameSpec(
                kind: kind,
                payload: payload,
                controlID: nil
            ),
        ]))
    }

    mutating func beginSession(
        controlID: UInt64,
        normalizedY: UInt16,
        residualX: Int32,
        entryEdge: HorizontalDisplaySide = .left,
        returnOpeningY: ClosedRange<Int32>
    ) -> MouseMailboxSubmission {
        guard ready, controlID != 0, session == nil, let screenMetrics,
              screenMetrics.width > 0, screenMetrics.height > 0 else {
            return session == nil ? .ignored : fail()
        }
        let maximumX = Int32(clamping: screenMetrics.width - 1)
        let maximumY = Int32(clamping: screenMetrics.height - 1)
        guard returnOpeningY.lowerBound >= 0,
              returnOpeningY.upperBound <= maximumY,
              returnOpeningY.lowerBound <= returnOpeningY.upperBound else {
            return fail()
        }
        let initial = Point(
            x: entryEdge == .left ? min(1, maximumX) : max(0, maximumX - 1),
            y: Int32(
                (UInt64(normalizedY) * UInt64(maximumY) + 32_767) / 65_535
            )
        )
        var newSession = Session(
            controlID: controlID,
            maximumX: maximumX,
            maximumY: maximumY,
            returnOpeningY: returnOpeningY,
            position: initial,
            entryEdge: entryEdge
        )
        let residualSamples = MousePayload.split(dx: residualX, dy: 0)
        for sample in residualSamples {
            _ = apply(sample, to: &newSession, detectsLeave: false)
        }

        var frames = [enterFrame(
            controlID: controlID,
            normalizedY: normalizedY,
            entryEdge: entryEdge
        )]
        let residual = MousePayload.split(
            dx: newSession.position.x - initial.x,
            dy: newSession.position.y - initial.y
        )
        frames.append(contentsOf: residual.chunks(ofCount: ClipboardWire.maximumMouseMoveBatch).map {
            MouseOutboundFrameSpec(
                kind: .mouseMove,
                payload: MousePayload.move(controlID: controlID, samples: Array($0)),
                controlID: controlID
            )
        })
        session = newSession
        resetWheel()
        return append(.frames(frames))
    }

    mutating func enqueueMove(
        controlID: UInt64,
        dx: Int32,
        dy: Int32
    ) -> MouseMailboxSubmission {
        guard var active = acceptedSession(controlID), dx != 0 || dy != 0 else {
            return .ignored
        }
        let start = active.position
        let samples = MousePayload.split(dx: dx, dy: dy)
        var forcesLeave = false
        for sample in samples {
            if apply(sample, to: &active, detectsLeave: true) {
                forcesLeave = true
                active.waitingForLeave = true
                active.acceptingInput = false
                break
            }
        }
        session = active
        let preservesHeldEdgeProbe = !forcesLeave
            && active.buttons != 0
            && isAtEntryEdge(active.position.x, session: active)
            && isMovingTowardEntryEdge(dx, session: active)
        let endsWithEdgeProbe = forcesLeave || preservesHeldEdgeProbe

        if case var .movement(previous)? = items.last,
           previous.controlID == controlID,
           !previous.endsWithEdgeProbe {
            previous.target = active.position
            previous.endsWithEdgeProbe = endsWithEdgeProbe
            items[items.count - 1] = .movement(previous)
            return drainResult()
        }
        guard start != active.position || endsWithEdgeProbe else { return .ignored }
        return append(.movement(Movement(
            controlID: controlID,
            start: start,
            target: active.position,
            maximumX: active.maximumX,
            entryEdge: active.entryEdge,
            endsWithEdgeProbe: endsWithEdgeProbe
        )))
    }

    mutating func enqueueButton(
        controlID: UInt64,
        button: UInt8,
        down: Bool
    ) -> MouseMailboxSubmission {
        guard var active = acceptedSession(controlID), (1...3).contains(button) else {
            return .ignored
        }
        let mask = UInt8(1 << (button - 1))
        if down {
            active.buttons |= mask
        } else {
            active.buttons &= ~mask
        }
        let expectsLeave = !down && active.buttons == 0
            && isAtEntryEdge(active.position.x, session: active)
            && active.recentMovedTowardEdge
            && active.returnOpeningY.contains(active.position.y)
        if expectsLeave {
            active.waitingForLeave = true
            active.acceptingInput = false
        }
        session = active
        return appendSessionFrame(
            kind: .mouseButton,
            payload: MousePayload.button(controlID: controlID, button: button, down: down),
            controlID: controlID
        )
    }

    mutating func enqueueWheel(
        controlID: UInt64,
        inputLines: Double,
        capturedAt: ContinuousClock.Instant = .now
    ) -> MouseMailboxSubmission {
        guard acceptedSession(controlID) != nil,
              inputLines.isFinite,
              inputLines != 0 else { return .ignored }
        if let lastWheelInputAt,
           lastWheelInputAt.duration(to: capturedAt) >= .milliseconds(100) {
            wheelAccumulator.reset()
        }
        lastWheelInputAt = capturedAt
        wheelAccumulator.add(inputLines)
        let lines = wheelAccumulator.drain()
        guard lines != 0 else { return .ignored }
        return appendSessionFrame(
            kind: .mouseWheel,
            payload: MousePayload.wheel(controlID: controlID, lines: lines),
            controlID: controlID
        )
    }

    mutating func enqueueKeyboard(
        controlID: UInt64,
        report: KeyboardReport
    ) -> MouseMailboxSubmission {
        guard keyboardSupported, var active = acceptedSession(controlID) else { return .ignored }
        active.keyboardReport = report
        session = active
        return appendSessionFrame(
            kind: .keyboardState,
            payload: MousePayload.keyboard(controlID: controlID, report: report),
            controlID: controlID
        )
    }

    mutating func enqueueHeartbeat(controlID: UInt64) -> MouseMailboxSubmission {
        guard let active = acceptedSession(controlID) else { return .ignored }
        let keyboard = keyboardSupported && !active.keyboardReport.isReleased
            ? active.keyboardReport : nil
        var frames = [MouseOutboundFrameSpec(
            kind: .mouseControlHeartbeat,
            payload: MousePayload.control(controlID: controlID),
            controlID: controlID
        )]
        if let keyboard {
            frames.append(MouseOutboundFrameSpec(
                kind: .keyboardState,
                payload: MousePayload.keyboard(controlID: controlID, report: keyboard),
                controlID: controlID
            ))
        }
        if case let .heartbeat(previousID, previousKeyboard, _)? = items.last,
           previousID == controlID,
           previousKeyboard == keyboard {
            items[items.count - 1] = .heartbeat(
                controlID: controlID,
                keyboardReport: keyboard,
                frames: frames
            )
            return drainResult()
        }
        return append(.heartbeat(
            controlID: controlID,
            keyboardReport: keyboard,
            frames: frames
        ))
    }

    mutating func enqueueRelease(controlID: UInt64) -> MouseMailboxSubmission {
        guard ready, !failed, var active = session,
              active.controlID == controlID,
              active.acceptingInput || active.waitingForLeave else { return .ignored }
        active.acceptingInput = false
        active.keyboardReport = .released
        session = active
        resetWheel()
        var frames: [MouseOutboundFrameSpec] = []
        if keyboardSupported {
            frames.append(MouseOutboundFrameSpec(
                kind: .keyboardState,
                payload: MousePayload.keyboard(controlID: controlID, report: .released),
                controlID: controlID
            ))
        }
        frames.append(MouseOutboundFrameSpec(
            kind: .mouseReleaseAll,
            payload: MousePayload.control(controlID: controlID),
            controlID: controlID
        ))
        return append(.frames(frames))
    }

    mutating func abortControl(controlID: UInt64) -> MouseMailboxSubmission {
        guard ready, !failed, var active = session,
              active.controlID == controlID else { return .ignored }
        active.acceptingInput = false
        active.keyboardReport = .released
        session = active
        resetWheel()
        items.removeAll { $0.belongs(to: controlID) }

        var frames: [MouseOutboundFrameSpec] = []
        if keyboardSupported {
            frames.append(MouseOutboundFrameSpec(
                kind: .keyboardState,
                payload: MousePayload.keyboard(controlID: controlID, report: .released),
                controlID: controlID
            ))
        }
        frames.append(MouseOutboundFrameSpec(
            kind: .mouseReleaseAll,
            payload: MousePayload.control(controlID: controlID),
            controlID: controlID
        ))
        items.insert(.frames(frames), at: 0)
        return drainResult()
    }

    mutating func finishSession(controlID: UInt64) {
        guard session?.controlID == controlID else { return }
        session = nil
        items.removeAll { $0.belongs(to: controlID) }
        resetWheel()
    }

    mutating func disableKeyboard() {
        keyboardSupported = false
        session?.keyboardReport = .released
    }

    mutating func dequeue(maximumFrameCount: Int) -> [MouseOutboundFrameSpec] {
        precondition(maximumFrameCount > 0)
        guard !failed, !items.isEmpty else {
            drainScheduled = false
            return []
        }
        var result: [MouseOutboundFrameSpec] = []
        while !items.isEmpty {
            let frames = items[0].frames
            if !result.isEmpty, result.count + frames.count > maximumFrameCount { break }
            items.removeFirst()
            if result.isEmpty, frames.count > maximumFrameCount {
                result.append(contentsOf: frames.prefix(maximumFrameCount))
                items.insert(.frames(Array(frames.dropFirst(maximumFrameCount))), at: 0)
                break
            }
            result.append(contentsOf: frames)
        }
        if result.isEmpty, items.isEmpty {
            drainScheduled = false
        }
        return result
    }

    var queuedItemCount: Int { items.count }
    var sessionPosition: (x: Int32, y: Int32)? {
        session.map { ($0.position.x, $0.position.y) }
    }
    var isWaitingForLeave: Bool { session?.waitingForLeave == true }

    func isAccepting(controlID: UInt64) -> Bool {
        acceptedSession(controlID) != nil
    }

    private func acceptedSession(_ controlID: UInt64) -> Session? {
        guard ready, !failed, let session,
              session.controlID == controlID,
              session.acceptingInput,
              !session.waitingForLeave else { return nil }
        return session
    }

    private mutating func apply(
        _ sample: MouseMoveSample,
        to session: inout Session,
        detectsLeave: Bool
    ) -> Bool {
        let previousX = session.position.x
        let proposedX = Int64(previousX) + Int64(sample.dx)
        let proposedY = Int32(
            (Int64(session.position.y) + Int64(sample.dy))
                .clamped(to: 0...Int64(session.maximumY))
        )
        let reachesEntryEdge: Bool
        switch session.entryEdge {
        case .left:
            reachesEntryEdge = (previousX > 0 && proposedX <= 0)
                || (previousX == 0 && sample.dx < 0)
        case .right:
            reachesEntryEdge = (previousX < session.maximumX
                    && proposedX >= Int64(session.maximumX))
                || (previousX == session.maximumX && sample.dx > 0)
        }
        if detectsLeave,
           reachesEntryEdge,
           !session.returnOpeningY.contains(proposedY) {
            session.position.x = session.entryEdge == .left
                ? min(1, session.maximumX)
                : max(0, session.maximumX - 1)
            session.position.y = proposedY
            if sample.dx != 0 {
                session.recentMovedTowardEdge = true
            }
            return false
        }
        session.position.x = Int32(
            proposedX.clamped(to: 0...Int64(session.maximumX))
        )
        session.position.y = proposedY
        if sample.dx != 0 {
            session.recentMovedTowardEdge = isMovingTowardEntryEdge(
                Int32(sample.dx),
                session: session
            )
        }
        return detectsLeave && session.buttons == 0 && reachesEntryEdge
    }

    private func isAtEntryEdge(_ horizontalPosition: Int32, session: Session) -> Bool {
        session.entryEdge == .left
            ? horizontalPosition == 0
            : horizontalPosition == session.maximumX
    }

    private func isMovingTowardEntryEdge(_ dx: Int32, session: Session) -> Bool {
        session.entryEdge == .left ? dx < 0 : dx > 0
    }

    private func enterFrame(
        controlID: UInt64,
        normalizedY: UInt16,
        entryEdge: HorizontalDisplaySide
    ) -> MouseOutboundFrameSpec {
        return MouseOutboundFrameSpec(
            kind: .directionalMouseEnter,
            payload: MousePayload.directionalEnter(
                controlID: controlID,
                normalizedY: normalizedY,
                entryEdge: entryEdge
            ),
            controlID: controlID
        )
    }

    private mutating func appendSessionFrame(
        kind: ClipboardMessageKind,
        payload: Data,
        controlID: UInt64
    ) -> MouseMailboxSubmission {
        append(.frames([
            MouseOutboundFrameSpec(
                kind: kind,
                payload: payload,
                controlID: controlID
            ),
        ]))
    }

    private mutating func append(_ item: Item) -> MouseMailboxSubmission {
        guard !failed else { return .ignored }
        guard items.count < maximumItems else { return fail() }
        items.append(item)
        return drainResult()
    }

    private mutating func drainResult() -> MouseMailboxSubmission {
        guard !drainScheduled else { return .queued }
        drainScheduled = true
        return .scheduleDrain
    }

    private mutating func fail() -> MouseMailboxSubmission {
        guard !failed else { return .ignored }
        failed = true
        return .failed
    }

    private mutating func resetWheel() {
        wheelAccumulator.reset()
        lastWheelInputAt = nil
    }
}

private extension Array {
    func chunks(ofCount count: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: self.count, by: count).map {
            self[$0..<Swift.min($0 + count, self.count)]
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
