@preconcurrency import CoreGraphics

enum WindowsVerticalMappingMethod: String, Equatable, Sendable {
    case physical
    case clampedToEdge = "clamped"
    case percentageFallback = "percentage"
    case safeMainCenter = "safe-main-center"
}

struct WindowsVerticalMapping: Equatable, Sendable {
    let normalizedY: UInt16
    let method: WindowsVerticalMappingMethod
    let physicalOffsetMM: CGFloat?
}

struct WindowsCursorReturn: Equatable, Sendable {
    let point: CGPoint
    let method: WindowsVerticalMappingMethod
    let physicalOffsetMM: CGFloat?
}

/// A validated Mac seam and the corresponding entry edge on Windows.
struct WindowsDisplayHandoffGeometry: Equatable, Sendable {
    let macDisplay: CrossScreenDisplay
    let macEdge: HorizontalDisplaySide
    let windowsEntryEdge: HorizontalDisplaySide
    let activeDisplays: [CrossScreenDisplay]

    var windowsSeamX: CGFloat {
        macEdge == .left ? macDisplay.frame.minX : macDisplay.frame.maxX
    }

    var entryInstruction: String {
        let displayName = macDisplay.isMain ? "Mac 主屏" : macDisplay.name
        let edgeName = macEdge == .left ? "左边缘" : "右边缘"
        return "从 \(displayName)\(edgeName)进入 Windows。"
    }

    func containsWindowsSeam(atY verticalPosition: CGFloat) -> Bool {
        verticalPosition >= macDisplay.frame.minY
            && verticalPosition < macDisplay.frame.maxY
    }

    func movesTowardWindows(deltaX: CGFloat) -> Bool {
        macEdge == .left ? deltaX < 0 : deltaX > 0
    }

    func crossingResidualX(locationX: CGFloat, deltaX: CGFloat) -> CGFloat? {
        guard movesTowardWindows(deltaX: deltaX) else { return nil }
        let seamX = windowsSeamX
        let crossesFromReportedPosition: Bool
        let crossesFromUpdatedPosition: Bool
        switch macEdge {
        case .left:
            crossesFromReportedPosition = locationX >= seamX
                && locationX + deltaX <= seamX
            crossesFromUpdatedPosition = locationX <= seamX
                && locationX - deltaX >= seamX
        case .right:
            crossesFromReportedPosition = locationX <= seamX
                && locationX + deltaX >= seamX
            crossesFromUpdatedPosition = locationX >= seamX
                && locationX - deltaX <= seamX
        }
        let crossingWidth = max(abs(deltaX) + 2, 4)
        guard crossesFromReportedPosition || crossesFromUpdatedPosition,
              abs(locationX - seamX) <= crossingWidth else {
            return nil
        }
        let residual = crossesFromReportedPosition
            ? locationX + deltaX - seamX
            : locationX - seamX
        return macEdge == .left ? min(0, residual) : max(0, residual)
    }

    func session(
        screenMetrics: MouseScreenMetrics,
        configuration: DisplayHandoffConfiguration
    ) -> WindowsDisplayHandoffSession? {
        guard screenMetrics.width > 2, screenMetrics.height > 2 else { return nil }
        return WindowsDisplayHandoffSession(
            macDisplay: macDisplay,
            macEdge: macEdge,
            windowsEntryEdge: windowsEntryEdge,
            activeDisplays: activeDisplays,
            windowsScreenMetrics: screenMetrics,
            configuration: configuration,
            windowsPhysicalHeightMM: FixedDisplayConfiguration.philipsActiveHeightMM
        )
    }

    static func resolve(
        sharedDisplayID: String?,
        topologyPlan: SoftKVMTopologyPlan?,
        displays: [CrossScreenDisplay],
        allowsPortalRouting: Bool
    ) -> WindowsDisplayHandoffGeometry? {
        guard let sharedDisplayID, let topologyPlan else { return nil }
        let shared = displays.first(where: { $0.id == sharedDisplayID })
        let localDisplays = displays.filter { $0.id != sharedDisplayID }
        guard Set(displays.map(\.id)).count == displays.count,
              localDisplays.count == 2,
              let main = localDisplays.only(where: \.isMain),
              let other = localDisplays.only(where: { $0.id != main.id }),
              main.supportsHorizontalHandoff,
              other.supportsHorizontalHandoff,
              side(
                  of: other,
                  relativeTo: main,
                  allowsPortalRouting: allowsPortalRouting
              ) == topologyPlan.localDisplaySide else {
            return nil
        }
        if let shared {
            guard !shared.isMain,
                  shared.supportsHorizontalHandoff,
                  side(
                      of: shared,
                      relativeTo: main,
                      allowsPortalRouting: allowsPortalRouting
                  ) == topologyPlan.sharedDisplaySide else {
                return nil
            }
        }

        return WindowsDisplayHandoffGeometry(
            macDisplay: main,
            macEdge: topologyPlan.macEntryEdge,
            windowsEntryEdge: topologyPlan.windowsEntryEdge,
            activeDisplays: displays.sorted { $0.id < $1.id }
        )
    }

    private static func side(
        of display: CrossScreenDisplay,
        relativeTo main: CrossScreenDisplay,
        allowsPortalRouting: Bool
    ) -> HorizontalDisplaySide? {
        if display.isImmediatelyLeft(of: main) { return .left }
        if main.isImmediatelyLeft(of: display) { return .right }
        guard allowsPortalRouting else { return nil }
        let tolerance: CGFloat = 2
        let touchesAtVerticalCorner =
            abs(display.frame.maxY - main.frame.minY) <= tolerance
            || abs(main.frame.maxY - display.frame.minY) <= tolerance
        if abs(display.frame.maxX - main.frame.minX) <= tolerance,
           touchesAtVerticalCorner {
            return .left
        }
        if abs(main.frame.maxX - display.frame.minX) <= tolerance,
           touchesAtVerticalCorner {
            return .right
        }
        return nil
    }
}

struct WindowsDisplayHandoffSession: Equatable, Sendable {
    let macDisplay: CrossScreenDisplay
    let macEdge: HorizontalDisplaySide
    let windowsEntryEdge: HorizontalDisplaySide
    let activeDisplays: [CrossScreenDisplay]
    let windowsScreenMetrics: MouseScreenMetrics
    let configuration: DisplayHandoffConfiguration
    let windowsPhysicalHeightMM: CGFloat

    init(
        macDisplay: CrossScreenDisplay,
        macEdge: HorizontalDisplaySide = .right,
        windowsEntryEdge: HorizontalDisplaySide = .left,
        activeDisplays: [CrossScreenDisplay],
        windowsScreenMetrics: MouseScreenMetrics,
        configuration: DisplayHandoffConfiguration,
        windowsPhysicalHeightMM: CGFloat
    ) {
        self.macDisplay = macDisplay
        self.macEdge = macEdge
        self.windowsEntryEdge = windowsEntryEdge
        self.activeDisplays = activeDisplays
        self.windowsScreenMetrics = windowsScreenMetrics
        self.configuration = configuration
        self.windowsPhysicalHeightMM = windowsPhysicalHeightMM
    }

    func entryMapping(macY: CGFloat) -> WindowsVerticalMapping {
        guard configuration.enabled else { return percentageEntryMapping(macY: macY) }
        let result = PhysicalVerticalMapper.map(
            sourceY: macY,
            source: PhysicalDisplayGeometry(
                frame: macDisplay.frame,
                heightMM: macDisplay.physicalHeightMM
            ),
            destination: PhysicalDisplayGeometry(
                frame: windowsFrame,
                heightMM: windowsPhysicalHeightMM
            ),
            alignment: configuration.alignment
        )
        switch result {
        case let .mapped(mapping):
            return WindowsVerticalMapping(
                normalizedY: normalizedY(forWindowsY: mapping.targetY),
                method: .physical,
                physicalOffsetMM: mapping.physicalOffsetMM
            )
        case let .outside(mapping):
            return WindowsVerticalMapping(
                normalizedY: normalizedY(forWindowsY: mapping.targetY),
                method: .clampedToEdge,
                physicalOffsetMM: mapping.physicalOffsetMM
            )
        case .unavailable:
            return percentageEntryMapping(macY: macY)
        }
    }

    func returnMapping(windowsNormalizedY: UInt16) -> WindowsCursorReturn {
        guard configuration.enabled else {
            return percentageReturnMapping(windowsNormalizedY: windowsNormalizedY)
        }
        let result = returnMappingResult(
            windowsY: windowsY(normalizedY: windowsNormalizedY)
        )
        switch result {
        case let .mapped(mapping):
            return cursorReturn(mapping: mapping, method: .physical)
        case let .outside(mapping):
            return cursorReturn(mapping: mapping, method: .clampedToEdge)
        case .unavailable:
            return percentageReturnMapping(windowsNormalizedY: windowsNormalizedY)
        }
    }

    var windowsReturnOpeningY: ClosedRange<Int32> {
        let maximumY = Int32(clamping: windowsScreenMetrics.height - 1)
        let fullRange = Int32.zero...maximumY
        guard configuration.enabled else { return fullRange }

        func isMapped(_ y: Int32) -> Bool? {
            switch returnMappingResult(windowsY: CGFloat(y)) {
            case .mapped:
                return true
            case .outside:
                return false
            case .unavailable:
                return nil
            }
        }
        switch configuration.alignment {
        case .bottom:
            guard isMapped(0) == false else { return fullRange }
            var lower = Int32.zero
            var upper = maximumY
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if isMapped(middle) == true {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return lower...maximumY
        case .top:
            guard isMapped(maximumY) == false else { return fullRange }
            var lower = Int32.zero
            var upper = maximumY
            while lower < upper {
                let middle = lower + (upper - lower + 1) / 2
                if isMapped(middle) == true {
                    lower = middle
                } else {
                    upper = middle - 1
                }
            }
            return Int32.zero...lower
        }
    }

    func matches(currentDisplays: [CrossScreenDisplay]) -> Bool {
        guard currentDisplays.count == activeDisplays.count,
              Set(currentDisplays.map(\.id)).count == currentDisplays.count else {
            return false
        }
        return activeDisplays.allSatisfy { expected in
            guard let current = currentDisplays.first(where: { $0.id == expected.id }) else {
                return false
            }
            return current.frame == expected.frame
                && current.isMain == expected.isMain
                && current.rotationDegrees == expected.rotationDegrees
                && current.isMirrored == expected.isMirrored
        }
    }

    private var windowsFrame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: CGFloat(windowsScreenMetrics.width),
            height: CGFloat(windowsScreenMetrics.height)
        )
    }

    private func windowsY(normalizedY: UInt16) -> CGFloat {
        CGFloat(normalizedY) / CGFloat(UInt16.max) * (windowsFrame.height - 1)
    }

    private func returnMappingResult(
        windowsY: CGFloat
    ) -> PhysicalVerticalMappingResult {
        PhysicalVerticalMapper.map(
            sourceY: windowsY,
            source: PhysicalDisplayGeometry(
                frame: windowsFrame,
                heightMM: windowsPhysicalHeightMM
            ),
            destination: PhysicalDisplayGeometry(
                frame: macDisplay.frame,
                heightMM: macDisplay.physicalHeightMM
            ),
            alignment: configuration.alignment
        )
    }

    private func percentageEntryMapping(macY: CGFloat) -> WindowsVerticalMapping {
        let fraction = ((macY - macDisplay.frame.minY) / macDisplay.frame.height)
            .clamped(to: 0...1)
        return WindowsVerticalMapping(
            normalizedY: UInt16((fraction * CGFloat(UInt16.max)).rounded()),
            method: .percentageFallback,
            physicalOffsetMM: nil
        )
    }

    private func percentageReturnMapping(windowsNormalizedY: UInt16) -> WindowsCursorReturn {
        let fraction = CGFloat(windowsNormalizedY) / CGFloat(UInt16.max)
        let targetY = (macDisplay.frame.minY + fraction * macDisplay.frame.height)
            .clamped(to: macDisplay.frame.minY...(macDisplay.frame.maxY - 1))
        return WindowsCursorReturn(
            point: CGPoint(x: macReturnX, y: targetY),
            method: .percentageFallback,
            physicalOffsetMM: nil
        )
    }

    private func normalizedY(forWindowsY windowsY: CGFloat) -> UInt16 {
        let fraction = (windowsY / (windowsFrame.height - 1)).clamped(to: 0...1)
        return UInt16((fraction * CGFloat(UInt16.max)).rounded())
    }

    private func cursorReturn(
        mapping: PhysicalVerticalMapping,
        method: WindowsVerticalMappingMethod
    ) -> WindowsCursorReturn {
        WindowsCursorReturn(
            point: CGPoint(x: macReturnX, y: mapping.targetY),
            method: method,
            physicalOffsetMM: mapping.physicalOffsetMM
        )
    }

    private var macReturnX: CGFloat {
        macEdge == .left ? macDisplay.frame.minX + 1 : macDisplay.frame.maxX - 1
    }
}

enum WindowsReturnPointResolver {
    static func point(
        session: WindowsDisplayHandoffSession?,
        windowsNormalizedY: UInt16,
        currentDisplays: [CrossScreenDisplay]
    ) -> WindowsCursorReturn? {
        if let session,
           session.matches(currentDisplays: currentDisplays) {
            return session.returnMapping(windowsNormalizedY: windowsNormalizedY)
        }
        guard let main = currentDisplays.only(where: \.isMain),
              main.hasValidFrame else {
            return nil
        }
        return WindowsCursorReturn(
            point: CGPoint(
                x: min(max(main.frame.midX, main.frame.minX + 1), main.frame.maxX - 1),
                y: min(max(main.frame.midY, main.frame.minY + 1), main.frame.maxY - 1)
            ),
            method: .safeMainCenter,
            physicalOffsetMM: nil
        )
    }
}

private extension Collection {
    func only(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        let matches = try filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
