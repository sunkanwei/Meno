import Foundation

// Owns closed-lid mode persistence and shutdown-helper orchestration: the
// mode is written to UserDefaults and mirrored to the privileged helper
// configuration, with rollback when the helper configuration cannot be
// written. The app layer only mirrors state and forwards failures.
@MainActor
final class ClosedLidShutdownCoordinator {
    private let defaults: UserDefaults
    private let configuration = ClosedLidShutdownConfiguration()
    private let helper = ClosedLidShutdownHelperManager()

    private(set) var mode: ClosedLidMode
    private(set) var helperStatus: ClosedLidShutdownHelperStatus

    var onModeChanged: ((ClosedLidMode) -> Void)?
    var onModeApplied: ((ClosedLidMode) -> Void)?
    var onHelperStatusChanged: ((ClosedLidShutdownHelperStatus) -> Void)?
    var onFailure: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawMode = defaults.string(forKey: AppPreferenceKey.closedLidMode),
           let savedMode = ClosedLidMode(rawValue: rawMode) {
            mode = savedMode
        } else {
            mode = .keepRunning
            defaults.set(ClosedLidMode.keepRunning.rawValue, forKey: AppPreferenceKey.closedLidMode)
        }
        helperStatus = helper.currentStatus()
    }

    func refreshHelperStatus() {
        publish(helper.currentStatus())
    }

    @discardableResult
    func setMode(_ newMode: ClosedLidMode) -> Bool {
        let previousMode = mode
        mode = newMode
        defaults.set(newMode.rawValue, forKey: AppPreferenceKey.closedLidMode)
        do {
            try configuration.write(mode: newMode)
        } catch {
            mode = previousMode
            defaults.set(previousMode.rawValue, forKey: AppPreferenceKey.closedLidMode)
            onModeChanged?(previousMode)
            onFailure?("无法保存合盖模式，原有设置保持不变：\(error.localizedDescription)")
            return false
        }
        onModeChanged?(newMode)
        onModeApplied?(newMode)
        if newMode == .shutdown, !helperStatus.isReady {
            installHelper()
        }
        return true
    }

    func installHelper() {
        guard helperStatus != .installing else { return }
        publish(.installing)
        onModeApplied?(mode)
        Task { [weak self] in
            guard let self else { return }
            let status = await helper.install()
            publish(status)
            onModeApplied?(mode)
            if status.isReady {
                synchronizeConfiguration()
            }
        }
    }

    func synchronizeConfiguration() {
        do {
            try configuration.write(mode: mode)
        } catch {
            if mode == .shutdown {
                onFailure?("无法把关机模式同步给系统关机助手：\(error.localizedDescription)")
            }
        }
    }

    private func publish(_ status: ClosedLidShutdownHelperStatus) {
        helperStatus = status
        onHelperStatusChanged?(status)
    }
}
