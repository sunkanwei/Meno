import Foundation
import XCTest

final class MarkdownImageDataCollectorTests: XCTestCase {
    func testCollectsImageInsideDocumentDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("document.md")
        let imageURL = directory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let result = MarkdownImageDataCollector.collect(
            from: documentURL,
            markdown: "![image](image.png)"
        )

        XCTAssertTrue(result.dataURLs["image.png"]?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(result.allowedFileURLs, [imageURL])
    }

    func testAllowsExplicitParentImageInMarkdownSyntax() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let childDirectory = directory.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let documentURL = childDirectory.appendingPathComponent("document.md")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent("secret.png"))

        let imageURL = directory.appendingPathComponent("secret.png")
        let result = MarkdownImageDataCollector.collect(
            from: documentURL,
            markdown: "![secret](../secret.png)"
        )

        XCTAssertNotNil(result.dataURLs["../secret.png"])
        XCTAssertEqual(result.allowedFileURLs, [imageURL])
    }

    func testIgnoresRemoteImages() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = MarkdownImageDataCollector.collect(
            from: directory.appendingPathComponent("document.md"),
            markdown: "![remote](https://example.com/image.png)"
        )

        XCTAssertTrue(result.dataURLs.isEmpty)
        XCTAssertTrue(result.allowedFileURLs.isEmpty)
    }

    func testAllowsExplicitParentImageWithoutGrantingItsDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentDirectory = directory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let result = MarkdownImageDataCollector.collect(
            from: documentDirectory.appendingPathComponent("document.md"),
            markdown: #"<img src="../image.png" width="120">"#
        )

        XCTAssertTrue(result.dataURLs["../image.png"]?.hasPrefix("data:image/png;base64,") == true)
        XCTAssertEqual(result.allowedFileURLs, [imageURL])
    }

    func testRejectsSymlinkImage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("target.png")
        let symlinkURL = directory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        let result = MarkdownImageDataCollector.collect(
            from: directory.appendingPathComponent("document.md"),
            markdown: "![image](image.png)"
        )

        XCTAssertTrue(result.dataURLs.isEmpty)
        XCTAssertTrue(result.allowedFileURLs.isEmpty)
    }

    func testRejectsImageLargerThanLimit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("image.png")
        try Data(repeating: 0, count: 5).write(to: imageURL)
        let limits = MarkdownImageDataCollector.Limits(
            maxImageCount: 1,
            maxImageBytes: 4,
            maxTotalBytes: 4
        )

        let result = MarkdownImageDataCollector.collect(
            from: directory.appendingPathComponent("document.md"),
            markdown: "![image](image.png)",
            limits: limits
        )

        XCTAssertTrue(result.dataURLs.isEmpty)
        XCTAssertTrue(result.allowedFileURLs.isEmpty)
    }

    func testCountsDuplicatePathsAsOneAllowedFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("image.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let limits = MarkdownImageDataCollector.Limits(
            maxImageCount: 1,
            maxImageBytes: 1024,
            maxTotalBytes: 1024
        )

        let result = MarkdownImageDataCollector.collect(
            from: directory.appendingPathComponent("document.md"),
            markdown: "![first](image.png)\n![second](./image.png)",
            limits: limits
        )

        XCTAssertNotNil(result.dataURLs["image.png"])
        XCTAssertNotNil(result.dataURLs["./image.png"])
        XCTAssertEqual(result.allowedFileURLs, [imageURL])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoMarkdownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
