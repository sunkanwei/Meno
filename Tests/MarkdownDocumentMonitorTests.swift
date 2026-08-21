import Foundation
import XCTest

final class MarkdownDocumentMonitorTests: XCTestCase {
    @MainActor
    func testDetectsInPlaceWrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("document.md")
        try Data("before".utf8).write(to: fileURL)
        let changed = expectation(description: "Detects in-place write")
        let monitor = makeMonitor(fileURL: fileURL) {
            changed.fulfill()
        }
        defer { monitor.stop() }

        XCTAssertTrue(monitor.start())
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("after".utf8))
        try handle.close()

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after")
    }

    @MainActor
    func testDetectsAtomicReplacementAndContinuesMonitoring() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("document.md")
        try Data("before".utf8).write(to: fileURL)
        let firstChange = expectation(description: "Detects atomic replacement")
        let secondChange = expectation(description: "Monitors replacement file")
        var phase = 0
        let monitor = makeMonitor(fileURL: fileURL) {
            if phase == 0 {
                phase = 1
                firstChange.fulfill()
            } else if phase == 2 {
                phase = 3
                secondChange.fulfill()
            }
        }
        defer { monitor.stop() }

        XCTAssertTrue(monitor.start())
        try Data("replacement".utf8).write(to: fileURL, options: .atomic)
        await fulfillment(of: [firstChange], timeout: 2)

        phase = 2
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" updated".utf8))
        try handle.close()
        await fulfillment(of: [secondChange], timeout: 2)

        XCTAssertEqual(
            try String(contentsOf: fileURL, encoding: .utf8),
            "replacement updated"
        )
    }

    @MainActor
    func testResumesMonitoringWhenDeletedFileIsRecreatedLater() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("document.md")
        try Data("before".utf8).write(to: fileURL)
        let recreated = expectation(description: "Detects delayed recreation")
        let monitor = makeMonitor(fileURL: fileURL) {
            recreated.fulfill()
        }
        defer { monitor.stop() }

        XCTAssertTrue(monitor.start())
        try FileManager.default.removeItem(at: fileURL)
        try await Task.sleep(for: .milliseconds(300))
        try Data("after".utf8).write(to: fileURL)

        await fulfillment(of: [recreated], timeout: 2)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after")
    }

    @MainActor
    private func makeMonitor(
        fileURL: URL,
        changeHandler: @escaping @MainActor () -> Void
    ) -> MarkdownDocumentMonitor {
        MarkdownDocumentMonitor(
            fileURL: fileURL,
            debounceDuration: .milliseconds(20),
            retryDuration: .milliseconds(20),
            changeHandler: changeHandler
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoDocumentMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
