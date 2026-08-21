import Darwin
import Foundation

enum PowerHelperInstaller {
    private struct ExistingInstallation {
        let hadFiles: Bool
        let filesAreValid: Bool
        let jobWasRegistered: Bool
    }

    private struct TransactionURLs {
        let stagedExecutable: URL
        let stagedDaemon: URL
        let backupExecutable: URL
        let backupDaemon: URL
        let failedExecutable: URL
        let failedDaemon: URL
    }

    private struct LaunchctlResult {
        let status: Int32
        let output: String
    }

    static func install() throws {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let executableURL = URL(fileURLWithPath: ClosedLidShutdownContract.installedExecutablePath)
        let daemonURL = URL(fileURLWithPath: ClosedLidShutdownContract.launchDaemonPath)

        guard sourceURL.path == ClosedLidShutdownContract.bundledExecutablePath,
              ClosedLidShutdownValidation.isRegularFileWithoutFollowingLinks(at: sourceURL.path),
              ClosedLidShutdownValidation.helperHasExpectedCodeSignature(at: sourceURL.path) else {
            throw installationError("The bundled power helper is not trusted.")
        }

        try fileManager.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: daemonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let transaction = transactionURLs(executableURL: executableURL, daemonURL: daemonURL)
        defer {
            removeIfPresent(transaction.stagedExecutable, using: fileManager)
            removeIfPresent(transaction.stagedDaemon, using: fileManager)
        }

        try stageExecutable(from: sourceURL, at: transaction.stagedExecutable, using: fileManager)
        try stageLaunchDaemon(at: transaction.stagedDaemon)
        guard stagedExecutableIsValid(at: transaction.stagedExecutable),
              stagedDaemonIsValid(at: transaction.stagedDaemon) else {
            throw installationError("The staged power helper failed validation.")
        }

        let executableExists = fileManager.fileExists(atPath: executableURL.path)
        let daemonExists = fileManager.fileExists(atPath: daemonURL.path)
        let existing = ExistingInstallation(
            hadFiles: executableExists || daemonExists,
            filesAreValid: executableExists
                && daemonExists
                && ClosedLidShutdownValidation.installedFilesAreProtected()
                && ClosedLidShutdownValidation.helperHasExpectedCodeSignature(
                    at: executableURL.path
                ),
            jobWasRegistered: launchdJobIsRegistered()
        )
        var installedExecutable = false
        var installedDaemon = false

        do {
            let bootout = try runLaunchctl(
                ["bootout", "system/\(ClosedLidShutdownContract.helperLabel)"],
                allowsFailure: true
            )
            if bootout.status != 0, launchdJobIsRegistered() {
                throw launchctlError(bootout)
            }

            try backUpIfPresent(executableURL, to: transaction.backupExecutable, using: fileManager)
            try backUpIfPresent(daemonURL, to: transaction.backupDaemon, using: fileManager)
            try fileManager.moveItem(at: transaction.stagedExecutable, to: executableURL)
            installedExecutable = true
            try fileManager.moveItem(at: transaction.stagedDaemon, to: daemonURL)
            installedDaemon = true

            guard ClosedLidShutdownValidation.installedFilesAreProtectedAndCurrent(),
                  ClosedLidShutdownValidation.helperHasExpectedCodeSignature(
                    at: executableURL.path
                  ) else {
                throw installationError("The installed power helper failed validation.")
            }

            _ = try runLaunchctl(["bootstrap", "system", daemonURL.path])
            guard launchdJobIsRegistered() else {
                throw installationError("launchd did not register the new power helper.")
            }

            removeIfPresent(transaction.backupExecutable, using: fileManager)
            removeIfPresent(transaction.backupDaemon, using: fileManager)
        } catch {
            let rollbackResult = rollback(
                existing: existing,
                executableURL: executableURL,
                daemonURL: daemonURL,
                transaction: transaction,
                installedExecutable: installedExecutable,
                installedDaemon: installedDaemon,
                using: fileManager
            )
            throw installationError(
                "New helper installation failed: \(error.localizedDescription) \(rollbackResult)"
            )
        }
    }

    private static func transactionURLs(
        executableURL: URL,
        daemonURL: URL
    ) -> TransactionURLs {
        let identifier = UUID().uuidString.lowercased()
        func sibling(of url: URL, suffix: String) -> URL {
            url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).\(suffix).\(identifier)")
        }
        return TransactionURLs(
            stagedExecutable: sibling(of: executableURL, suffix: "staging"),
            stagedDaemon: sibling(of: daemonURL, suffix: "staging"),
            backupExecutable: sibling(of: executableURL, suffix: "backup"),
            backupDaemon: sibling(of: daemonURL, suffix: "backup"),
            failedExecutable: sibling(of: executableURL, suffix: "failed"),
            failedDaemon: sibling(of: daemonURL, suffix: "failed")
        )
    }

    private static func stageExecutable(
        from sourceURL: URL,
        at stagedURL: URL,
        using fileManager: FileManager
    ) throws {
        try fileManager.copyItem(at: sourceURL, to: stagedURL)
        try applyRootOwnershipAndPermissions(0o755, to: stagedURL)
    }

    private static func stageLaunchDaemon(at stagedURL: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ClosedLidShutdownContract.launchDaemonPropertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: stagedURL, options: .withoutOverwriting)
        try applyRootOwnershipAndPermissions(0o644, to: stagedURL)
    }

    private static func backUpIfPresent(
        _ sourceURL: URL,
        to backupURL: URL,
        using fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        try fileManager.moveItem(at: sourceURL, to: backupURL)
    }

    private static func rollback(
        existing: ExistingInstallation,
        executableURL: URL,
        daemonURL: URL,
        transaction: TransactionURLs,
        installedExecutable: Bool,
        installedDaemon: Bool,
        using fileManager: FileManager
    ) -> String {
        var failures: [String] = []
        if launchdJobIsRegistered() {
            do {
                let result = try runLaunchctl(
                    ["bootout", "system/\(ClosedLidShutdownContract.helperLabel)"],
                    allowsFailure: true
                )
                if result.status != 0, launchdJobIsRegistered() {
                    failures.append("could not stop the partial new job: \(result.output)")
                }
            } catch {
                failures.append("could not stop the partial new job: \(error.localizedDescription)")
            }
        }

        if installedExecutable {
            moveForRecovery(
                executableURL,
                to: transaction.failedExecutable,
                description: "isolate the new executable",
                using: fileManager,
                failures: &failures
            )
        }
        if installedDaemon {
            moveForRecovery(
                daemonURL,
                to: transaction.failedDaemon,
                description: "isolate the new daemon",
                using: fileManager,
                failures: &failures
            )
        }
        if fileManager.fileExists(atPath: transaction.backupExecutable.path) {
            moveForRecovery(
                transaction.backupExecutable,
                to: executableURL,
                description: "restore the previous executable",
                using: fileManager,
                failures: &failures
            )
        }
        if fileManager.fileExists(atPath: transaction.backupDaemon.path) {
            moveForRecovery(
                transaction.backupDaemon,
                to: daemonURL,
                description: "restore the previous daemon",
                using: fileManager,
                failures: &failures
            )
        }

        if existing.jobWasRegistered, existing.filesAreValid, failures.isEmpty {
            do {
                _ = try runLaunchctl(["bootstrap", "system", daemonURL.path])
                guard launchdJobIsRegistered() else {
                    throw installationError("launchd did not restore the previous job.")
                }
            } catch {
                failures.append("could not restart the previous job: \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            return existing.hadFiles || existing.jobWasRegistered
                ? "The previous installation was restored."
                : "There was no previous installation to restore."
        }
        return "Rollback was incomplete: \(failures.joined(separator: "; "))"
    }

    private static func moveForRecovery(
        _ sourceURL: URL,
        to destinationURL: URL,
        description: String,
        using fileManager: FileManager,
        failures: inout [String]
    ) {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            failures.append("could not \(description): source file is missing")
            return
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            failures.append("could not \(description): \(error.localizedDescription)")
        }
    }

    private static func stagedExecutableIsValid(at url: URL) -> Bool {
        protectedRegularFile(at: url, permissions: 0o755)
            && ClosedLidShutdownValidation.helperHasExpectedCodeSignature(at: url.path)
    }

    private static func stagedDaemonIsValid(at url: URL) -> Bool {
        protectedRegularFile(at: url, permissions: 0o644)
            && ClosedLidShutdownValidation.launchDaemonPropertyListIsValid(at: url.path)
    }

    private static func protectedRegularFile(at url: URL, permissions: mode_t) -> Bool {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else { return false }
        return (attributes.st_mode & S_IFMT) == S_IFREG
            && attributes.st_uid == 0
            && attributes.st_gid == 0
            && (attributes.st_mode & mode_t(0o777)) == permissions
    }

    private static func applyRootOwnershipAndPermissions(
        _ permissions: Int,
        to url: URL
    ) throws {
        try FileManager.default.setAttributes(
            [
                .ownerAccountID: 0,
                .groupOwnerAccountID: 0,
                .posixPermissions: permissions,
            ],
            ofItemAtPath: url.path
        )
    }

    private static func launchdJobIsRegistered() -> Bool {
        guard let result = try? runLaunchctl(
            ["print", "system/\(ClosedLidShutdownContract.helperLabel)"],
            allowsFailure: true
        ) else { return false }
        return result.status == 0
    }

    private static func runLaunchctl(
        _ arguments: [String],
        allowsFailure: Bool = false
    ) throws -> LaunchctlResult {
        let process = Process()
        let outputPipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = outputPipe
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        if finished.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                guard finished.wait(timeout: .now() + 0.5) == .success else {
                    throw installationError("launchctl operation timed out.")
                }
            }
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let result = LaunchctlResult(status: process.terminationStatus, output: output)
        if !allowsFailure, result.status != 0 {
            throw launchctlError(result)
        }
        return result
    }

    private static func launchctlError(_ result: LaunchctlResult) -> NSError {
        NSError(
            domain: "com.sunkanwei.Meno.PowerHelperInstaller",
            code: Int(result.status),
            userInfo: [
                NSLocalizedDescriptionKey: result.output.isEmpty
                    ? "launchctl failed with status \(result.status)."
                    : result.output,
            ]
        )
    }

    private static func removeIfPresent(_ url: URL, using fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func installationError(_ message: String) -> NSError {
        NSError(
            domain: "com.sunkanwei.Meno.PowerHelperInstaller",
            code: Int(EX_NOPERM),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
