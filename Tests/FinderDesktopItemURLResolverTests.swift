import XCTest

final class FinderDesktopItemURLResolverTests: XCTestCase {
    func testKeepsResolvedDesktopURL() throws {
        let desktopURL = try makeTemporaryDesktop()
        defer { try? FileManager.default.removeItem(at: desktopURL) }
        let fileURL = desktopURL.appendingPathComponent("Report.md")
        try Data().write(to: fileURL)

        XCTAssertEqual(
            FinderDesktopItemURLResolver.resolve(
                reportedURL: fileURL,
                filename: fileURL.lastPathComponent,
                desktopURL: desktopURL
            ),
            fileURL.standardizedFileURL
        )
    }

    func testUsesFilenameWhenFinderFileReferenceIsUnresolvable() throws {
        let desktopURL = try makeTemporaryDesktop()
        defer { try? FileManager.default.removeItem(at: desktopURL) }
        let fileURL = desktopURL.appendingPathComponent("审查报告.md")
        try Data().write(to: fileURL)
        let unresolvableURL = try XCTUnwrap(
            URL(string: "com-apple-unresolvable-file-reference-url:")
        )

        XCTAssertEqual(
            FinderDesktopItemURLResolver.resolve(
                reportedURL: unresolvableURL,
                filename: fileURL.lastPathComponent,
                desktopURL: desktopURL
            ),
            fileURL.standardizedFileURL
        )
    }

    func testRejectsMissingAndNestedFilenameFallbacks() throws {
        let desktopURL = try makeTemporaryDesktop()
        defer { try? FileManager.default.removeItem(at: desktopURL) }
        let nestedDirectory = desktopURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try Data().write(to: nestedDirectory.appendingPathComponent("Report.md"))
        let unresolvableURL = try XCTUnwrap(
            URL(string: "com-apple-unresolvable-file-reference-url:")
        )

        XCTAssertNil(
            FinderDesktopItemURLResolver.resolve(
                reportedURL: unresolvableURL,
                filename: "Missing.md",
                desktopURL: desktopURL
            )
        )
        XCTAssertNil(
            FinderDesktopItemURLResolver.resolve(
                reportedURL: unresolvableURL,
                filename: "Nested/Report.md",
                desktopURL: desktopURL
            )
        )
    }

    func testDoesNotReplaceResolvedURLOutsideDesktop() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let desktopURL = rootURL.appendingPathComponent("Desktop", isDirectory: true)
        let outsideURL = rootURL.appendingPathComponent("Report.md")
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data().write(to: outsideURL)
        try Data().write(to: desktopURL.appendingPathComponent("Report.md"))

        XCTAssertNil(
            FinderDesktopItemURLResolver.resolve(
                reportedURL: outsideURL,
                filename: "Report.md",
                desktopURL: desktopURL
            )
        )
    }

    func testFilenameFallbackKeepsBrokenDesktopSymbolicLink() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let desktopURL = rootURL.appendingPathComponent("Desktop", isDirectory: true)
        let targetURL = rootURL.appendingPathComponent("Missing.md")
        let linkURL = desktopURL.appendingPathComponent("Link.md")
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let unresolvableURL = try XCTUnwrap(
            URL(string: "com-apple-unresolvable-file-reference-url:")
        )

        XCTAssertEqual(
            FinderDesktopItemURLResolver.resolve(
                reportedURL: unresolvableURL,
                filename: linkURL.lastPathComponent,
                desktopURL: desktopURL
            ),
            linkURL.standardizedFileURL
        )
    }

    private func makeTemporaryDesktop() throws -> URL {
        let desktopURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: false)
        return desktopURL
    }
}
