import Darwin
import Foundation

enum ClosedLidShutdownValidation {
    static func isRegularFileWithoutFollowingLinks(at path: String) -> Bool {
        var attributes = stat()
        return lstat(path, &attributes) == 0
            && (attributes.st_mode & S_IFMT) == S_IFREG
    }

    static func helperHasExpectedCodeSignature(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--strict",
            "--requirements",
            ClosedLidShutdownContract.helperCodeRequirement,
            path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func installedFilesAreProtectedAndCurrent() -> Bool {
        isRegularFileWithoutFollowingLinks(
            at: ClosedLidShutdownContract.bundledExecutablePath
        ) && installedFilesAreProtected() && FileManager.default.contentsEqual(
            atPath: ClosedLidShutdownContract.bundledExecutablePath,
            andPath: ClosedLidShutdownContract.installedExecutablePath
        )
    }

    static func installedFilesAreProtected() -> Bool {
        protectedRegularFile(
            at: ClosedLidShutdownContract.installedExecutablePath,
            permissions: 0o755
        ) && protectedRegularFile(
            at: ClosedLidShutdownContract.launchDaemonPath,
            permissions: 0o644
        ) && launchDaemonPropertyListIsValid(at: ClosedLidShutdownContract.launchDaemonPath)
    }

    static func launchDaemonPropertyListIsValid(at path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) else {
            return false
        }
        return launchDaemonPropertyListIsValid(propertyList)
    }

    static func launchDaemonPropertyListIsValid(_ propertyList: Any) -> Bool {
        guard let dictionary = propertyList as? [String: Any],
              dictionary.count == ClosedLidShutdownContract.launchDaemonPropertyList.count,
              dictionary["Label"] as? String == ClosedLidShutdownContract.helperLabel,
              dictionary["ProgramArguments"] as? [String] == [
                  ClosedLidShutdownContract.installedExecutablePath
              ],
              dictionary["RunAtLoad"] as? Bool == true,
              let keepAlive = dictionary["KeepAlive"] as? [String: Any],
              keepAlive.count == 1,
              keepAlive["Crashed"] as? Bool == true,
              dictionary["ProcessType"] as? String == "Background",
              dictionary["ThrottleInterval"] as? Int == 10 else {
            return false
        }
        return true
    }

    private static func protectedRegularFile(at path: String, permissions: mode_t) -> Bool {
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { return false }
        return (attributes.st_mode & S_IFMT) == S_IFREG
            && attributes.st_uid == 0
            && attributes.st_gid == 0
            && (attributes.st_mode & mode_t(0o777)) == permissions
    }
}
