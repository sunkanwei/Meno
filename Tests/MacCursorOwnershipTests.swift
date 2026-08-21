import CoreGraphics
import XCTest

final class MacCursorOwnershipTests: XCTestCase {
    private final class CallRecorder {
        var calls: [String] = []
    }

    func testCaptureHidesBeforeDetaching() {
        let recorder = CallRecorder()
        let result = MacCursorOwnership.capture(using: operations(recorder: recorder))

        XCTAssertNotNil(result.token)
        XCTAssertEqual(recorder.calls, ["background", "hide", "associate:false"])
    }

    func testCaptureStopsWhenHideFails() {
        let recorder = CallRecorder()
        let result = MacCursorOwnership.capture(
            using: operations(recorder: recorder, hideError: .failure)
        )

        XCTAssertNil(result.token)
        XCTAssertEqual(recorder.calls, ["background", "hide"])
        XCTAssertNil(result.rollbackShowError)
    }

    func testCaptureStopsBeforeHidingWithoutBackgroundControl() {
        let recorder = CallRecorder()
        let result = MacCursorOwnership.capture(
            using: operations(recorder: recorder, backgroundControl: .unavailable)
        )

        XCTAssertNil(result.token)
        XCTAssertEqual(recorder.calls, ["background"])
    }

    func testCaptureRollsBackHideWhenDetachFails() {
        let recorder = CallRecorder()
        let result = MacCursorOwnership.capture(
            using: operations(recorder: recorder, detachError: .failure)
        )

        XCTAssertNil(result.token)
        XCTAssertEqual(
            recorder.calls,
            ["background", "hide", "associate:false", "associate:true", "show"]
        )
        XCTAssertEqual(result.rollbackAssociationError, .success)
        XCTAssertEqual(result.rollbackShowError, .success)
    }

    func testCaptureReportsRollbackFailures() {
        let recorder = CallRecorder()
        let result = MacCursorOwnership.capture(
            using: operations(
                recorder: recorder,
                showError: .failure,
                detachError: .failure,
                restoreAssociationError: .failure
            )
        )

        XCTAssertNil(result.token)
        XCTAssertEqual(
            recorder.calls,
            ["background", "hide", "associate:false", "associate:true", "show"]
        )
        XCTAssertEqual(result.rollbackAssociationError, .failure)
        XCTAssertEqual(result.rollbackShowError, .failure)
    }

    func testRestoreReconnectsAndWarpsBeforeShowing() throws {
        let recorder = CallRecorder()
        let capture = try captureToken()
        let result = MacCursorOwnership.restore(
            capture,
            at: CGPoint(x: 12, y: 34),
            using: operations(recorder: recorder)
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            recorder.calls,
            ["background", "suppression", "associate:true", "warp:12.0,34.0", "show"]
        )
    }

    func testRestoreReportsShowFailure() throws {
        let recorder = CallRecorder()
        let capture = try captureToken()
        let result = MacCursorOwnership.restore(
            capture,
            at: nil,
            using: operations(recorder: recorder, showError: .failure)
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            recorder.calls,
            ["background", "suppression", "associate:true", "show"]
        )
    }

    func testRestoreStillShowsAfterPreparationFailures() throws {
        let recorder = CallRecorder()
        let capture = try captureToken()
        let result = MacCursorOwnership.restore(
            capture,
            at: CGPoint(x: 12, y: 34),
            using: operations(
                recorder: recorder,
                backgroundControl: .unavailable,
                restoreAssociationError: .failure,
                suppressionError: .failure,
                warpError: .failure
            )
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            recorder.calls,
            ["background", "suppression", "associate:true", "warp:12.0,34.0", "show"]
        )
        guard case .unavailable = result.backgroundControl else {
            return XCTFail("Expected background cursor control to be unavailable")
        }
        XCTAssertEqual(result.suppressionError, .failure)
        XCTAssertEqual(result.associationError, .failure)
        XCTAssertEqual(result.warpError, .failure)
        XCTAssertEqual(result.showError, .success)
    }

    private func captureToken() throws -> MacCursorOwnership.CaptureToken {
        let recorder = CallRecorder()
        return try XCTUnwrap(
            MacCursorOwnership.capture(using: operations(recorder: recorder)).token
        )
    }

    private func operations(
        recorder: CallRecorder,
        backgroundControl: MacCursorOwnership.BackgroundControlResult = .enabled,
        hideError: CGError = .success,
        showError: CGError = .success,
        detachError: CGError = .success,
        restoreAssociationError: CGError = .success,
        suppressionError: CGError = .success,
        warpError: CGError = .success
    ) -> MacCursorOwnership.SystemOperations {
        MacCursorOwnership.SystemOperations(
            enableBackgroundControl: {
                recorder.calls.append("background")
                return backgroundControl
            },
            hideCursor: {
                recorder.calls.append("hide")
                return hideError
            },
            showCursor: {
                recorder.calls.append("show")
                return showError
            },
            associateMouseAndCursor: { connected in
                recorder.calls.append("associate:\(connected)")
                return connected ? restoreAssociationError : detachError
            },
            reduceSuppressionInterval: {
                recorder.calls.append("suppression")
                return suppressionError
            },
            warpCursor: { point in
                recorder.calls.append("warp:\(point.x),\(point.y)")
                return warpError
            }
        )
    }
}
