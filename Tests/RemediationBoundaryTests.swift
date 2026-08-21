import AppKit
import Foundation
import XCTest

final class RemediationBoundaryTests: XCTestCase {
    func testMarkdownRendererPolicySupportsBundledDiagramsWithoutExternalConnections() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rendererURL = repositoryURL.appendingPathComponent("Vendor/FluxMarkdownRenderer")
        let expectedPolicy = "default-src 'none'; script-src 'self' 'unsafe-eval'; "
            + "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: local-md:; "
            + "font-src 'self' data:; connect-src 'self' blob:; worker-src 'self' blob:; "
            + "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"

        for relativePath in ["index.html", "dist/index.html"] {
            let html = try String(
                contentsOf: rendererURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let policyMarker = "http-equiv=\"Content-Security-Policy\""
            XCTAssertEqual(html.components(separatedBy: policyMarker).count, 2)
            XCTAssertTrue(html.contains("<meta \(policyMarker) content=\"\(expectedPolicy)\">"))
        }
    }

    func testMarkdownPreviewSandboxEntitlementsAreMinimalAndWebKitCompatible() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryURL
            .appendingPathComponent("Extensions/MenoMarkdownPreview/MenoMarkdownPreview.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let entitlements = try XCTUnwrap(propertyList as? [String: Any])
        let expectedKeys: Set<String> = [
            "com.apple.security.app-sandbox",
            "com.apple.security.files.user-selected.read-only",
            "com.apple.security.network.client",
        ]

        XCTAssertEqual(Set(entitlements.keys), expectedKeys)
        for key in expectedKeys {
            XCTAssertEqual(entitlements[key] as? Bool, true, "Expected enabled entitlement: \(key)")
        }
    }

    func testDiskBudgetPreservesFreeSpaceReserve() {
        XCTAssertTrue(FileClipboardDiskBudget.accepts(
            freeBytes: 30,
            incomingBytes: 10,
            minimumReserve: 10
        ))
        XCTAssertFalse(FileClipboardDiskBudget.accepts(
            freeBytes: 19,
            incomingBytes: 10,
            minimumReserve: 10
        ))
        XCTAssertFalse(FileClipboardDiskBudget.accepts(
            freeBytes: .max,
            incomingBytes: .max,
            minimumReserve: 10
        ))
    }

    func testReadinessGateAllowsOnlyOneHelloAndRequiresReadyWrite() {
        var gate = ConnectionReadinessGate()

        XCTAssertTrue(gate.isHandshakePending)
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.beginHello())
        XCTAssertFalse(gate.beginHello())
        XCTAssertFalse(gate.isReady)
        XCTAssertTrue(gate.readyFrameWasSent())
        XCTAssertTrue(gate.isReady)
        XCTAssertFalse(gate.isHandshakePending)
        XCTAssertFalse(gate.readyFrameWasSent())

        gate.close()
        XCTAssertFalse(gate.isReady)
        XCTAssertFalse(gate.beginHello())
    }

    func testIncomingSocketCannotReplaceOccupiedConnection() {
        XCTAssertTrue(IncomingConnectionAdmission.allows(
            serviceEnabled: true,
            systemIsSleeping: false,
            serverMatches: true,
            slotIsOccupied: false
        ))
        XCTAssertFalse(IncomingConnectionAdmission.allows(
            serviceEnabled: true,
            systemIsSleeping: false,
            serverMatches: true,
            slotIsOccupied: true
        ))
        XCTAssertFalse(IncomingConnectionAdmission.allows(
            serviceEnabled: true,
            systemIsSleeping: true,
            serverMatches: true,
            slotIsOccupied: false
        ))
    }

    func testClipboardImageBudgetRejectsDimensionsPixelsAndOverflow() {
        XCTAssertTrue(ClipboardImageBudget.accepts(width: 4_096, height: 4_096))
        XCTAssertFalse(ClipboardImageBudget.accepts(width: 16_385, height: 1))
        XCTAssertFalse(ClipboardImageBudget.accepts(width: 4_097, height: 4_096))
        XCTAssertFalse(ClipboardImageBudget.accepts(width: .max, height: .max))
        XCTAssertFalse(ClipboardImageBudget.accepts(bytesPerRow: Int.max, height: 2))
    }

    func testClipboardImageCodecAcceptsSmallSingleFramePNG() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        XCTAssertTrue(ClipboardImageCodec.isAcceptablePNG(png))
    }

    func testCacheEvictionUsesOldestUnpinnedRoots() {
        let old = Date(timeIntervalSince1970: 1)
        let new = Date(timeIntervalSince1970: 2)
        let candidates = [
            FileClipboardCacheEvictionCandidate(
                path: "/cache/pinned",
                logicalBytes: 20,
                entryCount: 5,
                completedAt: old,
                isPinned: true
            ),
            FileClipboardCacheEvictionCandidate(
                path: "/cache/old",
                logicalBytes: 10,
                entryCount: 5,
                completedAt: old,
                isPinned: false
            ),
            FileClipboardCacheEvictionCandidate(
                path: "/cache/new",
                logicalBytes: 10,
                entryCount: 5,
                completedAt: new,
                isPinned: false
            )
        ]

        XCTAssertEqual(
            FileClipboardCacheEvictionPlanner.plan(
                completed: candidates,
                incomingBytes: 15,
                incomingEntries: 5,
                byteQuota: 50,
                entryQuota: 25
            ),
            ["/cache/old"]
        )
    }

    func testCacheEvictionRejectsPlansThatCannotMeetQuotas() {
        let pinned = FileClipboardCacheEvictionCandidate(
            path: "/cache/pinned",
            logicalBytes: 20,
            entryCount: 5,
            completedAt: Date(timeIntervalSince1970: 1),
            isPinned: true
        )

        XCTAssertNil(FileClipboardCacheEvictionPlanner.plan(
            completed: [pinned],
            incomingBytes: 35,
            incomingEntries: 10,
            byteQuota: 50,
            entryQuota: 25
        ))
        XCTAssertNil(FileClipboardCacheEvictionPlanner.plan(
            completed: [],
            incomingBytes: 55,
            incomingEntries: 0,
            byteQuota: 50,
            entryQuota: 25
        ))
        XCTAssertNil(FileClipboardCacheEvictionPlanner.plan(
            completed: [],
            hasUnaccountedRoots: true,
            incomingBytes: 1,
            incomingEntries: 1,
            byteQuota: 50,
            entryQuota: 25
        ))
    }

    func testCacheEvictionCountsZeroByteEntries() {
        let old = Date(timeIntervalSince1970: 1)
        let zeroByteTransfer = FileClipboardCacheEvictionCandidate(
            path: "/cache/zero-byte",
            logicalBytes: 0,
            entryCount: 20,
            completedAt: old,
            isPinned: false
        )
        XCTAssertEqual(FileClipboardCacheEvictionPlanner.plan(
            completed: [zeroByteTransfer],
            incomingBytes: 0,
            incomingEntries: 1,
            byteQuota: 50,
            entryQuota: 20
        ), ["/cache/zero-byte"])
        XCTAssertNil(FileClipboardCacheEvictionPlanner.plan(
            completed: [FileClipboardCacheEvictionCandidate(
                path: "/cache/pinned-zero-byte",
                logicalBytes: 0,
                entryCount: 20,
                completedAt: old,
                isPinned: true
            )],
            incomingBytes: 0,
            incomingEntries: 1,
            byteQuota: 50,
            entryQuota: 20
        ))
    }

    func testCurrentDisplayTopologyWinsWhenRecordedSourceWasRemoved() throws {
        let oldSource = CrossScreenDisplay(
            id: "old",
            name: "Old display",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            isMain: true
        )
        let recorded = WindowsDisplayHandoffSession(
            macDisplay: oldSource,
            activeDisplays: [oldSource],
            windowsScreenMetrics: MouseScreenMetrics(width: 1_920, height: 1_080),
            configuration: .defaultValue,
            windowsPhysicalHeightMM: FixedDisplayConfiguration.philipsActiveHeightMM
        )
        let currentMain = CrossScreenDisplay(
            id: "current",
            name: "Current display",
            frame: CGRect(x: 2_000, y: 100, width: 1_200, height: 900),
            isMain: true
        )

        let result = try XCTUnwrap(WindowsReturnPointResolver.point(
            session: recorded,
            windowsNormalizedY: UInt16.max / 2,
            currentDisplays: [currentMain]
        ))

        XCTAssertTrue(currentMain.frame.contains(result.point))
        XCTAssertEqual(result.point, CGPoint(x: 2_600, y: 550))
        XCTAssertEqual(result.method, .safeMainCenter)
    }

    func testNilGeometryUsesCurrentMainDisplaySafePoint() {
        let currentMain = CrossScreenDisplay(
            id: "current",
            name: "Current display",
            frame: CGRect(x: -1_600, y: 0, width: 1_600, height: 1_000),
            isMain: true
        )

        XCTAssertEqual(
            WindowsReturnPointResolver.point(
                session: nil,
                windowsNormalizedY: 0,
                currentDisplays: [currentMain]
            )?.point,
            CGPoint(x: -800, y: 500)
        )
    }

    func testNoCurrentDisplaySkipsCursorWarp() {
        XCTAssertNil(WindowsReturnPointResolver.point(
            session: nil,
            windowsNormalizedY: 0,
            currentDisplays: []
        ))
    }

    func testEventTapOneShotNeverRunsActionTwice() {
        let oneShot = EventTapOneShot()
        let counter = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            oneShot.perform {
                counter.increment()
            }
        }

        XCTAssertEqual(counter.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withCriticalSection { storage }
    }

    func increment() {
        lock.withCriticalSection { storage += 1 }
    }
}
