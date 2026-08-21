import AppKit
import XCTest

final class PasteboardCopyPollerTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.sunkanwei.Meno.Tests.\(UUID().uuidString)")
        )
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meno-poller-\(UUID().uuidString).txt")
        try Data().write(to: fileURL, options: .withoutOverwriting)
    }

    override func tearDownWithError() throws {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        pasteboard = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testDeliversChangeAlreadyOnPasteboard() {
        let baseline = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        var received: PasteboardCopyPoller.Result?
        PasteboardCopyPoller.poll(
            pasteboard: pasteboard,
            baselineChangeCount: baseline,
            deadline: Date().addingTimeInterval(1),
            isCurrent: { true },
            contextIsValid: { true },
            onResult: { received = $0 }
        )

        guard case let .some(.confirmed(change)) = received else {
            XCTFail("Expected a confirmed pasteboard change")
            return
        }
        XCTAssertEqual(change.fileURLs, [fileURL])
        XCTAssertEqual(change.changeCount, pasteboard.changeCount)
    }

    @MainActor
    func testReportsTimeoutWhenDeadlineExpired() {
        var received: PasteboardCopyPoller.Result?
        PasteboardCopyPoller.poll(
            pasteboard: pasteboard,
            baselineChangeCount: pasteboard.changeCount,
            deadline: Date().addingTimeInterval(-1),
            isCurrent: { true },
            contextIsValid: { true },
            onResult: { received = $0 }
        )

        guard case .some(.failed(.confirmationTimedOut)) = received else {
            XCTFail("Expected a timeout result for an expired attempt")
            return
        }
    }

    @MainActor
    func testReportsInvalidatedContext() {
        var received: PasteboardCopyPoller.Result?
        PasteboardCopyPoller.poll(
            pasteboard: pasteboard,
            baselineChangeCount: pasteboard.changeCount,
            deadline: Date().addingTimeInterval(1),
            isCurrent: { true },
            contextIsValid: { false },
            onResult: { received = $0 }
        )

        guard case .some(.failed(.contextInvalidated)) = received else {
            XCTFail("Expected an invalid-context result")
            return
        }
    }

    @MainActor
    func testStopsSilentlyWhenNoLongerCurrent() {
        var received: PasteboardCopyPoller.Result?
        PasteboardCopyPoller.poll(
            pasteboard: pasteboard,
            baselineChangeCount: pasteboard.changeCount,
            deadline: Date().addingTimeInterval(1),
            isCurrent: { false },
            contextIsValid: { true },
            onResult: { received = $0 }
        )

        XCTAssert(received == nil, "Expected no result for a superseded attempt")
    }

    @MainActor
    func testDeliversChangeWrittenWhilePolling() {
        let expectedFileURL = fileURL!
        let baseline = pasteboard.changeCount
        let delivered = expectation(description: "Pasteboard change is delivered")

        PasteboardCopyPoller.poll(
            pasteboard: pasteboard,
            baselineChangeCount: baseline,
            deadline: Date().addingTimeInterval(1),
            isCurrent: { true },
            contextIsValid: { true },
            onResult: { result in
                guard case let .confirmed(change) = result else {
                    XCTFail("Expected a confirmed pasteboard change")
                    delivered.fulfill()
                    return
                }
                XCTAssertEqual(change.fileURLs, [expectedFileURL])
                delivered.fulfill()
            }
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([expectedFileURL as NSURL]))

        wait(for: [delivered], timeout: 2)
    }

    @MainActor
    func testWaitsForFileURLsAfterATransientEmptyChange() {
        let expectedFileURL = fileURL!
        let baseline = pasteboard.changeCount
        let delivered = expectation(description: "File URLs are delivered after an empty change")

        PasteboardCopyPoller.poll(
            pasteboard: pasteboard,
            baselineChangeCount: baseline,
            deadline: Date().addingTimeInterval(1),
            isCurrent: { true },
            contextIsValid: { true },
            onResult: { result in
                guard case let .confirmed(change) = result else {
                    XCTFail("Expected a confirmed pasteboard change")
                    delivered.fulfill()
                    return
                }
                XCTAssertEqual(change.fileURLs, [expectedFileURL])
                delivered.fulfill()
            }
        )

        pasteboard.clearContents()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            XCTAssertTrue(self.pasteboard.writeObjects([expectedFileURL as NSURL]))
        }

        wait(for: [delivered], timeout: 2)
    }
}
