import Foundation
import XCTest

final class QuickScriptCatalogTests: XCTestCase {
    func testLoadsOnlyTopLevelRegularZshFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("echo second", to: directory.appendingPathComponent("02 第二个.zsh"))
        try write("echo first", to: directory.appendingPathComponent("01 第一个.ZSH"))
        try write("ignored", to: directory.appendingPathComponent("说明.txt"))
        try write("hidden", to: directory.appendingPathComponent(".隐藏.zsh"))

        let nested = directory.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try write("nested", to: nested.appendingPathComponent("嵌套.zsh"))

        let directoryWithExtension = directory.appendingPathComponent("不是文件.zsh", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryWithExtension,
            withIntermediateDirectories: false
        )

        let target = directory.appendingPathComponent("真实脚本.zsh")
        try write("target", to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("映射脚本.zsh"),
            withDestinationURL: target
        )

        let scripts = try QuickScriptCatalog.load(from: directory)

        XCTAssertEqual(scripts.map(\.displayName), ["01 第一个", "02 第二个", "真实脚本"])
    }

    func testMissingDirectoryReportsClearError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoMissingQuickScripts-\(UUID().uuidString)")

        XCTAssertThrowsError(try QuickScriptCatalog.load(from: missing)) { error in
            XCTAssertEqual(error as? QuickScriptCatalogError, .directoryUnavailable)
            XCTAssertEqual(error.localizedDescription, "脚本目录不存在或不是文件夹。")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenoQuickScriptCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }
}
