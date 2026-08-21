import CoreGraphics
import XCTest

final class PhysicalDisplayHandoffTests: XCTestCase {
    func testTopAndBottomAlignmentPreservePhysicalOffsets() throws {
        let source = CGRect(x: 0, y: -80, width: 2_048, height: 1_152)
        let destination = CGRect(x: -1_728, y: 120, width: 1_728, height: 1_117)

        for alignment in DisplayHandoffAlignment.allCases {
            let sourceY: CGFloat = alignment == .top ? 263.4 : 808.6
            let result = PhysicalVerticalMapper.map(
                sourceY: sourceY,
                source: geometry(source, heightMM: 335.664),
                destination: geometry(destination, heightMM: 222.5),
                alignment: alignment
            )
            let mapping = try requireMapped(result)
            let destinationOffset = physicalOffset(
                verticalPosition: mapping.targetY,
                frame: destination,
                heightMM: 222.5,
                alignment: alignment
            )

            XCTAssertEqual(destinationOffset, mapping.physicalOffsetMM, accuracy: 0.001)
        }
    }

    func testEqualHeightMappingRoundTripsWithinOnePoint() throws {
        let first = CGRect(x: 0, y: -60, width: 200, height: 120)
        let second = CGRect(x: 200, y: 90, width: 300, height: 240)

        for alignment in DisplayHandoffAlignment.allCases {
            for sourceY in [first.minY, first.midY, first.maxY - 1] {
                let forward = try XCTUnwrap(PhysicalVerticalMapper.map(
                    sourceY: sourceY,
                    source: geometry(first, heightMM: 300),
                    destination: geometry(second, heightMM: 300),
                    alignment: alignment
                ).mappedValue)
                let backward = try XCTUnwrap(PhysicalVerticalMapper.map(
                    sourceY: forward.targetY,
                    source: geometry(second, heightMM: 300),
                    destination: geometry(first, heightMM: 300),
                    alignment: alignment
                ).mappedValue)

                XCTAssertEqual(backward.targetY, sourceY, accuracy: 1)
            }
        }
    }

    func testTruePhysicalOverflowIsReportedWithNearestEdge() throws {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let destination = CGRect(x: 100, y: 30, width: 100, height: 100)

        let bottom = PhysicalVerticalMapper.map(
            sourceY: 0,
            source: geometry(source, heightMM: 300),
            destination: geometry(destination, heightMM: 200),
            alignment: .bottom
        )
        guard case let .outside(bottomMapping) = bottom else {
            return XCTFail("Expected bottom-aligned overflow")
        }
        XCTAssertEqual(bottomMapping.targetY, destination.minY)

        let top = PhysicalVerticalMapper.map(
            sourceY: 99,
            source: geometry(source, heightMM: 300),
            destination: geometry(destination, heightMM: 200),
            alignment: .top
        )
        guard case let .outside(topMapping) = top else {
            return XCTFail("Expected top-aligned overflow")
        }
        XCTAssertEqual(topMapping.targetY, destination.maxY - 1)
    }

    func testOneDestinationPointOverflowUsesEdgeTolerance() {
        let source = CGRect(x: 0, y: 0, width: 100, height: 100)
        let destination = CGRect(x: 100, y: 0, width: 100, height: 100)

        let onePointOverflowY = source.maxY - 202 / 300 * source.height
        let tolerated = PhysicalVerticalMapper.map(
            sourceY: onePointOverflowY,
            source: geometry(source, heightMM: 300),
            destination: geometry(destination, heightMM: 200),
            alignment: .bottom
        )
        guard case .mapped = tolerated else {
            return XCTFail("One destination point should be tolerated")
        }

        let outside = PhysicalVerticalMapper.map(
            sourceY: 31,
            source: geometry(source, heightMM: 300),
            destination: geometry(destination, heightMM: 200),
            alignment: .bottom
        )
        guard case .outside = outside else {
            return XCTFail("Larger overflow should stay explicit")
        }
    }

    func testRejectsInvalidPhysicalDataFramesAndSourcePosition() {
        let validFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let invalidInputs: [PhysicalVerticalMappingResult] = [
            PhysicalVerticalMapper.map(
                sourceY: 50,
                source: geometry(validFrame, heightMM: nil),
                destination: geometry(validFrame, heightMM: 200),
                alignment: .bottom
            ),
            PhysicalVerticalMapper.map(
                sourceY: 50,
                source: geometry(
                    CGRect(x: 0, y: 0, width: 1, height: 100),
                    heightMM: 200
                ),
                destination: geometry(validFrame, heightMM: 200),
                alignment: .bottom
            ),
            PhysicalVerticalMapper.map(
                sourceY: -2,
                source: geometry(validFrame, heightMM: 200),
                destination: geometry(validFrame, heightMM: 200),
                alignment: .bottom
            )
        ]

        XCTAssertTrue(invalidInputs.allSatisfy { $0 == .unavailable })
    }

    private func physicalOffset(
        verticalPosition: CGFloat,
        frame: CGRect,
        heightMM: CGFloat,
        alignment: DisplayHandoffAlignment
    ) -> CGFloat {
        switch alignment {
        case .top:
            (verticalPosition - frame.minY) / frame.height * heightMM
        case .bottom:
            (frame.maxY - verticalPosition) / frame.height * heightMM
        }
    }

    private func geometry(_ frame: CGRect, heightMM: CGFloat?) -> PhysicalDisplayGeometry {
        PhysicalDisplayGeometry(frame: frame, heightMM: heightMM)
    }

    private func requireMapped(
        _ result: PhysicalVerticalMappingResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PhysicalVerticalMapping {
        try XCTUnwrap(result.mappedValue, file: file, line: line)
    }
}

private extension PhysicalVerticalMappingResult {
    var mappedValue: PhysicalVerticalMapping? {
        guard case let .mapped(mapping) = self else { return nil }
        return mapping
    }
}
