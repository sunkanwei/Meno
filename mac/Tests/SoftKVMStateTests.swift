import AppKit
@preconcurrency import CoreGraphics
import Foundation
import XCTest

final class SoftKVMStateTests: XCTestCase {
    func testOnlyNotificationCenterWindowsAreIgnoredDuringDisplaySwitch() {
        XCTAssertTrue(isIgnoredSystemWindowForDisplaySwitch(
            bundleIdentifier: "com.apple.notificationcenterui"
        ))
        XCTAssertFalse(isIgnoredSystemWindowForDisplaySwitch(bundleIdentifier: nil))
        XCTAssertFalse(isIgnoredSystemWindowForDisplaySwitch(
            bundleIdentifier: "com.apple.TextEdit"
        ))
    }

    func testOnlyVerifiedFinderDesktopShellIsIgnoredDuringDisplaySwitch() {
        XCTAssertTrue(isFinderDesktopShellWindow(
            bundleIdentifier: "com.apple.finder",
            title: "",
            role: kAXWindowRole as String,
            subrole: "AXUnknown",
            positionSettable: false,
            sizeSettable: false,
            coversAssignedDisplay: true
        ))

        for variation in [
            ("com.apple.finder", "Downloads", nil, false, false, true),
            ("com.apple.finder", "", kAXStandardWindowSubrole as String?, false, false, true),
            ("com.apple.finder", "", nil, true, false, true),
            ("com.apple.finder", "", nil, false, true, true),
            ("com.apple.finder", "", nil, false, false, false),
            ("com.example.app", "", nil, false, false, true)
        ] {
            XCTAssertFalse(isFinderDesktopShellWindow(
                bundleIdentifier: variation.0,
                title: variation.1,
                role: kAXWindowRole as String,
                subrole: variation.2,
                positionSettable: variation.3,
                sizeSettable: variation.4,
                coversAssignedDisplay: variation.5
            ))
        }
    }

    func testProtectedViewSonicModeRemainsExact() {
        XCTAssertTrue(FixedDisplayConfiguration.isProtectedViewSonicMode(
            DisplayModeRecord(
                logicalWidth: 2_048,
                logicalHeight: 1_152,
                pixelWidth: 4_096,
                pixelHeight: 2_304,
                refreshRate: 60,
                isHiDPI: true
            )
        ))
        XCTAssertFalse(FixedDisplayConfiguration.isProtectedViewSonicMode(
            DisplayModeRecord(
                logicalWidth: 1_920,
                logicalHeight: 1_080,
                pixelWidth: 3_840,
                pixelHeight: 2_160,
                refreshRate: 60,
                isHiDPI: true
            )
        ))
    }

    func testMacBaselineCapturesSharedDisplayOnEitherSide() throws {
        let right = try XCTUnwrap(SoftKVMMacBaseline.resolve([
            display(.viewSonic, id: 2, x: -120, width: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.philips, id: 3, x: 100, width: 160)
        ]))
        let left = try XCTUnwrap(SoftKVMMacBaseline.resolve([
            display(.philips, id: 3, x: -160, width: 160),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, width: 120)
        ]))

        XCTAssertEqual(right.mainDisplay.role, .builtIn)
        XCTAssertEqual(right.localDisplay.role, .viewSonic)
        XCTAssertEqual(right.topologyPlan.sharedDisplaySide, .right)
        XCTAssertEqual(left.topologyPlan.sharedDisplaySide, .left)
    }

    func testMacBaselineSupportsViewSonicAsMainDisplay() throws {
        let baseline = try XCTUnwrap(SoftKVMMacBaseline.resolve([
            display(.builtIn, id: 1, x: -100, width: 100),
            display(.viewSonic, id: 2, isMain: true, x: 0, width: 120),
            display(.philips, id: 3, x: 120, width: 160)
        ]))

        XCTAssertEqual(baseline.mainDisplay.role, .viewSonic)
        XCTAssertEqual(baseline.localDisplay.role, .builtIn)
        XCTAssertEqual(baseline.topologyPlan.sharedDisplaySide, .right)
    }

    func testWindowsTopologyValidatesLocalPairWithoutInferringSharedSide() throws {
        let leftLocal = try XCTUnwrap(SoftKVMWindowsTopology.resolve([
            display(.viewSonic, id: 2, x: -120, width: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.philips, id: 3, isActive: false, x: 0, width: 1)
        ]))
        let rightLocal = try XCTUnwrap(SoftKVMWindowsTopology.resolve([
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, width: 120),
            display(.philips, id: 3, isActive: false, x: 0, width: 1)
        ]))

        XCTAssertEqual(leftLocal.localDisplaySide, .left)
        XCTAssertEqual(rightLocal.localDisplaySide, .right)
    }

    func testRejectsExactThreeDisplayCornerTopology() {
        let displays = [
            display(.philips, id: 3, x: -160, y: -100, width: 160),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, y: 100, width: 120),
        ]

        XCTAssertNil(SoftKVMMacBaseline.resolve(displays))
    }

    func testIdentifiesButRejectsRemainingCornerPairAfterSharedDisplayDisconnects() throws {
        let displays = [
            display(.philips, id: 3, isActive: false, x: -160, y: -100, width: 160),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, y: 100, width: 120),
        ]

        let pair = try XCTUnwrap(SoftKVMWindowsDisplayPair.resolve(displays))
        XCTAssertEqual(pair.localDisplay.role, .viewSonic)
        XCTAssertNil(SoftKVMWindowsTopology.resolve(displays))
    }

    func testRejectsUShapedMacBaselineWithoutVerticalOverlap() {
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.philips, id: 3, x: -160, y: -100, width: 160),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, y: -100, width: 120),
        ]))
    }

    func testRejectsRemainingUShapedPairWithoutVerticalOverlap() {
        XCTAssertNil(SoftKVMWindowsTopology.resolve([
            display(.philips, id: 3, isActive: false, x: -160, y: -100, width: 160),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, y: -100, width: 120),
        ]))
    }

    func testTopologyPlanDefinesBothRoutes() {
        let leftShared = SoftKVMTopologyPlan(sharedDisplaySide: .left)
        let rightShared = SoftKVMTopologyPlan(sharedDisplaySide: .right)

        XCTAssertEqual(leftShared.localDisplaySide, .right)
        XCTAssertEqual(leftShared.macEntryEdge, .left)
        XCTAssertEqual(leftShared.windowsEntryEdge, .right)
        XCTAssertEqual(rightShared.localDisplaySide, .left)
        XCTAssertEqual(rightShared.macEntryEdge, .right)
        XCTAssertEqual(rightShared.windowsEntryEdge, .left)
    }

    func testMacBaselineCapturesCompleteRemainingDisplayPlacement() throws {
        let baseline = try XCTUnwrap(SoftKVMMacBaseline.resolve([
            display(.philips, id: 3, x: -160, y: -20, width: 160, height: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, y: -20, width: 120, height: 120),
        ]))
        let movedMain = display(.builtIn, id: 1, isMain: true, x: 30, y: 10, width: 100)
        let restoredLocal = display(
            .viewSonic,
            id: 2,
            x: 130,
            y: -10,
            width: 120,
            height: 120
        )

        XCTAssertEqual(
            baseline.remainingMacDisplayPlacement,
            SoftKVMRemainingDisplayPlacement(
                mainDisplay: baseline.mainDisplay,
                localDisplay: baseline.localDisplay
            )
        )
        XCTAssertTrue(baseline.remainingMacDisplayPlacement.matches(
            mainDisplay: movedMain,
            localDisplay: restoredLocal,
            topologyPlan: baseline.topologyPlan
        ))
        XCTAssertFalse(baseline.remainingMacDisplayPlacement.matches(
            mainDisplay: movedMain,
            localDisplay: display(
                .viewSonic,
                id: 2,
                x: 130,
                y: -100,
                width: 120,
                height: 120
            ),
            topologyPlan: baseline.topologyPlan
        ))
        XCTAssertNil(baseline.remainingMacDisplayPlacement.targetOrigin(
            mainDisplay: movedMain,
            localDisplay: restoredLocal,
            topologyPlan: SoftKVMTopologyPlan(sharedDisplaySide: .right)
        ))
    }

    func testLegacySoftDisconnectSideDecodesIntoTopologyPlan() throws {
        let legacy = SoftDisconnectState(
            schemaVersion: 1,
            createdAt: "2026-08-08T00:00:00Z",
            philips: display(.philips, id: 3, x: -160, width: 160)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy))
                as? [String: Any]
        )
        object.removeValue(forKey: "topologyPlan")
        object["philipsSide"] = HorizontalDisplaySide.left.rawValue
        let decoded = try JSONDecoder().decode(
            SoftDisconnectState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.topologyPlan, SoftKVMTopologyPlan(sharedDisplaySide: .left))
        XCTAssertNil(decoded.remainingMacDisplayPlacement)
    }

    func testSoftDisconnectSnapshotWritesTopologyAndRemainingDisplayPlacement() throws {
        let main = display(.builtIn, id: 1, isMain: true, x: 0, width: 100)
        let local = display(
            .viewSonic,
            id: 2,
            x: 100,
            y: -20,
            width: 120,
            height: 120
        )
        let placement = SoftKVMRemainingDisplayPlacement(
            mainDisplay: main,
            localDisplay: local
        )
        let state = SoftDisconnectState(
            schemaVersion: 1,
            createdAt: "2026-08-08T00:00:00Z",
            philips: display(.philips, id: 3, x: -160, width: 160),
            topologyPlan: SoftKVMTopologyPlan(sharedDisplaySide: .left),
            remainingMacDisplayPlacement: placement
        )
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let decoded = try JSONDecoder().decode(SoftDisconnectState.self, from: data)

        XCTAssertNotNil(object["topologyPlan"])
        XCTAssertNotNil(object["remainingMacDisplayPlacement"])
        XCTAssertNil(object["philipsSide"])
        XCTAssertEqual(decoded.topologyPlan, state.topologyPlan)
        XCTAssertEqual(decoded.remainingMacDisplayPlacement, placement)
    }

    func testLegacySnapshotUsesSavedSharedCoordinatesNotCurrentLocalSide() throws {
        let savedPhilips = display(.philips, id: 3, x: -160, width: 160)
        let currentMain = display(.builtIn, id: 1, isMain: true, x: 0, width: 100)

        let state = SoftDisconnectState(
            schemaVersion: 1,
            createdAt: "2026-08-08T00:00:00Z",
            philips: savedPhilips
        )
        let plan = try state.resolvedTopologyPlan(
            currentMainDisplay: currentMain
        )

        XCTAssertEqual(plan.sharedDisplaySide, .left)
    }

    func testMacBaselineRejectsInactiveSharedDisplayAndInvalidArrangement() {
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.viewSonic, id: 2, x: -120, width: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.philips, id: 3, isActive: false, x: 100, width: 160)
        ]))
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.viewSonic, id: 2, x: -140, width: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.philips, id: 3, x: 100, width: 160)
        ]))
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.viewSonic, id: 2, x: -120, y: 120, width: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.philips, id: 3, x: 100, width: 160)
        ]))
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.philips, id: 3, x: -160, y: -20, width: 160, height: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.viewSonic, id: 2, x: 100, y: -10, width: 120, height: 120)
        ]))
    }

    func testTopologyResolversRejectMissingMainAndAdditionalActiveDisplay() {
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.viewSonic, id: 2, x: -120, width: 120),
            display(.builtIn, id: 1, x: 0, width: 100),
            display(.philips, id: 3, x: 100, width: 160)
        ]))
        XCTAssertNil(SoftKVMMacBaseline.resolve([
            display(.viewSonic, id: 2, x: -120, width: 120),
            display(.builtIn, id: 1, isMain: true, x: 0, width: 100),
            display(.philips, id: 3, x: 100, width: 160),
            display(.unknown, id: 4, x: 260, width: 100)
        ]))
    }

    func testTransactionStoreRoundTripAndPermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoSoftKVMTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DisplayStateStore(directory: root)
        let operationID = UUID()
        let transaction = SwitchTransactionState(
            schemaVersion: 1,
            createdAt: "2026-08-08T00:00:00Z",
            operationID: operationID,
            target: .windows,
            phase: .inputChanged
        )

        try await store.save(transaction: transaction)

        let restored = try await store.transaction()
        XCTAssertEqual(restored?.operationID, operationID)
        XCTAssertEqual(restored?.target, .windows)
        XCTAssertEqual(restored?.phase, .inputChanged)
        let directoryMode = try posixPermissions(at: root)
        let fileMode = try posixPermissions(
            at: root.appendingPathComponent("switch-transaction.json")
        )
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)

        try await store.clearTransaction()
        let cleared = try await store.transaction()
        XCTAssertNil(cleared)
    }

    func testDefaultShortcutTriggersOnceAndConsumesReleaseSequence() throws {
        let shortcut = SoftKVMShortcut.defaultValue
        var capture = SoftKVMShortcutCapture()
        let keyDown = try keyboardEvent(keyCode: shortcut.keyCode, keyDown: true)
        keyDown.flags = [.maskShift]

        XCTAssertEqual(capture.handle(type: .keyDown, event: keyDown, shortcut: shortcut), .trigger)
        XCTAssertEqual(capture.handle(type: .keyDown, event: keyDown, shortcut: shortcut), .swallow)

        let keyUp = try keyboardEvent(keyCode: shortcut.keyCode, keyDown: false)
        keyUp.flags = keyDown.flags
        XCTAssertEqual(capture.handle(type: .keyUp, event: keyUp, shortcut: shortcut), .swallow)

        let flagsUp = try keyboardEvent(keyCode: 55, keyDown: false)
        flagsUp.flags = []
        XCTAssertEqual(capture.handle(type: .flagsChanged, event: flagsUp, shortcut: shortcut), .swallow)

        let otherKey = try keyboardEvent(keyCode: 0, keyDown: true)
        XCTAssertEqual(capture.handle(type: .keyDown, event: otherKey, shortcut: shortcut), .none)
    }

    func testShortcutCaptureResetDoesNotSwallowLaterTyping() throws {
        let shortcut = SoftKVMShortcut.defaultValue
        var capture = SoftKVMShortcutCapture()
        let keyDown = try keyboardEvent(keyCode: shortcut.keyCode, keyDown: true)
        keyDown.flags = [.maskShift]
        XCTAssertEqual(capture.handle(type: .keyDown, event: keyDown, shortcut: shortcut), .trigger)

        capture.reset()

        let otherKey = try keyboardEvent(keyCode: 0, keyDown: true)
        XCTAssertEqual(capture.handle(type: .keyDown, event: otherKey, shortcut: shortcut), .none)
    }

    func testLegacyTransactionSchemaStillLoads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoSoftKVMLegacyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"createdAt":"2026-08-08T00:00:00Z"}"#.utf8)
            .write(to: root.appendingPathComponent("switch-transaction.json"))

        let transaction = try await DisplayStateStore(directory: root).transaction()

        XCTAssertEqual(transaction?.schemaVersion, 1)
        XCTAssertNil(transaction?.operationID)
        XCTAssertNil(transaction?.target)
        XCTAssertNil(transaction?.phase)
    }

    func testShortcutValidationRejectsWeakAndEmergencyCombinations() {
        XCTAssertNil(SoftKVMShortcut.make(
            keyCode: 40,
            modifiers: [.command],
            label: "K"
        ))
        XCTAssertNil(SoftKVMShortcut.make(
            keyCode: 53,
            modifiers: [.command, .option],
            label: nil
        ))
        XCTAssertEqual(SoftKVMShortcut.defaultValue.keyCode, 0x6F)
        XCTAssertEqual(SoftKVMShortcut.defaultValue.modifiers, [.shift])
        XCTAssertEqual(SoftKVMShortcut.defaultValue.title, "Shift + F12")
        XCTAssertEqual(
            SoftKVMShortcut.make(keyCode: 0x6F, modifiers: [.shift], label: nil),
            .defaultValue
        )

        let supersededCommandDefault = SoftKVMShortcut(
            keyCode: 40,
            modifiers: [.command, .option, .shift],
            keyLabel: "K"
        )
        XCTAssertEqual(
            SoftKVMShortcut.replacingSupersededDefault(supersededCommandDefault),
            .defaultValue
        )

        let supersededControlDefault = SoftKVMShortcut(
            keyCode: 40,
            modifiers: [.control, .option, .shift],
            keyLabel: "K"
        )
        XCTAssertEqual(
            SoftKVMShortcut.replacingSupersededDefault(supersededControlDefault),
            .defaultValue
        )

        let customShortcut = SoftKVMShortcut(
            keyCode: 0,
            modifiers: [.control, .option],
            keyLabel: "A"
        )
        XCTAssertEqual(
            SoftKVMShortcut.replacingSupersededDefault(customShortcut),
            customShortcut
        )
    }

    func testMacActionRequiresAReadyInputChannel() {
        XCTAssertFalse(SoftKVMStatus.macWaiting(reason: "等待 Windows").actionEnabled)
        XCTAssertTrue(SoftKVMStatus.macReady(remoteName: "Windows").actionEnabled)
        XCTAssertEqual(
            SoftKVMStatus.macReady(remoteName: "Windows").shortcutAcknowledgement,
            "正在切到 Windows，请稍候。"
        )
        XCTAssertEqual(
            SoftKVMStatus.windowsReady(remoteName: "Windows").shortcutAcknowledgement,
            "正在切回 Mac，请稍候。"
        )
        XCTAssertEqual(
            SoftKVMStatus.windowsWaiting(reason: "连接断开").actionTitle,
            "切回 Mac"
        )
    }

    private func keyboardEvent(keyCode: UInt16, keyDown: Bool) throws -> CGEvent {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: keyDown
        ) else {
            throw NSError(domain: "SoftKVMStateTests", code: 1)
        }
        return event
    }

    private func display(
        _ role: DisplayRole,
        id: UInt32,
        isActive: Bool = true,
        isMain: Bool = false,
        x: Int,
        y: Int = 0,
        width: Int,
        height: Int = 100
    ) -> DisplayRecord {
        let identity: (uuid: String?, vendor: UInt32, model: UInt32, serial: UInt32, edid: String?)
        let mode: DisplayModeRecord?
        switch role {
        case .builtIn:
            identity = ("internal", 1, 1, 1, "internal-edid")
            mode = nil
        case .viewSonic:
            identity = (
                FixedDisplayConfiguration.viewSonicUUID,
                FixedDisplayConfiguration.viewSonicVendorID,
                FixedDisplayConfiguration.viewSonicModelID,
                FixedDisplayConfiguration.viewSonicSerialNumber,
                FixedDisplayConfiguration.viewSonicEDIDUUID
            )
            mode = DisplayModeRecord(
                logicalWidth: 2_048,
                logicalHeight: 1_152,
                pixelWidth: 4_096,
                pixelHeight: 2_304,
                refreshRate: 60,
                isHiDPI: true
            )
        case .philips:
            identity = (
                FixedDisplayConfiguration.philipsUUID,
                FixedDisplayConfiguration.philipsVendorID,
                FixedDisplayConfiguration.philipsModelID,
                FixedDisplayConfiguration.philipsSerialNumber,
                FixedDisplayConfiguration.philipsEDIDUUID
            )
            mode = nil
        case .unknown:
            identity = (nil, 0, 0, 0, nil)
            mode = nil
        }
        return DisplayRecord(
            role: role,
            runtimeID: id,
            uuid: identity.uuid,
            vendorID: identity.vendor,
            modelID: identity.model,
            serialNumber: identity.serial,
            isBuiltIn: role == .builtIn,
            isActive: isActive,
            isMain: isMain,
            originX: x,
            originY: y,
            width: width,
            height: height,
            edidUUID: identity.edid,
            mode: mode
        )
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
