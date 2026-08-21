import CoreGraphics
import XCTest

final class WindowsDisplayHandoffGeometryTests: XCTestCase {
    private let rightSharedPlan = SoftKVMTopologyPlan(sharedDisplaySide: .right)
    private let leftSharedPlan = SoftKVMTopologyPlan(sharedDisplaySide: .left)

    func testRightSharedDisplayUsesMainRightEdgeBeforeAndAfterDisconnect() throws {
        for displays in [
            currentLayoutDisplays(includePhilips: true),
            currentLayoutDisplays(includePhilips: false),
            targetLayoutDisplays(includePhilips: true),
            targetLayoutDisplays(includePhilips: false),
        ] {
            let geometry = try XCTUnwrap(resolveGeometry(
                sharedDisplayID: "philips",
                topologyPlan: rightSharedPlan,
                displays: displays
            ))

            XCTAssertTrue(geometry.macDisplay.isMain)
            XCTAssertEqual(geometry.windowsSeamX, geometry.macDisplay.frame.maxX)
            XCTAssertEqual(geometry.macEdge, .right)
            XCTAssertEqual(geometry.windowsEntryEdge, .left)
        }
    }

    func testKVMRouteSnapshotFreezesBaselineIdentityAndTopology() throws {
        let displays = currentLayoutDisplays(includePhilips: false)
        let geometry = try XCTUnwrap(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: displays
        ))
        let snapshot = KVMRouteSnapshot(
            routeID: 9,
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            geometry: geometry
        )

        XCTAssertEqual(snapshot.routeID, 9)
        XCTAssertEqual(snapshot.topologySignature.sharedDisplayID, "philips")
        XCTAssertEqual(snapshot.topologySignature.sharedDisplaySide, .right)
        XCTAssertEqual(snapshot.topologySignature.sourceDisplay, geometry.macDisplay)
        XCTAssertEqual(snapshot.topologySignature.activeDisplays, geometry.activeDisplays)

        let activeRoute = try XCTUnwrap(snapshot.activate(
            screenMetrics: MouseScreenMetrics(width: 3_840, height: 2_160),
            configuration: .defaultValue
        ))
        XCTAssertEqual(activeRoute.routeID, snapshot.routeID)
        XCTAssertEqual(activeRoute.geometry, geometry)
        XCTAssertEqual(activeRoute.session.activeDisplays, displays.sorted { $0.id < $1.id })
        XCTAssertEqual(activeRoute.makeMovementScaler().scaleX, activeRoute.movementScaleX)
    }

    func testLeftSharedDisplayUsesMainLeftEdgeBeforeAndAfterDisconnect() throws {
        for includePhilips in [true, false] {
            let geometry = try XCTUnwrap(resolveGeometry(
                sharedDisplayID: "philips",
                topologyPlan: leftSharedPlan,
                displays: leftPhilipsLayoutDisplays(includePhilips: includePhilips)
            ))

            XCTAssertEqual(geometry.macDisplay.id, "internal")
            XCTAssertEqual(geometry.windowsSeamX, 0)
            XCTAssertEqual(geometry.macEdge, .left)
            XCTAssertEqual(geometry.windowsEntryEdge, .right)
        }
    }

    func testDisconnectedGeometryRequiresPersistedPlanAndMatchingLocalSide() {
        let displays = leftPhilipsLayoutDisplays(includePhilips: false)

        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: nil,
            displays: displays
        ))
        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: displays
        ))
        XCTAssertNotNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: displays
        ))
    }

    func testActiveSharedDisplayMustMatchPersistedSide() {
        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: targetLayoutDisplays(includePhilips: true)
        ))
    }

    func testPortalRoutingAcceptsRemainingUShapedMacPair() throws {
        let displays = [
            makeDisplayHandoffTestDisplay(
                "internal", x: 0, width: 100, height: 100,
                physicalHeightMM: 222.5, isMain: true
            ),
            makeDisplayHandoffTestDisplay(
                "viewsonic", x: 100, y: -100, width: 120, height: 100,
                physicalHeightMM: 335.664
            ),
        ]

        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: displays
        ))
        let geometry = try XCTUnwrap(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: displays,
            allowsPortalRouting: true
        ))

        XCTAssertEqual(geometry.macEdge, .left)
        XCTAssertEqual(geometry.windowsEntryEdge, .right)
    }

    func testPortalRoutingAcceptsCompleteUShapedMacTopology() throws {
        let displays = [
            makeDisplayHandoffTestDisplay(
                "philips", x: -160, y: -100, width: 160, height: 100,
                physicalHeightMM: 335.664
            ),
            makeDisplayHandoffTestDisplay(
                "internal", x: 0, width: 100, height: 100,
                physicalHeightMM: 222.5, isMain: true
            ),
            makeDisplayHandoffTestDisplay(
                "viewsonic", x: 100, y: -100, width: 120, height: 100,
                physicalHeightMM: 335.664
            ),
        ]

        let geometry = try XCTUnwrap(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: displays,
            allowsPortalRouting: true
        ))

        XCTAssertEqual(geometry.macDisplay.id, "internal")
        XCTAssertEqual(geometry.macEdge, .left)
    }

    func testPortalRoutingRejectsSeparatedUShapedMacPair() {
        let displays = [
            makeDisplayHandoffTestDisplay(
                "internal", x: 0, width: 100, height: 100,
                physicalHeightMM: 222.5, isMain: true
            ),
            makeDisplayHandoffTestDisplay(
                "viewsonic", x: 100, y: -103, width: 120, height: 100,
                physicalHeightMM: 335.664
            ),
        ]

        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: displays,
            allowsPortalRouting: true
        ))
    }

    func testSeamUsesEntireMacMainHeightAfterPhilipsDisconnects() throws {
        let geometry = try XCTUnwrap(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: targetLayoutDisplays(includePhilips: false)
        ))

        XCTAssertTrue(geometry.containsWindowsSeam(atY: geometry.macDisplay.frame.minY))
        XCTAssertTrue(geometry.containsWindowsSeam(atY: geometry.macDisplay.frame.maxY - 1))
        XCTAssertFalse(geometry.containsWindowsSeam(atY: geometry.macDisplay.frame.maxY))
    }

    func testCrossingResidualMirrorsAtLeftAndRightSeams() throws {
        let right = try XCTUnwrap(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: targetLayoutDisplays(includePhilips: false)
        ))
        let left = try XCTUnwrap(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: leftSharedPlan,
            displays: leftPhilipsLayoutDisplays(includePhilips: false)
        ))

        XCTAssertEqual(right.crossingResidualX(locationX: 1_727, deltaX: 4), 3)
        XCTAssertEqual(left.crossingResidualX(locationX: 1, deltaX: -4), -3)
        XCTAssertNil(right.crossingResidualX(locationX: 1_727, deltaX: -4))
        XCTAssertNil(left.crossingResidualX(locationX: 1, deltaX: 4))
    }

    func testRejectsGapExtraDisplayRotationAndMirroring() {
        let main = makeDisplayHandoffTestDisplay(
            "main", x: 0, width: 100, physicalHeightMM: 200, isMain: true
        )
        let left = makeDisplayHandoffTestDisplay(
            "left", x: -100, width: 100, physicalHeightMM: 200
        )
        let philips = makeDisplayHandoffTestDisplay(
            "philips", x: 100, width: 100, physicalHeightMM: 200
        )

        XCTAssertNotNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: [left, main, philips]
        ))
        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: [
                makeDisplayHandoffTestDisplay(
                    "left", x: -103, width: 100, physicalHeightMM: 200
                ),
                main,
            ]
        ))
        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: [
                left,
                main,
                philips,
                makeDisplayHandoffTestDisplay(
                    "extra", x: 200, width: 100, physicalHeightMM: 200
                ),
            ]
        ))
        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: [left, makeDisplayHandoffTestDisplay(
                "main", x: 0, width: 100, physicalHeightMM: 200,
                isMain: true, rotationDegrees: 90
            )]
        ))
        XCTAssertNil(resolveGeometry(
            sharedDisplayID: "philips",
            topologyPlan: rightSharedPlan,
            displays: [left, makeDisplayHandoffTestDisplay(
                "main", x: 0, width: 100, physicalHeightMM: 200,
                isMain: true, isMirrored: true
            )]
        ))
    }

    private func resolveGeometry(
        sharedDisplayID: String?,
        topologyPlan: SoftKVMTopologyPlan?,
        displays: [CrossScreenDisplay],
        allowsPortalRouting: Bool = false
    ) -> WindowsDisplayHandoffGeometry? {
        WindowsDisplayHandoffGeometry.resolve(
            sharedDisplayID: sharedDisplayID,
            topologyPlan: topologyPlan,
            displays: displays,
            allowsPortalRouting: allowsPortalRouting
        )
    }

    private func currentLayoutDisplays(includePhilips: Bool) -> [CrossScreenDisplay] {
        var displays = [
            makeDisplayHandoffTestDisplay(
                "internal", x: -1_728, width: 1_728, height: 1_117,
                physicalHeightMM: 222.5
            ),
            makeDisplayHandoffTestDisplay(
                "viewsonic", x: 0, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664, isMain: true
            ),
        ]
        if includePhilips {
            displays.append(makeDisplayHandoffTestDisplay(
                "philips", x: 2_048, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ))
        }
        return displays
    }

    private func targetLayoutDisplays(includePhilips: Bool) -> [CrossScreenDisplay] {
        var displays = [
            makeDisplayHandoffTestDisplay(
                "viewsonic", x: -2_048, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ),
            makeDisplayHandoffTestDisplay(
                "internal", x: 0, width: 1_728, height: 1_117,
                physicalHeightMM: 222.5, isMain: true
            ),
        ]
        if includePhilips {
            displays.append(makeDisplayHandoffTestDisplay(
                "philips", x: 1_728, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ))
        }
        return displays
    }

    private func leftPhilipsLayoutDisplays(includePhilips: Bool) -> [CrossScreenDisplay] {
        var displays = [
            makeDisplayHandoffTestDisplay(
                "internal", x: 0, width: 1_728, height: 1_117,
                physicalHeightMM: 222.5, isMain: true
            ),
            makeDisplayHandoffTestDisplay(
                "viewsonic", x: 1_728, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ),
        ]
        if includePhilips {
            displays.append(makeDisplayHandoffTestDisplay(
                "philips", x: -2_048, width: 2_048, height: 1_152,
                physicalHeightMM: 335.664
            ))
        }
        return displays
    }
}
final class WindowsDisplayHandoffMappingTests: XCTestCase {
    private let remoteMetrics = MouseScreenMetrics(width: 3_840, height: 2_160)

    func testEqualPhysicalHeightRoundTripsWithinOneRemotePixel() {
        let session = makeSession(macHeightMM: 335.664, configuration: .defaultValue)

        for normalizedY in [UInt16(0), UInt16.max / 2, UInt16.max] {
            let returned = session.returnMapping(windowsNormalizedY: normalizedY)
            let entry = session.entryMapping(macY: returned.point.y)
            let pixelError = abs(
                Double(entry.normalizedY) - Double(normalizedY)
            ) / Double(UInt16.max) * Double(remoteMetrics.height - 1)

            XCTAssertLessThanOrEqual(pixelError, 1.01)
        }
    }

    func testBottomAlignmentClampsWindowsTopOverflowToBuiltInTop() {
        let session = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: true, alignment: .bottom)
        )

        let result = session.returnMapping(windowsNormalizedY: 0)

        XCTAssertEqual(result.method, .clampedToEdge)
        XCTAssertEqual(result.point.y, session.macDisplay.frame.minY)
    }

    func testTopAlignmentClampsWindowsBottomOverflowToBuiltInBottom() {
        let session = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: true, alignment: .top)
        )

        let result = session.returnMapping(windowsNormalizedY: UInt16.max)

        XCTAssertEqual(result.method, .clampedToEdge)
        XCTAssertEqual(result.point.y, session.macDisplay.frame.maxY - 1)
    }

    func testBottomAlignmentRestrictsWindowsReturnToPhysicalOpening() {
        let session = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: true, alignment: .bottom)
        )
        let opening = session.windowsReturnOpeningY

        XCTAssertGreaterThan(opening.lowerBound, 0)
        XCTAssertEqual(opening.upperBound, Int32(remoteMetrics.height - 1))
        XCTAssertNotEqual(
            session.returnMapping(
                windowsNormalizedY: UInt16(
                    (UInt64(opening.lowerBound) * UInt64(UInt16.max))
                        / UInt64(remoteMetrics.height - 1)
                )
            ).method,
            .clampedToEdge
        )
    }

    func testTopAlignmentRestrictsWindowsReturnToPhysicalOpening() {
        let session = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: true, alignment: .top)
        )
        let opening = session.windowsReturnOpeningY

        XCTAssertEqual(opening.lowerBound, 0)
        XCTAssertLessThan(opening.upperBound, Int32(remoteMetrics.height - 1))
    }

    func testFallbackMappingLeavesEntireWindowsEdgeOpen() {
        let disabled = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: false, alignment: .bottom)
        )
        let unavailable = makeSession(macHeightMM: nil, configuration: .defaultValue)
        let fullRange = Int32.zero...Int32(remoteMetrics.height - 1)

        XCTAssertEqual(disabled.windowsReturnOpeningY, fullRange)
        XCTAssertEqual(unavailable.windowsReturnOpeningY, fullRange)
        XCTAssertEqual(disabled.windowsReturnOpeningNormalizedY, 0...UInt16.max)
        XCTAssertEqual(unavailable.windowsReturnOpeningNormalizedY, 0...UInt16.max)
    }

    func testReturnOpeningUsesTheSameInclusiveNormalizedCoordinateSpaceAsEntry() {
        let session = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: true, alignment: .bottom)
        )
        let pixels = session.windowsReturnOpeningY
        let normalized = session.windowsReturnOpeningNormalizedY

        XCTAssertGreaterThan(normalized.lowerBound, 0)
        XCTAssertEqual(normalized.upperBound, UInt16.max)
        XCTAssertEqual(
            normalized.lowerBound,
            UInt16(
                (UInt64(pixels.lowerBound) * UInt64(UInt16.max)
                    + UInt64(remoteMetrics.height - 1) / 2)
                    / UInt64(remoteMetrics.height - 1)
            )
        )
    }

    func testLeftMacSeamReturnsInsideLeftEdge() {
        let base = makeSession(macHeightMM: 222.5, configuration: .defaultValue)
        let session = WindowsDisplayHandoffSession(
            macDisplay: base.macDisplay,
            macEdge: .left,
            windowsEntryEdge: .right,
            activeDisplays: base.activeDisplays,
            windowsScreenMetrics: base.windowsScreenMetrics,
            configuration: base.configuration,
            windowsPhysicalHeightMM: base.windowsPhysicalHeightMM
        )

        XCTAssertEqual(
            session.returnMapping(windowsNormalizedY: UInt16.max / 2).point.x,
            session.macDisplay.frame.minX + 1
        )
    }

    func testMacEntryClampsSourceAreaOutsidePhilipsPhysicalHeight() {
        let session = makeSession(
            macHeightMM: 400,
            configuration: DisplayHandoffConfiguration(enabled: true, alignment: .bottom)
        )

        let result = session.entryMapping(macY: session.macDisplay.frame.minY)

        XCTAssertEqual(result.method, .clampedToEdge)
        XCTAssertEqual(result.normalizedY, 0)
    }

    func testDisabledAndMissingPhysicalDataUsePercentageMapping() {
        let disabled = makeSession(
            macHeightMM: 222.5,
            configuration: DisplayHandoffConfiguration(enabled: false, alignment: .bottom)
        )
        let unavailable = makeSession(
            macHeightMM: nil,
            configuration: .defaultValue
        )

        for session in [disabled, unavailable] {
            let entry = session.entryMapping(macY: session.macDisplay.frame.midY)
            let returned = session.returnMapping(windowsNormalizedY: UInt16.max / 2)
            XCTAssertEqual(entry.method, .percentageFallback)
            XCTAssertLessThanOrEqual(
                abs(Int(entry.normalizedY) - Int(UInt16.max / 2)),
                1
            )
            XCTAssertEqual(returned.method, .percentageFallback)
            XCTAssertEqual(returned.point.y, session.macDisplay.frame.midY, accuracy: 1)
        }
    }

    func testResolverUsesFrozenDisplayOnlyWhileTopologyMatches() throws {
        let session = makeSession(macHeightMM: 222.5, configuration: .defaultValue)
        let matching = session.macDisplay
        let normal = try XCTUnwrap(WindowsReturnPointResolver.point(
            session: session,
            windowsNormalizedY: UInt16.max / 2,
            currentDisplays: [matching]
        ))
        XCTAssertNotEqual(normal.method, .safeMainCenter)

        let changedFrame = makeDisplayHandoffTestDisplay(
            matching.id,
            x: matching.frame.minX + 100,
            width: matching.frame.width,
            height: matching.frame.height,
            physicalHeightMM: matching.physicalHeightMM,
            isMain: true
        )
        let fallback = try XCTUnwrap(WindowsReturnPointResolver.point(
            session: session,
            windowsNormalizedY: UInt16.max / 2,
            currentDisplays: [changedFrame]
        ))

        XCTAssertEqual(fallback.method, .safeMainCenter)
        XCTAssertEqual(fallback.point, CGPoint(x: changedFrame.frame.midX, y: changedFrame.frame.midY))
    }

    func testResolverFallsBackWhenAnotherDisplayMovesDuringSession() throws {
        let main = makeDisplayHandoffTestDisplay(
            "main", x: 0, width: 1_728, height: 1_117,
            physicalHeightMM: 222.5, isMain: true
        )
        let left = makeDisplayHandoffTestDisplay(
            "left", x: -2_048, width: 2_048, height: 1_152,
            physicalHeightMM: 335.664
        )
        let session = WindowsDisplayHandoffSession(
            macDisplay: main,
            activeDisplays: [left, main],
            windowsScreenMetrics: remoteMetrics,
            configuration: .defaultValue,
            windowsPhysicalHeightMM: 335.664
        )
        let movedLeft = makeDisplayHandoffTestDisplay(
            "left", x: -2_100, width: 2_048, height: 1_152,
            physicalHeightMM: 335.664
        )

        let result = try XCTUnwrap(WindowsReturnPointResolver.point(
            session: session,
            windowsNormalizedY: UInt16.max / 2,
            currentDisplays: [movedLeft, main]
        ))

        XCTAssertEqual(result.method, .safeMainCenter)
        XCTAssertEqual(result.point, CGPoint(x: main.frame.midX, y: main.frame.midY))
    }

    func testMissingRecordedDisplayFallsBackToCurrentMainCenter() throws {
        let session = makeSession(macHeightMM: 222.5, configuration: .defaultValue)
        let currentMain = makeDisplayHandoffTestDisplay(
            "new-main", x: 2_000, y: 100, width: 1_200, height: 900,
            physicalHeightMM: 300, isMain: true
        )

        let result = try XCTUnwrap(WindowsReturnPointResolver.point(
            session: session,
            windowsNormalizedY: 0,
            currentDisplays: [currentMain]
        ))

        XCTAssertEqual(result.method, .safeMainCenter)
        XCTAssertEqual(result.point, CGPoint(x: 2_600, y: 550))
    }

    func testNoCurrentDisplaySkipsCursorWarp() {
        XCTAssertNil(WindowsReturnPointResolver.point(
            session: nil,
            windowsNormalizedY: 0,
            currentDisplays: []
        ))
    }

    func testInvalidCurrentMainFrameSkipsCursorWarp() {
        let invalidMain = makeDisplayHandoffTestDisplay(
            "main",
            x: 0,
            width: 1,
            physicalHeightMM: 200,
            isMain: true
        )

        XCTAssertNil(WindowsReturnPointResolver.point(
            session: nil,
            windowsNormalizedY: 0,
            currentDisplays: [invalidMain]
        ))
    }

    private func makeSession(
        macHeightMM: CGFloat?,
        configuration: DisplayHandoffConfiguration
    ) -> WindowsDisplayHandoffSession {
        let macDisplay = makeDisplayHandoffTestDisplay(
            "main",
            x: 0,
            y: 40,
            width: 1_728,
            height: 1_117,
            physicalHeightMM: macHeightMM,
            isMain: true
        )
        return WindowsDisplayHandoffSession(
            macDisplay: macDisplay,
            activeDisplays: [macDisplay],
            windowsScreenMetrics: remoteMetrics,
            configuration: configuration,
            windowsPhysicalHeightMM: 335.664
        )
    }
}
