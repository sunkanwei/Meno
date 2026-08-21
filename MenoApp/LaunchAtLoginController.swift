import Darwin
import Foundation
import ServiceManagement

enum LaunchAtLoginStatus {
    case disabled
    case enabled
    case requiresApproval
}

@MainActor
final class LaunchAtLoginController {
    private static let hasConfiguredKey = "HasConfiguredLaunchAtLogin"
    nonisolated private static let fallbackLabel = "com.sunkanwei.Meno.LoginItem"
    nonisolated private static let installedApplicationPath = "/Applications/Meno.app"

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let service = SMAppService.mainApp
    private(set) var status: LaunchAtLoginStatus = .disabled
    private var refreshTask: Task<Void, Never>?

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        refreshTask?.cancel()
        refreshTask = nil
        switch service.status {
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notRegistered, .notFound:
            let plistURL = fallbackPropertyListURL
            refreshTask = Task { [weak self] in
                let enabled = await Task.detached(priority: .utility) {
                    Self.fallbackIsEnabled(at: plistURL)
                }.value
                guard let self, !Task.isCancelled else { return }
                status = enabled ? .enabled : .disabled
                refreshTask = nil
            }
        @unknown default:
            status = .disabled
        }
    }

    func configureDefaultIfNeeded() {
        guard defaults.object(forKey: Self.hasConfiguredKey) == nil else { return }
        do {
            try setEnabled(true)
            defaults.set(true, forKey: Self.hasConfiguredKey)
        } catch {
            NSLog("Meno could not enable launch at login: %@", error.localizedDescription)
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
        refreshStatus()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func enable() throws {
        switch service.status {
        case .enabled:
            status = .enabled
        case .notFound:
            try installFallbackRegistration()
        case .requiresApproval:
            status = .requiresApproval
        case .notRegistered:
            try service.register()
        @unknown default:
            try service.register()
        }
    }

    private func disable() throws {
        var firstError: Error?
        let result = try Self.runLaunchctl([
            "bootout",
            "gui/\(getuid())/\(Self.fallbackLabel)",
        ], allowsFailure: true)
        if result.status != 0 && Self.fallbackJobIsRegistered() {
            firstError = Self.launchctlError(result)
        }
        if firstError == nil,
           fileManager.fileExists(atPath: fallbackPropertyListURL.path) {
            do {
                try fileManager.removeItem(at: fallbackPropertyListURL)
            } catch {
                firstError = error
            }
        }

        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    private var fallbackPropertyListURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.fallbackLabel).plist", isDirectory: false)
    }

    private func installFallbackRegistration() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: Self.installedApplicationPath,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw NSError(
                domain: "com.sunkanwei.Meno.LaunchAtLogin",
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "固定位置 /Applications/Meno.app 不存在。"]
            )
        }
        let directoryURL = fallbackPropertyListURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: Self.fallbackPropertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: fallbackPropertyListURL, options: .atomic)

        _ = try Self.runLaunchctl([
            "bootout",
            "gui/\(getuid())/\(Self.fallbackLabel)",
        ], allowsFailure: true)
        let bootstrap = try Self.runLaunchctl([
            "bootstrap",
            "gui/\(getuid())",
            fallbackPropertyListURL.path,
        ])
        guard bootstrap.status == 0,
              Self.fallbackIsEnabled(at: fallbackPropertyListURL) else {
            throw Self.launchctlError(bootstrap)
        }
    }

    nonisolated private static var fallbackPropertyList: [String: Any] {
        [
            "Label": fallbackLabel,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ProgramArguments": [
                "/usr/bin/open",
                "-g",
                installedApplicationPath,
            ],
            "RunAtLoad": true,
        ]
    }

    nonisolated private static func fallbackIsEnabled(at plistURL: URL) -> Bool {
        let applicationExists = FileManager.default.fileExists(atPath: installedApplicationPath)
        guard let data = try? Data(contentsOf: plistURL),
              data.count <= 64 * 1_024,
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else { return false }
        let propertyListMatches = NSDictionary(dictionary: value).isEqual(
            to: fallbackPropertyList
        )
        guard applicationExists, propertyListMatches else { return false }
        return fallbackJobIsRegistered()
    }

    nonisolated private static func fallbackJobIsRegistered() -> Bool {
        guard let result = try? runLaunchctl([
            "print",
            "gui/\(getuid())/\(fallbackLabel)",
        ], allowsFailure: true) else { return false }
        return result.status == 0
    }

    private struct LaunchctlResult {
        let status: Int32
        let output: String
    }

    nonisolated private static func runLaunchctl(
        _ arguments: [String],
        allowsFailure: Bool = false
    ) throws -> LaunchctlResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 2) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                guard finished.wait(timeout: .now() + 0.5) == .success else {
                    throw NSError(
                        domain: "com.sunkanwei.Meno.LaunchAtLogin",
                        code: Int(ETIMEDOUT),
                        userInfo: [NSLocalizedDescriptionKey: "launchctl 操作超时。"]
                    )
                }
            }
        }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let result = LaunchctlResult(status: process.terminationStatus, output: output)
        if !allowsFailure && result.status != 0 {
            throw launchctlError(result)
        }
        return result
    }

    nonisolated private static func launchctlError(_ result: LaunchctlResult) -> NSError {
        NSError(
            domain: "com.sunkanwei.Meno.LaunchAtLogin",
            code: Int(result.status),
            userInfo: [
                NSLocalizedDescriptionKey: result.output.isEmpty
                    ? "launchctl 操作失败（\(result.status)）。"
                    : result.output,
            ]
        )
    }
}
