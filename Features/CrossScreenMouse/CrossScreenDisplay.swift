import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// A display snapshot using Core Graphics global coordinates.
struct CrossScreenDisplay: Identifiable, Equatable, Sendable {
    private static let adjacencyTolerancePoints: CGFloat = 2
    private static let minimumVerticalOverlapPoints: CGFloat = 1

    let id: String
    let runtimeID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let physicalHeightMM: CGFloat?
    let isMain: Bool
    let rotationDegrees: Double
    let isMirrored: Bool

    init(
        id: String,
        runtimeID: CGDirectDisplayID = 0,
        name: String,
        frame: CGRect,
        physicalHeightMM: CGFloat? = nil,
        isMain: Bool,
        rotationDegrees: Double = 0,
        isMirrored: Bool = false
    ) {
        self.id = id
        self.runtimeID = runtimeID
        self.name = name
        self.frame = frame
        self.physicalHeightMM = physicalHeightMM
        self.isMain = isMain
        self.rotationDegrees = rotationDegrees
        self.isMirrored = isMirrored
    }

    @MainActor
    static func currentDisplays() -> [CrossScreenDisplay] {
        let mainDisplayID = CGMainDisplayID()
        var displays: [CrossScreenDisplay] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return []
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
                  let uuidString = CFUUIDCreateString(nil, uuid) as String? else {
                return []
            }
            let frame = CGDisplayBounds(displayID)
            displays.append(CrossScreenDisplay(
                id: uuidString,
                runtimeID: displayID,
                name: screen.localizedName,
                frame: frame,
                physicalHeightMM: CrossScreenDisplayCalibration.physicalHeightMM(
                    reportedHeightMM: CGDisplayScreenSize(displayID).height,
                    displayBoundsHeight: frame.height,
                    vendorID: CGDisplayVendorNumber(displayID),
                    modelID: CGDisplayModelNumber(displayID)
                ),
                isMain: displayID == mainDisplayID,
                rotationDegrees: CGDisplayRotation(displayID),
                isMirrored: CGDisplayIsInMirrorSet(displayID) != 0
            ))
        }
        return displays.sorted { first, second in
            if first.frame.minX == second.frame.minX {
                return first.frame.minY < second.frame.minY
            }
            return first.frame.minX < second.frame.minX
        }
    }

    var hasValidFrame: Bool {
        frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 2 && frame.height > 2
    }

    var supportsHorizontalHandoff: Bool {
        hasValidFrame
            && abs(rotationDegrees) < 0.001
            && !isMirrored
    }

    func isImmediatelyLeft(of rightDisplay: CrossScreenDisplay) -> Bool {
        guard hasValidFrame, rightDisplay.hasValidFrame else { return false }
        let verticalOverlap = min(frame.maxY, rightDisplay.frame.maxY)
            - max(frame.minY, rightDisplay.frame.minY)
        return abs(frame.maxX - rightDisplay.frame.minX)
                <= Self.adjacencyTolerancePoints
            && verticalOverlap > Self.minimumVerticalOverlapPoints
    }
}

enum CrossScreenDisplayCalibration {
    private static let plausibleHeightMM: ClosedRange<CGFloat> = 50...2_000
    private static let pointsPerMillimeterAt72DPI: CGFloat = 72 / 25.4
    private static let fallbackTolerance: CGFloat = 0.02

    static func physicalHeightMM(
        reportedHeightMM: CGFloat,
        displayBoundsHeight: CGFloat,
        vendorID: UInt32,
        modelID: UInt32
    ) -> CGFloat? {
        if let fixedHeight = FixedDisplayConfiguration.activeHeightMM(
            vendorID: vendorID,
            modelID: modelID
        ) {
            return fixedHeight
        }
        guard reportedHeightMM.isFinite,
              plausibleHeightMM.contains(reportedHeightMM),
              displayBoundsHeight.isFinite,
              displayBoundsHeight > 0 else { return nil }
        let fallbackHeightMM = displayBoundsHeight / pointsPerMillimeterAt72DPI
        if abs(reportedHeightMM - fallbackHeightMM) / fallbackHeightMM
            <= fallbackTolerance {
            return nil
        }
        return reportedHeightMM
    }
}
