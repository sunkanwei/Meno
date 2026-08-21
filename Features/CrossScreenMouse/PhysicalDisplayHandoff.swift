@preconcurrency import CoreGraphics

enum DisplayHandoffAlignment: String, CaseIterable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }
}

struct DisplayHandoffConfiguration: Equatable, Sendable {
    let enabled: Bool
    let alignment: DisplayHandoffAlignment

    static let defaultValue = DisplayHandoffConfiguration(
        enabled: true,
        alignment: .bottom
    )
}

struct PhysicalVerticalMapping: Equatable, Sendable {
    let targetY: CGFloat
    let physicalOffsetMM: CGFloat
}

struct PhysicalDisplayGeometry: Equatable, Sendable {
    let frame: CGRect
    let heightMM: CGFloat?
}

enum PhysicalVerticalMappingResult: Equatable, Sendable {
    case mapped(PhysicalVerticalMapping)
    case outside(PhysicalVerticalMapping)
    case unavailable
}

enum PhysicalVerticalMapper {
    private static let edgeTolerancePoints: CGFloat = 1

    static func map(
        sourceY: CGFloat,
        source: PhysicalDisplayGeometry,
        destination: PhysicalDisplayGeometry,
        alignment: DisplayHandoffAlignment
    ) -> PhysicalVerticalMappingResult {
        guard valid(frame: source.frame),
              valid(frame: destination.frame),
              let sourceHeightMM = source.heightMM,
              let destinationHeightMM = destination.heightMM,
              valid(heightMM: sourceHeightMM),
              valid(heightMM: destinationHeightMM),
              sourceY.isFinite,
              sourceY >= source.frame.minY - edgeTolerancePoints,
              sourceY <= source.frame.maxY + edgeTolerancePoints else {
            return .unavailable
        }

        let clampedSourceY = sourceY.clamped(
            to: source.frame.minY...(source.frame.maxY - 1)
        )
        let physicalOffsetMM: CGFloat
        switch alignment {
        case .top:
            physicalOffsetMM = (clampedSourceY - source.frame.minY)
                / source.frame.height * sourceHeightMM
        case .bottom:
            physicalOffsetMM = (source.frame.maxY - clampedSourceY)
                / source.frame.height * sourceHeightMM
        }

        let destinationOffsetPoints = physicalOffsetMM / destinationHeightMM
            * destination.frame.height
        let rawTargetY: CGFloat
        switch alignment {
        case .top:
            rawTargetY = destination.frame.minY + destinationOffsetPoints
        case .bottom:
            rawTargetY = destination.frame.maxY - destinationOffsetPoints
        }
        let mapping = PhysicalVerticalMapping(
            targetY: rawTargetY.clamped(
                to: destination.frame.minY...(destination.frame.maxY - 1)
            ),
            physicalOffsetMM: physicalOffsetMM
        )

        let excessMM = physicalOffsetMM - destinationHeightMM
        guard excessMM > 0 else { return .mapped(mapping) }
        let toleranceMM = destinationHeightMM / destination.frame.height
            * edgeTolerancePoints
        return excessMM <= toleranceMM ? .mapped(mapping) : .outside(mapping)
    }

    private static func valid(frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 2 && frame.height > 2
    }

    private static func valid(heightMM: CGFloat) -> Bool {
        heightMM.isFinite && heightMM > 0
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
