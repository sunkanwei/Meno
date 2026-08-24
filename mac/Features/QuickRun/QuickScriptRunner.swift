import Darwin
import Foundation

enum QuickScriptTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
    case runnerFailed(String)
}

struct QuickScriptRunResult: Equatable, Sendable {
    let script: QuickScript
    let termination: QuickScriptTermination
    let output: String
    let outputWasTruncated: Bool
    let finalOutputLine: String?

    var succeeded: Bool {
        termination == .exited(0)
    }

    var summary: String {
        if let finalOutputLine {
            return finalOutputLine
        }
        return succeeded ? "运行完成。" : terminationDescription
    }

    var detail: String {
        var parts: [String] = []
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !succeeded {
            parts.append(terminationDescription)
        }
        if outputWasTruncated, let finalOutputLine {
            parts.append("最后一行：\(finalOutputLine)")
        }
        if !trimmedOutput.isEmpty {
            parts.append(trimmedOutput)
        }
        if outputWasTruncated {
            parts.append("输出内容过长，只保留了前 64 KiB。")
        }
        return parts.isEmpty ? terminationDescription : parts.joined(separator: "\n\n")
    }

    private var terminationDescription: String {
        switch termination {
        case let .exited(code):
            code == 0 ? "运行完成。" : "脚本以状态 \(code) 结束。"
        case let .signaled(signal):
            "脚本被停止（信号 \(signal)）。"
        case let .runnerFailed(message):
            "无法运行脚本：\(message)"
        }
    }
}

private struct QuickScriptCapturedOutput: Sendable {
    let data: Data
    let truncated: Bool
    let tail: Data
}

private final class QuickScriptOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: QuickScriptCapturedOutput?

    func store(_ output: QuickScriptCapturedOutput) {
        lock.withCriticalSection {
            captured = output
        }
    }

    var result: QuickScriptCapturedOutput? {
        lock.withCriticalSection {
            captured
        }
    }
}

final class QuickScriptRunner: @unchecked Sendable {
    private static let outputLimit = 64 * 1024
    private static let outputTailLimit = 4 * 1024
    private static let zshPath = "/bin/zsh"

    private let queue = DispatchQueue(
        label: "com.sunkanwei.Meno.quick-run",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var processGroups: [UUID: pid_t] = [:]
    private var stopping = false

    func run(
        _ script: QuickScript,
        completion: @escaping @Sendable (QuickScriptRunResult) -> Void
    ) {
        let runID = UUID()
        queue.async {
            completion(self.execute(script, runID: runID))
        }
    }

    func shutdown() {
        let groups: [pid_t] = lock.withCriticalSection {
            stopping = true
            return Array(processGroups.values)
        }
        terminateProcessGroups(groups)
    }

    private func terminateProcessGroups(_ groups: [pid_t]) {
        let terminatedGroups = groups.filter { Darwin.kill(-$0, SIGTERM) == 0 }
        if !terminatedGroups.isEmpty {
            usleep(100_000)
        }
        for group in terminatedGroups where Darwin.kill(-group, 0) == 0 {
            _ = Darwin.kill(-group, SIGKILL)
        }
    }

    private func execute(_ script: QuickScript, runID: UUID) -> QuickScriptRunResult {
        guard !isStopping else {
            return launchFailure(script, message: "Meno 正在退出。")
        }
        guard isRunnableScript(script.url) else {
            return launchFailure(script, message: "脚本已经移动，或不再是普通的 .zsh 文件。")
        }

        var outputPipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&outputPipe) == 0 else {
            return launchFailure(script, message: posixErrorDescription(errno))
        }
        let readDescriptor = outputPipe[0]
        let writeDescriptor = outputPipe[1]
        defer { Darwin.close(readDescriptor) }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            Darwin.close(writeDescriptor)
            return launchFailure(script, message: "无法准备脚本运行环境。")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            Darwin.close(writeDescriptor)
            return launchFailure(script, message: "无法准备脚本进程。")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let actionError = configureFileActions(
            &fileActions,
            readDescriptor: readDescriptor,
            writeDescriptor: writeDescriptor,
            directoryPath: script.url.deletingLastPathComponent().path
        )
        guard actionError == 0 else {
            Darwin.close(writeDescriptor)
            return launchFailure(script, message: posixErrorDescription(actionError))
        }

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
            sigaddset(&defaultSignals, signal)
        }
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        )
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0 else {
            Darwin.close(writeDescriptor)
            return launchFailure(script, message: "无法隔离脚本进程。")
        }

        let executable = strdup(Self.zshPath)
        let scriptPath = strdup(script.url.path)
        guard let executable, let scriptPath else {
            free(executable)
            free(scriptPath)
            Darwin.close(writeDescriptor)
            return launchFailure(script, message: "内存不足。")
        }
        defer {
            free(executable)
            free(scriptPath)
        }

        var processID: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [executable, scriptPath, nil]
        let environmentStrings = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
        var environmentPointers: [UnsafeMutablePointer<CChar>] = []
        for string in environmentStrings {
            guard let pointer = strdup(string) else {
                for allocatedPointer in environmentPointers {
                    free(allocatedPointer)
                }
                Darwin.close(writeDescriptor)
                return launchFailure(script, message: "内存不足。")
            }
            environmentPointers.append(pointer)
        }
        defer {
            for pointer in environmentPointers {
                free(pointer)
            }
        }
        var environment: [UnsafeMutablePointer<CChar>?] = environmentPointers + [nil]
        let spawnError = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            environment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    executable,
                    &fileActions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        Darwin.close(writeDescriptor)
        guard spawnError == 0 else {
            return launchFailure(script, message: posixErrorDescription(spawnError))
        }

        let shouldStop = lock.withCriticalSection {
            processGroups[runID] = processID
            return stopping
        }
        if shouldStop {
            terminateProcessGroups([processID])
        }

        let outputCapture = QuickScriptOutputCapture()
        let outputGroup = DispatchGroup()
        outputGroup.enter()
        queue.async {
            outputCapture.store(Self.readOutput(from: readDescriptor))
            outputGroup.leave()
        }

        var waitStatus: Int32 = 0
        var waitResult: pid_t
        repeat {
            waitResult = Darwin.waitpid(processID, &waitStatus, 0)
        } while waitResult == -1 && errno == EINTR
        let waitError = waitResult == -1 ? errno : 0
        terminateProcessGroups([processID])
        outputGroup.wait()
        _ = lock.withCriticalSection {
            processGroups.removeValue(forKey: runID)
        }
        guard let captured = outputCapture.result else {
            return launchFailure(script, message: "无法读取脚本输出。")
        }

        return QuickScriptRunResult(
            script: script,
            termination: waitResult == processID
                ? Self.termination(from: waitStatus)
                : .runnerFailed("无法等待脚本结束：\(posixErrorDescription(waitError))"),
            output: String(decoding: captured.data, as: UTF8.self),
            outputWasTruncated: captured.truncated,
            finalOutputLine: Self.finalOutputLine(in: captured.tail)
        )
    }

    private func configureFileActions(
        _ actions: inout posix_spawn_file_actions_t?,
        readDescriptor: Int32,
        writeDescriptor: Int32,
        directoryPath: String
    ) -> Int32 {
        var result = posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO)
        if result == 0 {
            result = posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO)
        }
        if result == 0 {
            result = posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                "/dev/null",
                O_RDONLY,
                0
            )
        }
        if result == 0 {
            result = posix_spawn_file_actions_addclose(&actions, readDescriptor)
        }
        if result == 0 {
            result = posix_spawn_file_actions_addclose(&actions, writeDescriptor)
        }
        if result == 0 {
            result = directoryPath.withCString {
                posix_spawn_file_actions_addchdir(&actions, $0)
            }
        }
        return result
    }

    private static func readOutput(from descriptor: Int32) -> QuickScriptCapturedOutput {
        var data = Data()
        var tail = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                tail.append(buffer, count: count)
                if tail.count > Self.outputTailLimit {
                    tail.removeFirst(tail.count - Self.outputTailLimit)
                }
                let remaining = Self.outputLimit - data.count
                if remaining > 0 {
                    data.append(buffer, count: min(remaining, count))
                }
                if count > remaining {
                    truncated = true
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        return QuickScriptCapturedOutput(data: data, truncated: truncated, tail: tail)
    }

    private var isStopping: Bool {
        lock.withCriticalSection { stopping }
    }

    private func isRunnableScript(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "zsh",
              let values = try? url.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func launchFailure(_ script: QuickScript, message: String) -> QuickScriptRunResult {
        QuickScriptRunResult(
            script: script,
            termination: .runnerFailed(message),
            output: "",
            outputWasTruncated: false,
            finalOutputLine: nil
        )
    }

    private func posixErrorDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func termination(from waitStatus: Int32) -> QuickScriptTermination {
        if waitStatus & 0x7f == 0 {
            return .exited((waitStatus >> 8) & 0xff)
        }
        return .signaled(waitStatus & 0x7f)
    }

    private static func finalOutputLine(in data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
    }
}
