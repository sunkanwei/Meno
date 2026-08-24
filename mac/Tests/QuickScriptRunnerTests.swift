import Darwin
import Foundation
import XCTest

final class QuickScriptRunnerTests: XCTestCase {
    func testRunsWithScriptDirectoryAndCapturesOutput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "成功.zsh",
            contents: "pwd\necho 运行完成",
            in: directory
        )

        let result = await Self.run(script, using: QuickScriptRunner())

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(result.summary, "运行完成")
        XCTAssertTrue(result.output.contains(directory.path))
        XCTAssertFalse(result.outputWasTruncated)
    }

    func testReturnsFailureCodeAndStandardError() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "失败.zsh",
            contents: "echo 失败原因 >&2\nexit 7",
            in: directory
        )

        let result = await Self.run(script, using: QuickScriptRunner())

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.termination, .exited(7))
        XCTAssertEqual(result.summary, "失败原因")
        XCTAssertTrue(result.detail.contains("脚本以状态 7 结束"))
    }

    func testClosesStandardInputInsteadOfWaitingForTerminal() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "标准输入.zsh",
            contents: "if read value; then\n  echo 不应读到输入\nelse\n  echo 输入已关闭\nfi",
            in: directory
        )

        let result = await Self.run(script, using: QuickScriptRunner())

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.summary, "输入已关闭")
    }

    func testTruncatedFailureKeepsFinalErrorVisible() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "大量失败输出.zsh",
            contents: "i=0\nwhile (( i < 70000 )); do\n  printf x\n  (( i++ ))\ndone\necho\necho 最终失败 >&2\nexit 9",
            in: directory
        )

        let result = await Self.run(script, using: QuickScriptRunner())

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertTrue(result.detail.hasPrefix("脚本以状态 9 结束"))
        XCTAssertTrue(result.detail.contains("最后一行：最终失败"))
    }

    func testLimitsCapturedOutputWhileStillLettingScriptFinish() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "大量输出.zsh",
            contents: "i=0\nwhile (( i < 70000 )); do\n  printf x\n  (( i++ ))\ndone\necho\necho 最终结果",
            in: directory
        )

        let result = await Self.run(script, using: QuickScriptRunner())

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertEqual(result.output.utf8.count, 64 * 1024)
        XCTAssertEqual(result.summary, "最终结果")
    }

    func testNormalCompletionRemovesBackgroundProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "后台任务.zsh",
            contents: "sleep 30 >/dev/null 2>&1 &\necho $! > child.pid",
            in: directory
        )

        let result = await Self.run(script, using: QuickScriptRunner())
        let processIDText = try String(
            contentsOf: directory.appendingPathComponent("child.pid"),
            encoding: .utf8
        )
        let processID = try XCTUnwrap(
            Int32(processIDText.trimmingCharacters(in: .whitespacesAndNewlines))
        )

        XCTAssertTrue(result.succeeded)
        await Self.assertProcessGone(processID)
    }

    func testRejectsSymbolicLinkChangedAfterCatalogRefresh() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try makeScript(named: "真实脚本.zsh", contents: "echo 不应运行", in: directory)
        let linkURL = directory.appendingPathComponent("映射脚本.zsh")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target.url)

        let result = await Self.run(QuickScript(url: linkURL), using: QuickScriptRunner())

        XCTAssertEqual(
            result.termination,
            .runnerFailed("脚本已经移动，或不再是普通的 .zsh 文件。")
        )
    }

    func testScheduledRunRetainsTemporaryRunnerUntilCompletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(named: "临时运行器.zsh", contents: "echo 完成", in: directory)
        let finished = XCTestExpectation(description: "临时运行器完成回调")

        QuickScriptRunner().run(script) { result in
            XCTAssertTrue(result.succeeded)
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 2)
    }

    func testShutdownRejectsNewRuns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(named: "退出后.zsh", contents: "echo 不应运行", in: directory)
        let runner = QuickScriptRunner()

        runner.shutdown()
        let result = await Self.run(script, using: runner)

        XCTAssertEqual(result.termination, .runnerFailed("Meno 正在退出。"))
    }

    @MainActor
    func testStopAllTerminatesScriptProcessGroup() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try makeScript(
            named: "等待.zsh",
            contents: "echo $$ > shell.pid\nsleep 30 &\necho $! > child.pid\nwait",
            in: directory
        )
        let runner = QuickScriptRunner()
        async let result = Self.run(script, using: runner)
        let shellProcessID = try await Self.waitForProcessID(
            at: directory.appendingPathComponent("shell.pid")
        )
        let childProcessID = try await Self.waitForProcessID(
            at: directory.appendingPathComponent("child.pid")
        )
        runner.shutdown()

        let stoppedResult = await result
        XCTAssertFalse(stoppedResult.succeeded)
        await Self.assertProcessGone(shellProcessID)
        await Self.assertProcessGone(childProcessID)
    }

    private static func run(
        _ script: QuickScript,
        using runner: QuickScriptRunner
    ) async -> QuickScriptRunResult {
        await withCheckedContinuation { continuation in
            runner.run(script) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Meno QuickScriptRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeScript(named name: String, contents: String, in directory: URL) throws -> QuickScript {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return QuickScript(url: url)
    }

    private static func waitForProcessID(at url: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8),
               let processID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processID
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("脚本没有写入进程编号：\(url.lastPathComponent)")
        throw CocoaError(.fileReadUnknown)
    }

    private static func assertProcessGone(_ processID: pid_t) async {
        for _ in 0..<100 {
            if Darwin.kill(processID, 0) == -1, errno == ESRCH {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("进程仍然存在：\(processID)")
    }
}
