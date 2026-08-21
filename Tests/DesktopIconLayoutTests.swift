import Foundation
import XCTest

final class DesktopIconLayoutTests: XCTestCase {
    func testRestoreTargetsOnlyMissingOrActuallyDisplacedItems() {
        let expected = [
            item("/Users/test/Desktop/A", x: 100, y: 200),
            item("/Users/test/Desktop/B", x: 300, y: 400),
            item("/Users/test/Desktop/C", x: 500, y: 600),
        ]
        let current = [
            item("/Users/test/Desktop/A", x: 102, y: 198),
            item("/Users/test/Desktop/B", x: 303, y: 400),
        ]

        XCTAssertEqual(
            desktopItemsNeedingRestore(expected: expected, current: current),
            [expected[1], expected[2]]
        )
    }

    func testCapturesOnlyItemsInsideViewSonicAndRestoresRelativePositions() throws {
        let originalDisplay = viewSonic(x: 1_500, y: -300)
        let state = try DesktopIconLayoutState.capture(
            items: [
                item("/Users/test/Desktop/B", x: 1_900, y: 200),
                item("/Users/test/Desktop/A", x: 1_500, y: -300),
                item("/Users/test/Desktop/left", x: 1_499, y: 100),
                item("/Users/test/Desktop/right", x: 3_548, y: 100),
                item("/Users/test/Desktop/bottom", x: 2_000, y: 852),
            ],
            on: originalDisplay,
            createdAt: "2026-08-11T00:00:00Z"
        )

        XCTAssertEqual(state.entries, [
            DesktopIconLayoutEntry(
                path: "/Users/test/Desktop/A",
                offsetX: 0,
                offsetY: 0
            ),
            DesktopIconLayoutEntry(
                path: "/Users/test/Desktop/B",
                offsetX: 400,
                offsetY: 500
            ),
        ])

        let restored = try state.restoredItems(on: viewSonic(x: 2_048, y: 100))
        XCTAssertEqual(restored, [
            item("/Users/test/Desktop/A", x: 2_048, y: 100),
            item("/Users/test/Desktop/B", x: 2_448, y: 600),
        ])
    }

    func testRejectsDifferentDisplaySizeAndInvalidSavedOffsets() throws {
        let state = try DesktopIconLayoutState.capture(
            items: [item("/Users/test/Desktop/A", x: 10, y: 20)],
            on: viewSonic(x: 0, y: 0),
            createdAt: "2026-08-11T00:00:00Z"
        )

        XCTAssertThrowsError(try state.restoredItems(on: viewSonic(
            x: 0,
            y: 0,
            width: 1_920
        )))

        let invalid = DesktopIconLayoutState(
            schemaVersion: 1,
            createdAt: state.createdAt,
            displayUUID: state.displayUUID,
            displayWidth: state.displayWidth,
            displayHeight: state.displayHeight,
            entries: [DesktopIconLayoutEntry(
                path: "/Users/test/Desktop/A",
                offsetX: state.displayWidth,
                offsetY: 0
            )]
        )
        XCTAssertThrowsError(try invalid.restoredItems(on: viewSonic(x: 0, y: 0)))
    }

    func testRejectsDuplicatePathsAndUnsupportedSnapshotIdentity() throws {
        XCTAssertThrowsError(try DesktopIconLayoutState.capture(
            items: [
                item("/Users/test/Desktop/A", x: 10, y: 20),
                item("/Users/test/Desktop/A", x: 30, y: 40),
            ],
            on: viewSonic(x: 0, y: 0),
            createdAt: "2026-08-11T00:00:00Z"
        ))

        let state = try DesktopIconLayoutState.capture(
            items: [item("/Users/test/Desktop/A", x: 10, y: 20)],
            on: viewSonic(x: 0, y: 0),
            createdAt: "2026-08-11T00:00:00Z"
        )
        let unsupported = DesktopIconLayoutState(
            schemaVersion: 2,
            createdAt: state.createdAt,
            displayUUID: state.displayUUID,
            displayWidth: state.displayWidth,
            displayHeight: state.displayHeight,
            entries: state.entries
        )
        XCTAssertThrowsError(try unsupported.restoredItems(on: viewSonic(x: 0, y: 0)))

        let wrongDisplay = DesktopIconLayoutState(
            schemaVersion: 1,
            createdAt: state.createdAt,
            displayUUID: UUID().uuidString,
            displayWidth: state.displayWidth,
            displayHeight: state.displayHeight,
            entries: state.entries
        )
        XCTAssertThrowsError(try wrongDisplay.restoredItems(on: viewSonic(x: 0, y: 0)))
    }

    func testDesktopIconStateStoreRoundTripPermissionsAndClear() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoDesktopIconTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DisplayStateStore(directory: root)
        let state = try DesktopIconLayoutState.capture(
            items: [item("/Users/test/Desktop/A", x: 100, y: 100)],
            on: viewSonic(x: 0, y: 0),
            createdAt: "2026-08-11T00:00:00Z"
        )

        try await store.save(desktopIconLayoutState: state)

        let restored = try await store.desktopIconLayoutState()
        XCTAssertEqual(restored, state)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("desktop-icon-layout-state.json").path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        try await store.clearDesktopIconLayoutState()
        let cleared = try await store.desktopIconLayoutState()
        XCTAssertNil(cleared)
    }

    func testDesktopIconSnapshotAloneRequiresRecovery() {
        let inspection = DisplaySwitchInspection(
            report: ProbeReport(
                passed: true,
                topology: .mac,
                displays: [],
                checks: []
            ),
            topologyPlan: nil,
            hasTransaction: false,
            hasSoftDisconnectState: false,
            hasWindowMigrationState: false,
            hasDesktopIconLayoutState: true
        )

        XCTAssertTrue(inspection.hasRecoveryState)
    }

    func testDesktopIconStateStoreRejectsUnsupportedVersion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoDesktopIconTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DisplayStateStore(directory: root)
        let state = DesktopIconLayoutState(
            schemaVersion: 2,
            createdAt: "2026-08-11T00:00:00Z",
            displayUUID: FixedDisplayConfiguration.viewSonicUUID,
            displayWidth: 2_048,
            displayHeight: 1_152,
            entries: []
        )
        try await store.save(desktopIconLayoutState: state)

        do {
            _ = try await store.desktopIconLayoutState()
            XCTFail("Expected an unsupported snapshot version error")
        } catch let error as DisplayControlError {
            guard case .state = error else {
                return XCTFail("Expected a state error, got \(error)")
            }
        }
    }

    private func item(_ path: String, x: Int, y: Int) -> FinderDesktopItemPosition {
        FinderDesktopItemPosition(path: path, x: x, y: y)
    }

    private func viewSonic(
        x: Int,
        y: Int,
        width: Int = 2_048,
        height: Int = 1_152
    ) -> DisplayRecord {
        DisplayRecord(
            role: .viewSonic,
            runtimeID: 2,
            uuid: FixedDisplayConfiguration.viewSonicUUID,
            vendorID: FixedDisplayConfiguration.viewSonicVendorID,
            modelID: FixedDisplayConfiguration.viewSonicModelID,
            serialNumber: FixedDisplayConfiguration.viewSonicSerialNumber,
            isBuiltIn: false,
            isActive: true,
            isMain: false,
            originX: x,
            originY: y,
            width: width,
            height: height,
            edidUUID: FixedDisplayConfiguration.viewSonicEDIDUUID,
            mode: nil
        )
    }
}
