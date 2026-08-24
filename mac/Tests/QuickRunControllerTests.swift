import Foundation
import XCTest

@MainActor
final class QuickRunControllerTests: XCTestCase {
    func testLoadsDefaultPersistsCustomDirectoryAndRestoresDefault() throws {
        let defaultDirectory = try makeTemporaryDirectory()
        let customDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: defaultDirectory)
            try? FileManager.default.removeItem(at: customDirectory)
        }
        try writeScript(named: "默认.zsh", in: defaultDirectory)
        try writeScript(named: "自选.zsh", in: customDirectory)
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.name) }

        let controller = QuickRunController(
            defaults: storage.defaults,
            defaultDirectoryURL: defaultDirectory
        )
        XCTAssertTrue(controller.isUsingDefaultDirectory)
        XCTAssertEqual(controller.scripts.map(\.displayName), ["默认"])

        controller.setDirectory(customDirectory)
        XCTAssertFalse(controller.isUsingDefaultDirectory)
        XCTAssertEqual(controller.scripts.map(\.displayName), ["自选"])
        XCTAssertEqual(
            storage.defaults.string(forKey: AppPreferenceKey.quickRunDirectoryPath),
            customDirectory.standardizedFileURL.path
        )

        let reloaded = QuickRunController(
            defaults: storage.defaults,
            defaultDirectoryURL: defaultDirectory
        )
        XCTAssertEqual(reloaded.directoryURL, customDirectory.standardizedFileURL)

        reloaded.restoreDefaultDirectory()
        XCTAssertTrue(reloaded.isUsingDefaultDirectory)
        XCTAssertNil(storage.defaults.string(forKey: AppPreferenceKey.quickRunDirectoryPath))
    }

    func testRejectsDuplicateRunAndRefreshesAfterCompletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("一次.zsh")
        try Data(
            "sleep 0.1\necho 已运行 > result.txt\nrm -- \"$0\"".utf8
        ).write(to: scriptURL)
        let storage = makeDefaults()
        defer { storage.defaults.removePersistentDomain(forName: storage.name) }
        let controller = QuickRunController(
            defaults: storage.defaults,
            defaultDirectoryURL: directory
        )
        let script = try XCTUnwrap(controller.scripts.first)

        let result = await withCheckedContinuation { continuation in
            XCTAssertTrue(controller.run(script) { runResult in
                continuation.resume(returning: runResult)
            })
            XCTAssertFalse(controller.run(script) { _ in
                XCTFail("重复运行不应收到完成回调。")
            })
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("result.txt"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines),
            "已运行"
        )
        XCTAssertTrue(controller.scripts.isEmpty)
        XCTAssertFalse(controller.isRunning(script))
    }

    private func makeDefaults() -> (name: String, defaults: UserDefaults) {
        let name = "com.sunkanwei.Meno.QuickRunTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meno QuickRunControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func writeScript(named name: String, in directory: URL) throws {
        try Data("echo test".utf8).write(to: directory.appendingPathComponent(name))
    }
}
