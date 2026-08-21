import Foundation

enum ClosedLidShutdownHelperStatus: Equatable, Sendable {
    case missing
    case installing
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .missing:
            return "关机助手尚未安装"
        case .installing:
            return "正在安装关机助手"
        case .ready:
            return "关机助手已就绪"
        case .failed:
            return "关机助手出现异常"
        }
    }

    var detail: String {
        switch self {
        case .missing:
            return "启用合盖自动关机需要先进行一次管理员授权。"
        case .installing:
            return "请完成 macOS 显示的管理员授权。"
        case .ready:
            return "合盖后会清除会话恢复名单并立即关机，不再询问。"
        case let .failed(message):
            return message
        }
    }

    var isReady: Bool {
        self == .ready
    }
}

struct ClosedLidShutdownHelperManager: Sendable {
    func currentStatus() -> ClosedLidShutdownHelperStatus {
        guard ClosedLidShutdownValidation.isRegularFileWithoutFollowingLinks(
            at: ClosedLidShutdownContract.bundledExecutablePath
        ), ClosedLidShutdownValidation.helperHasExpectedCodeSignature(
            at: ClosedLidShutdownContract.bundledExecutablePath
        ) else {
            return .failed("Meno 内置的关机助手签名无效，请重新安装 Meno。")
        }
        guard FileManager.default.isExecutableFile(
            atPath: ClosedLidShutdownContract.installedExecutablePath
        ), FileManager.default.fileExists(
            atPath: ClosedLidShutdownContract.launchDaemonPath
        ) else {
            return .missing
        }
        guard FileManager.default.contentsEqual(
            atPath: ClosedLidShutdownContract.bundledExecutablePath,
            andPath: ClosedLidShutdownContract.installedExecutablePath
        ) else {
            return .failed("关机助手需要更新，请重新安装。")
        }
        guard ClosedLidShutdownValidation.installedFilesAreProtected() else {
            return .failed("关机助手的系统文件或启动配置不正确，请重新安装。")
        }
        guard ClosedLidShutdownValidation.helperHasExpectedCodeSignature(
            at: ClosedLidShutdownContract.installedExecutablePath
        ) else {
            return .failed("关机助手的签名验证失败，请重新安装。")
        }

        let result = run(
            executable: "/bin/launchctl",
            arguments: ["print", "system/\(ClosedLidShutdownContract.helperLabel)"]
        )
        guard result.status == 0,
              result.output.contains("state = running"),
              result.output.contains(
                  "path = \(ClosedLidShutdownContract.launchDaemonPath)"
              ),
              result.output.contains(
                  "program = \(ClosedLidShutdownContract.installedExecutablePath)"
              ) else {
            return .failed("关机助手已安装，但当前没有正常运行；请重新安装。")
        }
        return .ready
    }

    func install() async -> ClosedLidShutdownHelperStatus {
        await Task.detached(priority: .userInitiated) {
            Self.performInstallation()
        }.value
    }

    private static func performInstallation() -> ClosedLidShutdownHelperStatus {
        let expectedHelperURL = URL(
            fileURLWithPath: ClosedLidShutdownContract.bundledExecutablePath
        )

        guard ClosedLidShutdownValidation.isRegularFileWithoutFollowingLinks(
                  at: expectedHelperURL.path
              ),
              ClosedLidShutdownValidation.helperHasExpectedCodeSignature(
                  at: expectedHelperURL.path
              ) else {
            return .failed("Meno 必须安装在“应用程序”文件夹后才能安装关机助手。")
        }

        let shellCommand = "'\(expectedHelperURL.path)' --install"
        let appleScriptCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = run(
            executable: "/usr/bin/osascript",
            arguments: [
                "-e",
                "do shell script \"\(appleScriptCommand)\" with administrator privileges"
            ]
        )
        guard result.status == 0 else {
            let message = result.output.isEmpty
                ? "没有完成管理员授权，关机助手尚未安装。"
                : result.output
            return .failed(message)
        }

        for _ in 0..<30 {
            let status = ClosedLidShutdownHelperManager().currentStatus()
            if status.isReady {
                return status
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return .failed("关机助手已经复制，但未能正常启动。")
    }

    private func run(executable: String, arguments: [String]) -> CommandResult {
        Self.run(executable: executable, arguments: arguments)
    }

    private static func run(executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                output: (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }
}

private struct CommandResult: Sendable {
    let status: Int32
    let output: String
}
