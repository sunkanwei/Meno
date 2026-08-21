import CoreGraphics
import XCTest

func requireDisplayHandoff(
    from decision: HorizontalDisplayHandoffDecision,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> HorizontalDisplayHandoff {
    guard case let .handoff(handoff) = decision else {
        XCTFail("Expected a display handoff", file: file, line: line)
        throw HorizontalDisplayHandoffTestError.expectedHandoff
    }
    return handoff
}

func makePortalDisplayHandoffFixtureGeometry(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> HorizontalDisplayHandoffGeometry {
    let displays = [
        makeDisplayHandoffTestDisplay(
            "left", x: -2_048, y: -1_152, width: 2_048, height: 1_152,
            physicalHeightMM: 335.664
        ),
        makeDisplayHandoffTestDisplay(
            "internal", x: 0, y: 0, width: 1_496, height: 967,
            physicalHeightMM: 222.5, isMain: true
        ),
        makeDisplayHandoffTestDisplay(
            "right", x: 1_496, y: 967, width: 2_048, height: 1_152,
            physicalHeightMM: 335.664
        )
    ]
    return try XCTUnwrap(
        HorizontalDisplayHandoffGeometry.resolve(
            displays: displays,
            routingOrderIDs: ["left", "internal", "right"]
        ),
        file: file,
        line: line
    )
}

func makeDisplayHandoffTestDisplay(
    _ id: String,
    x horizontalPosition: CGFloat,
    y verticalPosition: CGFloat = 0,
    width: CGFloat,
    height: CGFloat = 100,
    physicalHeightMM: CGFloat? = nil,
    isMain: Bool = false,
    rotationDegrees: Double = 0,
    isMirrored: Bool = false
) -> CrossScreenDisplay {
    CrossScreenDisplay(
        id: id,
        name: id,
        frame: CGRect(
            x: horizontalPosition,
            y: verticalPosition,
            width: width,
            height: height
        ),
        physicalHeightMM: physicalHeightMM,
        isMain: isMain,
        rotationDegrees: rotationDegrees,
        isMirrored: isMirrored
    )
}

func physicalHeightAboveBottomMM(
    _ verticalPosition: CGFloat,
    on display: CrossScreenDisplay,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> CGFloat {
    let heightMM = try XCTUnwrap(display.physicalHeightMM, file: file, line: line)
    return (display.frame.maxY - verticalPosition) / display.frame.height * heightMM
}

func physicalDistanceBelowTopMM(
    _ verticalPosition: CGFloat,
    on display: CrossScreenDisplay,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> CGFloat {
    let heightMM = try XCTUnwrap(display.physicalHeightMM, file: file, line: line)
    return (verticalPosition - display.frame.minY) / display.frame.height * heightMM
}

private enum HorizontalDisplayHandoffTestError: Error {
    case expectedHandoff
}
