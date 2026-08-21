@preconcurrency import CoreGraphics

enum HorizontalDisplayHandoffDirection: String, Equatable, Sendable {
    case left
    case right
}

struct HorizontalDisplayHandoff: Equatable, Sendable {
    let sourceDisplayID: String
    let destinationDisplayID: String
    let direction: HorizontalDisplayHandoffDirection
    let crossingPoint: CGPoint
    let targetPoint: CGPoint
    let alignment: DisplayHandoffAlignment
    let physicalOffsetMM: CGFloat

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
    let crossingPoint: CGPoint
    let retainedPoint: CGPoint
    let beginsContact: Bool

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
    let seamX: CGFloat

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

    var nativeCornerPoint: CGPoint {
        let leftBottomToRightTop = abs(leftDisplay.frame.maxY - rightDisplay.frame.minY)
        let rightBottomToLeftTop = abs(rightDisplay.frame.maxY - leftDisplay.frame.minY)
        let y = leftBottomToRightTop <= rightBottomToLeftTop
            ? (leftDisplay.frame.maxY + rightDisplay.frame.minY) / 2
            : (rightDisplay.frame.maxY + leftDisplay.frame.minY) / 2
        return CGPoint(x: seamX, y: y)
    }
}

/// A fresh, validated corner-portal snapshot of every active macOS display.
struct HorizontalDisplayHandoffGeometry: Equatable, Sendable {
    private static let destinationInsetPoints: CGFloat = 12
    private static let adjacencyTolerancePoints: CGFloat = 2
    private static let maximumPortalOverlapPoints: CGFloat = 1

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
            let verticalOverlap = min(left.frame.maxY, right.frame.maxY)
                - max(left.frame.minY, right.frame.minY)
            let touchesAtCorner = abs(left.frame.maxY - right.frame.minY)
                    <= Self.adjacencyTolerancePoints
                || abs(right.frame.maxY - left.frame.minY)
                    <= Self.adjacencyTolerancePoints
            guard abs(left.frame.maxX - right.frame.minX)
                    <= Self.adjacencyTolerancePoints,
                  verticalOverlap <= Self.maximumPortalOverlapPoints,
                  touchesAtCorner else {
                return nil
            }
            seams.append(HorizontalDisplaySeam(
                leftDisplay: left,
                rightDisplay: right,
                seamX: right.frame.minX
            ))
        }
        return HorizontalDisplayHandoffGeometry(
            displays: ordered,
            seams: seams
        )
    }

    func handoff(
        at crossingPoint: CGPoint,
        seam: HorizontalDisplaySeam,
        direction: HorizontalDisplayHandoffDirection,
        alignment: DisplayHandoffAlignment
    ) -> HorizontalDisplayHandoff? {
        let source = seam.source(for: direction)
        let destination = seam.destination(for: direction)
        guard case let .mapped(mapping) = PhysicalVerticalMapper.map(
            sourceY: crossingPoint.y,
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
            crossingPoint: crossingPoint,
            targetPoint: CGPoint(x: targetX, y: mapping.targetY),
            alignment: alignment,
            physicalOffsetMM: mapping.physicalOffsetMM
        )
    }

    func displayID(at point: CGPoint) -> String? {
        let matches = displays.filter { display in
            point.x >= display.frame.minX && point.x < display.frame.maxX
                && point.y >= display.frame.minY && point.y < display.frame.maxY
        }
        // The right display owns a seam coordinate when the validated frames
        // overlap within the small adjacency tolerance.
        return matches.last?.id
    }
}

/// Tracks one authoritative cursor trajectory across adjacent macOS displays.
struct HorizontalDisplayHandoffState: Sendable {
    private static let portalEdgeActivationInsetPoints: CGFloat = 2
    private static let portalCornerActivationInsetPoints: CGFloat = 10
    private static let portalCornerZonePoints: CGFloat = 32
    private static let portalWallInsetPoints: CGFloat = 2
    private static let maximumStalePortalEvents = 4

    private struct Observation: Sendable {
        let displayID: String
        let point: CGPoint
    }

    private struct Crossing: Sendable {
        let seam: HorizontalDisplaySeam
        let point: CGPoint
        let direction: HorizontalDisplayHandoffDirection
    }

    private struct PendingPortalHandoff: Sendable {
        let destinationDisplayID: String
        let targetPoint: CGPoint
        var remainingStaleEvents: Int
    }

    private(set) var geometry: HorizontalDisplayHandoffGeometry?
    private(set) var configuration: DisplayHandoffConfiguration
    private var previousObservation: Observation?
    private var pendingPortalHandoff: PendingPortalHandoff?
    private var activePortalWall: HorizontalDisplayHandoffWall?

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
            pendingPortalHandoff = nil
            activePortalWall = nil
            return .none
        }
        if let stabilization = portalStabilization(
            geometry: geometry,
            location: location
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
            activePortalWall = nil
            observe(location: location)
            return .none
        }
        let handoff = geometry.handoff(
            at: crossing.point,
            seam: crossing.seam,
            direction: crossing.direction,
            alignment: configuration.alignment
        )
        guard let handoff, allowsHandoff else {
            return portalWall(
                crossing: crossing,
                location: location
            )
        }
        activePortalWall = nil
        self.previousObservation = Observation(
            displayID: handoff.destinationDisplayID,
            point: handoff.targetPoint
        )
        pendingPortalHandoff = PendingPortalHandoff(
            destinationDisplayID: handoff.destinationDisplayID,
            targetPoint: handoff.targetPoint,
            remainingStaleEvents: Self.maximumStalePortalEvents
        )
        return .handoff(handoff)
    }

    mutating func resetTracking(at location: CGPoint?) {
        previousObservation = nil
        pendingPortalHandoff = nil
        activePortalWall = nil
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
        let observedDeltaX = location.x - previous.point.x
        let directionalDeltaX = movementDeltaX == 0 ? observedDeltaX : movementDeltaX
        guard directionalDeltaX != 0 else { return nil }
        let direction: HorizontalDisplayHandoffDirection = directionalDeltaX < 0
            ? .left
            : .right
        guard let sourceDisplayID = geometry.displayID(at: location),
              sourceDisplayID == previous.displayID,
              let seam = geometry.seams.first(where: {
                  $0.source(for: direction).id == sourceDisplayID
              }) else {
            return nil
        }
        let source = seam.source(for: direction)
        let isNearNativeCorner = abs(location.y - seam.nativeCornerPoint.y)
            <= Self.portalCornerZonePoints
        let activationInset = isNearNativeCorner
            ? Self.portalCornerActivationInsetPoints
            : Self.portalEdgeActivationInsetPoints
        let reachedPortal: Bool
        switch direction {
        case .left:
            reachedPortal = location.x
                <= source.frame.minX + activationInset
        case .right:
            reachedPortal = location.x
                >= source.frame.maxX - activationInset
        }
        guard reachedPortal else { return nil }
        return Crossing(
            seam: seam,
            point: CGPoint(x: seam.seamX, y: location.y),
            direction: direction
        )
    }

    private mutating func portalStabilization(
        geometry: HorizontalDisplayHandoffGeometry,
        location: CGPoint
    ) -> HorizontalDisplayHandoffDecision? {
        guard var pending = pendingPortalHandoff else {
            return nil
        }
        if geometry.displayID(at: location) == pending.destinationDisplayID {
            pendingPortalHandoff = nil
            observe(location: location)
            return HorizontalDisplayHandoffDecision.none
        }
        guard pending.remainingStaleEvents > 0 else {
            pendingPortalHandoff = nil
            observe(location: location)
            return HorizontalDisplayHandoffDecision.none
        }
        pending.remainingStaleEvents -= 1
        pendingPortalHandoff = pending
        previousObservation = Observation(
            displayID: pending.destinationDisplayID,
            point: pending.targetPoint
        )
        return .stabilize(pending.targetPoint)
    }

    private mutating func portalWall(
        crossing: Crossing,
        location: CGPoint
    ) -> HorizontalDisplayHandoffDecision {
        let source = crossing.seam.source(for: crossing.direction)
        let destination = crossing.seam.destination(for: crossing.direction)
        let sameWall = activePortalWall?.sourceDisplayID == source.id
            && activePortalWall?.destinationDisplayID == destination.id
            && activePortalWall?.direction == crossing.direction
        let retainedX = crossing.direction == .left
            ? source.frame.minX + Self.portalWallInsetPoints
            : source.frame.maxX - Self.portalWallInsetPoints
        let wall = HorizontalDisplayHandoffWall(
            sourceDisplayID: source.id,
            destinationDisplayID: destination.id,
            direction: crossing.direction,
            crossingPoint: crossing.point,
            retainedPoint: CGPoint(
                x: retainedX,
                y: min(max(location.y, source.frame.minY), source.frame.maxY - 1)
            ),
            beginsContact: !sameWall
        )
        activePortalWall = wall
        observe(location: wall.retainedPoint)
        return .wall(wall)
    }
}
