import Foundation
import XCTest

final class LocalFileSchemeHandlerTests: XCTestCase {
    @MainActor
    func testAllowsOnlyConfiguredFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoLocalFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let allowedURL = directory.appendingPathComponent("allowed.png")
        let deniedURL = directory.appendingPathComponent("denied.png")
        try Data([0]).write(to: allowedURL)
        try Data([0]).write(to: deniedURL)

        let handler = LocalFileSchemeHandler()
        handler.configure(allowedURLs: [allowedURL])

        XCTAssertEqual(
            handler.allowedFileURL(for: schemeURL(for: allowedURL)),
            allowedURL.standardizedFileURL
        )
        XCTAssertNil(handler.allowedFileURL(for: schemeURL(for: deniedURL)))
    }

    private func schemeURL(for fileURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = "local-md"
        components.path = fileURL.path
        return components.url!
    }
}
