import Foundation

struct MouseOutboundFrameSpec: Sendable {
    let kind: ClipboardMessageKind
    let payload: Data
    let controlID: UInt64?
}

enum MouseQueueSubmission: Equatable, Sendable {
    case ignored
    case queued
    case scheduleDrain
    case failed
}

/// A bounded, ordered transport queue. It deliberately has no remote cursor,
/// screen, edge, opening, wall, or leave model; those facts belong to Windows.
struct MouseTransportQueue: Sendable {
    private struct Session: Sendable {
        let controlID: UInt64
        var keyboardReport = KeyboardReport.released
        var acceptingInput = true
    }

    private enum Item: Sendable {
        case frame(MouseOutboundFrameSpec)
        case movement(controlID: UInt64, samples: [MouseMoveSample])
        case heartbeat(
            controlID: UInt64,
            keyboardReport: KeyboardReport?,
            frames: [MouseOutboundFrameSpec]
        )

        var frames: [MouseOutboundFrameSpec] {
            switch self {
            case let .frame(frame):
                [frame]
            case let .movement(controlID, samples):
                [MouseOutboundFrameSpec(
                    kind: .mouseMove,
                    payload: MousePayload.move(controlID: controlID, samples: samples),
                    controlID: controlID
                )]
            case let .heartbeat(_, _, frames):
                frames
            }
        }

        func belongs(to controlID: UInt64) -> Bool {
            switch self {
            case let .frame(frame): frame.controlID == controlID
            case let .movement(itemControlID, _): itemControlID == controlID
            case let .heartbeat(itemControlID, _, _): itemControlID == controlID
            }
        }
    }

    private let maximumItems: Int
    private var items: [Item] = []
    private var session: Session?
    private var ready = false
    private var keyboardSupported = false
    private var drainScheduled = false
    private var failed = false
    private var wheelAccumulator = MouseWheelAccumulator()
    private var lastWheelInputAt: ContinuousClock.Instant?

    init(maximumItems: Int = 64) {
        precondition(maximumItems > 0)
        self.maximumItems = maximumItems
        items.reserveCapacity(maximumItems)
    }

    mutating func activate(keyboardSupported: Bool) {
        self.keyboardSupported = keyboardSupported
        ready = true
        failed = false
    }

    mutating func deactivate() {
        ready = false
        failed = false
        session = nil
        items.removeAll(keepingCapacity: true)
        drainScheduled = false
        resetWheel()
    }

    mutating func enqueueConnectionFrame(
        kind: ClipboardMessageKind,
        payload: Data
    ) -> MouseQueueSubmission {
        guard ready else { return .ignored }
        return append(.frame(MouseOutboundFrameSpec(
            kind: kind,
            payload: payload,
            controlID: nil
        )))
    }

    mutating func beginSession(
        controlID: UInt64,
        routeID: UInt64,
        normalizedY: UInt16,
        residualX: Int32,
        entryEdge: HorizontalDisplaySide,
        returnOpeningY: ClosedRange<UInt16>
    ) -> MouseQueueSubmission {
        guard ready, controlID != 0, routeID != 0, session == nil else {
            return session == nil ? .ignored : fail()
        }
        session = Session(controlID: controlID)
        resetWheel()
        let enter = MouseOutboundFrameSpec(
            kind: .mouseEnterV2,
            payload: MousePayload.enterV2(
                controlID: controlID,
                routeID: routeID,
                normalizedY: normalizedY,
                openingLowerY: returnOpeningY.lowerBound,
                openingUpperY: returnOpeningY.upperBound,
                entryEdge: entryEdge
            ),
            controlID: controlID
        )
        let enterSubmission = append(.frame(enter))
        guard enterSubmission != .failed else { return .failed }
        let residualSubmission = enqueueMove(
            controlID: controlID,
            dx: residualX,
            dy: 0
        )
        return residualSubmission == .failed ? .failed : enterSubmission
    }

    mutating func enqueueMove(
        controlID: UInt64,
        dx: Int32,
        dy: Int32
    ) -> MouseQueueSubmission {
        guard accepts(controlID), dx != 0 || dy != 0 else { return .ignored }
        var pending = MousePayload.split(dx: dx, dy: dy)
        guard !pending.isEmpty else { return .ignored }

        if case let .movement(previousID, previousSamples)? = items.last,
           previousID == controlID,
           previousSamples.count < ClipboardWire.maximumMouseMoveBatch {
            let available = ClipboardWire.maximumMouseMoveBatch - previousSamples.count
            let appendedCount = min(available, pending.count)
            items[items.count - 1] = .movement(
                controlID: controlID,
                samples: previousSamples + pending.prefix(appendedCount)
            )
            pending.removeFirst(appendedCount)
        }
        let newItemCount = (pending.count + ClipboardWire.maximumMouseMoveBatch - 1)
            / ClipboardWire.maximumMouseMoveBatch
        guard items.count + newItemCount <= maximumItems else { return fail() }
        while !pending.isEmpty {
            let count = min(ClipboardWire.maximumMouseMoveBatch, pending.count)
            items.append(.movement(
                controlID: controlID,
                samples: Array(pending.prefix(count))
            ))
            pending.removeFirst(count)
        }
        return drainResult()
    }

    mutating func enqueueButton(
        controlID: UInt64,
        button: UInt8,
        down: Bool
    ) -> MouseQueueSubmission {
        guard accepts(controlID), (1...3).contains(button) else { return .ignored }
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
    ) -> MouseQueueSubmission {
        guard accepts(controlID), inputLines.isFinite, inputLines != 0 else { return .ignored }
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
    ) -> MouseQueueSubmission {
        guard keyboardSupported, var active = acceptedSession(controlID) else { return .ignored }
        active.keyboardReport = report
        session = active
        return appendSessionFrame(
            kind: .keyboardState,
            payload: MousePayload.keyboard(controlID: controlID, report: report),
            controlID: controlID
        )
    }

    mutating func enqueueHeartbeat(controlID: UInt64) -> MouseQueueSubmission {
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
           previousID == controlID, previousKeyboard == keyboard {
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

    mutating func enqueueRelease(controlID: UInt64) -> MouseQueueSubmission {
        guard ready, !failed, var active = session,
              active.controlID == controlID, active.acceptingInput else { return .ignored }
        active.acceptingInput = false
        active.keyboardReport = .released
        session = active
        resetWheel()
        return appendReleaseFrames(controlID: controlID)
    }

    mutating func abortControl(controlID: UInt64) -> MouseQueueSubmission {
        guard ready, !failed, var active = session,
              active.controlID == controlID else { return .ignored }
        active.acceptingInput = false
        active.keyboardReport = .released
        session = active
        resetWheel()
        items.removeAll { $0.belongs(to: controlID) }
        let release = releaseFrames(controlID: controlID).map(Item.frame)
        items.insert(contentsOf: release, at: 0)
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
        while !items.isEmpty, result.count < maximumFrameCount {
            let frames = items.removeFirst().frames
            let remaining = maximumFrameCount - result.count
            result.append(contentsOf: frames.prefix(remaining))
            if frames.count > remaining {
                items.insert(contentsOf: frames.dropFirst(remaining).map(Item.frame), at: 0)
            }
        }
        return result
    }

    var queuedItemCount: Int { items.count }

    func isAccepting(controlID: UInt64) -> Bool { accepts(controlID) }

    private func accepts(_ controlID: UInt64) -> Bool {
        acceptedSession(controlID) != nil
    }

    private func acceptedSession(_ controlID: UInt64) -> Session? {
        guard ready, !failed, let session,
              session.controlID == controlID, session.acceptingInput else { return nil }
        return session
    }

    private mutating func appendReleaseFrames(controlID: UInt64) -> MouseQueueSubmission {
        let frames = releaseFrames(controlID: controlID)
        guard items.count + frames.count <= maximumItems else { return fail() }
        items.append(contentsOf: frames.map(Item.frame))
        return drainResult()
    }

    private func releaseFrames(controlID: UInt64) -> [MouseOutboundFrameSpec] {
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
        return frames
    }

    private mutating func appendSessionFrame(
        kind: ClipboardMessageKind,
        payload: Data,
        controlID: UInt64
    ) -> MouseQueueSubmission {
        append(.frame(MouseOutboundFrameSpec(
            kind: kind,
            payload: payload,
            controlID: controlID
        )))
    }

    private mutating func append(_ item: Item) -> MouseQueueSubmission {
        guard !failed else { return .ignored }
        guard items.count < maximumItems else { return fail() }
        items.append(item)
        return drainResult()
    }

    private mutating func drainResult() -> MouseQueueSubmission {
        guard !drainScheduled else { return .queued }
        drainScheduled = true
        return .scheduleDrain
    }

    private mutating func fail() -> MouseQueueSubmission {
        guard !failed else { return .ignored }
        failed = true
        return .failed
    }

    private mutating func resetWheel() {
        wheelAccumulator.reset()
        lastWheelInputAt = nil
    }
}
