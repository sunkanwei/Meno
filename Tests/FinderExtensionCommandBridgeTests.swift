import XCTest

final class FinderExtensionCommandBridgeTests: XCTestCase {
    func testCreateDocumentCommandURLRoundTrip() throws {
        let request = FinderCreateDocumentRequest(
            directoryURL: URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true),
            kind: .markdown,
            position: CGPoint(x: 321.5, y: 654.25)
        )
        let commandURL = try XCTUnwrap(
            FinderExtensionCommandBridge.createDocumentCommandURL(for: request)
        )
        let decoded = try XCTUnwrap(
            FinderExtensionCommandBridge.createDocumentRequest(from: commandURL)
        )

        XCTAssertEqual(decoded, request)
    }

    func testCreateDocumentCommandRejectsMalformedURLs() throws {
        let malformedURLs = [
            "https://create-document?directoryPath=%2FUsers%2Fexample%2FDesktop&kind=markdown",
            "meno-sunkanwei-internal://wrong-command?directoryPath=%2FUsers%2Fexample%2FDesktop&kind=markdown",
            "meno-sunkanwei-internal://create-document?directoryPath=relative&kind=markdown",
            "meno-sunkanwei-internal://create-document?directoryPath=%2FUsers%2Fexample%2FDesktop&kind=unknown",
            "meno-sunkanwei-internal://create-document?directoryPath=%2FUsers%2Fexample%2FDesktop&directoryPath=%2Ftmp&kind=markdown",
            "meno-sunkanwei-internal://create-document?directoryPath=%2FUsers%2Fexample%2FDesktop&kind=markdown&x=120",
            "meno-sunkanwei-internal://desktop-position?filePath=%2FUsers%2Fexample%2FDesktop%2FTest.txt&x=120&y=240"
        ]

        for value in malformedURLs {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertNil(
                FinderExtensionCommandBridge.createDocumentRequest(from: url),
                "Unexpectedly accepted \(value)"
            )
        }
    }

    func testFileLocationsMatchThroughSymbolicLink() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actualDirectory = temporaryDirectory.appendingPathComponent("Desktop", isDirectory: true)
        let symbolicLink = temporaryDirectory.appendingPathComponent("SandboxDesktop", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: actualDirectory
        )

        XCTAssertTrue(
            FinderExtensionCommandBridge.fileLocationsMatch(symbolicLink, actualDirectory)
        )
    }
}
