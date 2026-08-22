@preconcurrency import CoreGraphics

enum HorizontalDisplayHandoffDirection: String, Equatable, Sendable {
    case left
    case right
}

struct HorizontalDisplayHandoff: Equatable, Sendable {
    let sourceDisplayID: String
    let destinationDisplayID: String
    let direction: HorizontalDisplayHandoffDirection
    let targetPoint: CGPoint
    let alignment: DisplayHandoffAlignment

    func apply(to event: CGEvent) {
        event.location = targetPoint
        event.setDoubleValueField(.mouseEventDeltaX, value: 0)
        event.setDoubleValueField(.mouseEventDeltaY, value: 0)
    }
}

enum HorizontalDisplayHandoffDecision: Equatable, Sendable {
    case none
    case handoff(HorizontalDisplayHandoff)
    case stabilize(CGPoint)
    case wall(HorizontalDisplayHandoffWall)
}

struct HorizontalDisplayHandoffWall: Equatable, Sendable {
    let sourceDisplayID: String
    let destinationDisplayID: String
    let direction: HorizontalDisplayHandoffDirection
    let retainedPoint: CGPoint

    func apply(to event: CGEvent) {
        event.location = retainedPoint
        event.setDoubleValueField(.mouseEventDeltaX, value: 0)
    }
}

func allowsAutomaticDisplayHandoff(
    type: CGEventType,
    localButtons: UInt8
) -> Bool {
    type == .mouseMoved && localButtons == 0
}

func allowsLocalDisplayHandoff(
    type: CGEventType,
    localButtons: UInt8
) -> Bool {
    if allowsAutomaticDisplayHandoff(type: type, localButtons: localButtons) {
        return true
    }
    return type == .leftMouseDragged
        && localButtons == 1
}

func handlesLocalDisplayBoundary(
    type: CGEventType,
    localButtons: UInt8
) -> Bool {
    if allowsLocalDisplayHandoff(
        type: type,
        localButtons: localButtons
    ) {
        return true
    }
    return type == .mouseMoved || type == .leftMouseDragged
        || type == .rightMouseDragged || type == .otherMouseDragged
}

struct HorizontalDisplaySeam: Equatable, Sendable {
    let leftDisplay: CrossScreenDisplay
    let rightDisplay: CrossScreenDisplay

    func source(
        for direction: HorizontalDisplayHandoffDirection
    ) -> CrossScreenDisplay {
        direction == .left ? rightDisplay : leftDisplay
    }

    func destination(
        for direction: HorizontalDisplayHandoffDirection
    ) -> CrossScreenDisplay {
        direction == .left ? leftDisplay : rightDisplay
    }
}

/// A fresh, validated native horizontal snapshot of every active macOS display.
struct HorizontalDisplayHandoffGeometry: Equatable, Sendable {
    private static let destinationInsetPoints: CGFloat = 12

    let displays: [CrossScreenDisplay]
    let seams: [HorizontalDisplaySeam]

    static func resolve(
        displays: [CrossScreenDisplay],
        routingOrderIDs: [String]
    ) -> HorizontalDisplayHandoffGeometry? {
        guard displays.count >= 2,
              routingOrderIDs.count == displays.count,
              Set(displays.map(\.id)).count == displays.count,
              Set(routingOrderIDs).count == routingOrderIDs.count,
              Set(displays.map(\.id)) == Set(routingOrderIDs),
              displays.filter(\.isMain).count == 1,
              displays.allSatisfy(\.supportsHorizontalHandoff) else {
            return nil
        }
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let ordered = routingOrderIDs.compactMap { displaysByID[$0] }
        guard ordered.count == displays.count else { return nil }

        var seams: [HorizontalDisplaySeam] = []
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            guard left.isImmediatelyLeft(of: right) else {
                return nil
            }
            seams.append(HorizontalDisplaySeam(
                leftDisplay: left,
                rightDisplay: right
            ))
        }
        return HorizontalDisplayHandoffGeometry(
            displays: ordered,
            seams: seams
        )
    }

    func handoff(
        sourceY: CGFloat,
        seam: HorizontalDisplaySeam,
        direction: HorizontalDisplayHandoffDirection,
        alignment: DisplayHandoffAlignment
    ) -> HorizontalDisplayHandoff? {
        let source = seam.source(for: direction)
        let destination = seam.destination(for: direction)
        guard case let .mapped(mapping) = PhysicalVerticalMapper.map(
            sourceY: sourceY,
            source: PhysicalDisplayGeometry(
                frame: source.frame,
                heightMM: source.physicalHeightMM
            ),
            destination: PhysicalDisplayGeometry(
                frame: destination.frame,
                heightMM: destination.physicalHeightMM
            ),
            alignment: alignment
        ) else {
            return nil
        }
        let targetX: CGFloat
        switch direction {
        case .left:
            targetX = max(
                destination.frame.maxX - Self.destinationInsetPoints,
                destination.frame.minX + 1
            )
        case .right:
            targetX = min(
                destination.frame.minX + Self.destinationInsetPoints,
                destination.frame.maxX - 1
            )
        }
        return HorizontalDisplayHandoff(
            sourceDisplayID: source.id,
            destinationDisplayID: destination.id,
            direction: direction,
            targetPoint: CGPoint(x: targetX, y: mapping.targetY),
            alignment: alignment
        )
    }

    func displayID(at point: CGPoint) -> String? {
        let matches = displays.filter { display in
            point.x >= display.frame.minX && point.x < display.frame.maxX
                && point.y >= display.frame.minY && point.y < display.frame.maxY
        }
        // The routing order resolves the small frame overlap allowed by the
        // shared adjacency tolerance in favor of the right-hand display.
        return matches.last?.id
    }
}

/// Tracks one authoritative cursor trajectory across adjacent macOS displays.
struct HorizontalDisplayHandoffState: Sendable {
    private static let edgeActivationInsetPoints: CGFloat = 2
    private static let wallInsetPoints: CGFloat = 2
    private static let maximumStaleHandoffEvents = 4

    private struct Observation: Sendable {
        let displayID: String
        let point: CGPoint
    }

    private struct Crossing: Sendable {
        let seam: HorizontalDisplaySeam
        let sourceY: CGFloat
        let direction: HorizontalDisplayHandoffDirection
    }

    private struct PendingHandoff: Sendable {
        let sourceDisplayID: String
        let destinationDisplayID: String
        let direction: HorizontalDisplayHandoffDirection
        let targetPoint: CGPoint
        var remainingStaleEvents: Int
    }

    private(set) var geometry: HorizontalDisplayHandoffGeometry?
    private(set) var configuration: DisplayHandoffConfiguration
    private var previousObservation: Observation?
    private var pendingHandoff: PendingHandoff?

    init(
        geometry: HorizontalDisplayHandoffGeometry? = nil,
        configuration: DisplayHandoffConfiguration = .defaultValue
    ) {
        self.geometry = geometry
        self.configuration = configuration
    }

    mutating func updateGeometry(
        _ geometry: HorizontalDisplayHandoffGeometry?,
        pointerLocation: CGPoint? = nil
    ) {
        self.geometry = geometry
        resetTracking(at: pointerLocation)
    }

    @discardableResult
    mutating func updateConfiguration(
        _ configuration: DisplayHandoffConfiguration,
        pointerLocation: CGPoint? = nil
    ) -> Bool {
        guard self.configuration != configuration else { return false }
        self.configuration = configuration
        resetTracking(at: pointerLocation)
        return true
    }

    mutating func decision(
        location: CGPoint,
        movementDeltaX: CGFloat,
        allowsHandoff: Bool = true
    ) -> HorizontalDisplayHandoffDecision {
        guard configuration.enabled, let geometry else {
            previousObservation = nil
            pendingHandoff = nil
            return .none
        }
        if let stabilization = handoffStabilization(
            geometry: geometry,
            location: location,
            movementDeltaX: movementDeltaX
        ) {
            return stabilization
        }
        guard let previousObservation else {
            observe(location: location)
            return .none
        }
        guard let crossing = crossing(
            geometry: geometry,
            from: previousObservation,
            to: location,
            movementDeltaX: movementDeltaX
        ) else {
            observe(location: location)
            return .none
        }
        let handoff = geometry.handoff(
            sourceY: crossing.sourceY,
            seam: crossing.seam,
            direction: crossing.direction,
            alignment: configuration.alignment
        )
        guard let handoff, allowsHandoff else {
            return boundaryWall(
                crossing: crossing,
                location: location
            )
        }
        self.previousObservation = Observation(
            displayID: handoff.destinationDisplayID,
            point: handoff.targetPoint
        )
        pendingHandoff = PendingHandoff(
            sourceDisplayID: handoff.sourceDisplayID,
            destinationDisplayID: handoff.destinationDisplayID,
            direction: handoff.direction,
            targetPoint: handoff.targetPoint,
            remainingStaleEvents: Self.maximumStaleHandoffEvents
        )
        return .handoff(handoff)
    }

    mutating func resetTracking(at location: CGPoint?) {
        previousObservation = nil
        pendingHandoff = nil
        if let location {
            observe(location: location)
        }
    }

    mutating func observe(location: CGPoint) {
        guard configuration.enabled,
              let geometry,
              let displayID = geometry.displayID(at: location) else {
            previousObservation = nil
            return
        }
        previousObservation = Observation(displayID: displayID, point: location)
    }

    private func crossing(
        geometry: HorizontalDisplayHandoffGeometry,
        from previous: Observation,
        to location: CGPoint,
        movementDeltaX: CGFloat
    ) -> Crossing? {
        guard let currentDisplayID = geometry.displayID(at: location) else {
            return nil
        }
        let observedDeltaX = location.x - previous.point.x
        let directionalDeltaX = currentDisplayID == previous.displayID
            ? (movementDeltaX == 0 ? observedDeltaX : movementDeltaX)
            : observedDeltaX
        guard directionalDeltaX != 0 else { return nil }
        let direction: HorizontalDisplayHandoffDirection = directionalDeltaX < 0
            ? .left
            : .right
        guard let seam = geometry.seams.first(where: {
            $0.source(for: direction).id == previous.displayID
        }) else {
            return nil
        }
        let source = seam.source(for: direction)
        let reachedBoundary: Bool
        switch direction {
        case .left:
            reachedBoundary = location.x
                <= source.frame.minX + Self.edgeActivationInsetPoints
        case .right:
            reachedBoundary = location.x
                >= source.frame.maxX - Self.edgeActivationInsetPoints
        }
        guard reachedBoundary else { return nil }
        return Crossing(
            seam: seam,
            sourceY: location.y,
            direction: direction
        )
    }

    private mutating func handoffStabilization(
        geometry: HorizontalDisplayHandoffGeometry,
        location: CGPoint,
        movementDeltaX: CGFloat
    ) -> HorizontalDisplayHandoffDecision? {
        guard var pending = pendingHandoff else {
            return nil
        }
        let currentDisplayID = geometry.displayID(at: location)
        if currentDisplayID == pending.destinationDisplayID {
            pendingHandoff = nil
            observe(location: location)
            return HorizontalDisplayHandoffDecision.none
        }
        let reversesDirection = pending.direction == .right
            ? movementDeltaX < 0
            : movementDeltaX > 0
        if currentDisplayID == pending.sourceDisplayID,
           reversesDirection {
            pendingHandoff = nil
            previousObservation = Observation(
                displayID: pending.destinationDisplayID,
                point: pending.targetPoint
            )
            return nil
        }
        guard pending.remainingStaleEvents > 0 else {
            pendingHandoff = nil
            observe(location: location)
            return HorizontalDisplayHandoffDecision.none
        }
        pending.remainingStaleEvents -= 1
        pendingHandoff = pending
        previousObservation = Observation(
            displayID: pending.destinationDisplayID,
            point: pending.targetPoint
        )
        return .stabilize(pending.targetPoint)
    }

    private mutating func boundaryWall(
        crossing: Crossing,
        location: CGPoint
    ) -> HorizontalDisplayHandoffDecision {
        let source = crossing.seam.source(for: crossing.direction)
        let destination = crossing.seam.destination(for: crossing.direction)
        let retainedX = crossing.direction == .left
            ? source.frame.minX + Self.wallInsetPoints
            : source.frame.maxX - Self.wallInsetPoints
        let wall = HorizontalDisplayHandoffWall(
            sourceDisplayID: source.id,
            destinationDisplayID: destination.id,
            direction: crossing.direction,
            retainedPoint: CGPoint(
                x: retainedX,
                y: min(max(location.y, source.frame.minY), source.frame.maxY - 1)
            )
        )
        observe(location: wall.retainedPoint)
        return .wall(wall)
    }
}
