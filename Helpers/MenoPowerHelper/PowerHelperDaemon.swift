import Foundation
import OSLog

final class PowerHelperDaemon: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "PowerHelper"
    )
    private let stateQueue = DispatchQueue(label: "com.sunkanwei.Meno.PowerHelper.state")
    private lazy var lidMonitor = PowerHelperLidMonitor { [weak self] in
        self?.evaluateCurrentState(reason: "lid-state-changed")
    }
    private var shutdownRequested = false

    func start() -> Bool {
        guard ClosedLidShutdownContract.isSupportedOperatingSystem else {
            logger.error("Power helper is idle on an unverified macOS version")
            return true
        }
        guard ClosedLidShutdownValidation.installedFilesAreProtected(),
              ClosedLidShutdownValidation.helperHasExpectedCodeSignature(
                  at: ClosedLidShutdownContract.installedExecutablePath
              ) else {
            logger.error("Power helper refused to run from an untrusted installation")
            return false
        }
        guard lidMonitor.start() else { return false }
        observeModeChanges()
        evaluateCurrentState(reason: "startup")
        logger.info("Power helper is ready")
        return true
    }

    private func observeModeChanges() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            Self.modeChangedCallback,
            ClosedLidShutdownContract.modeChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func evaluateCurrentState(reason: String) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard ClosedLidShutdownContract.isSupportedOperatingSystem else {
                shutdownRequested = false
                logger.error("Power helper disabled on an unverified macOS version")
                return
            }
            guard ClosedLidShutdownValidation.installedFilesAreProtected() else {
                shutdownRequested = false
                logger.error("Power helper disabled because its installation is no longer trusted")
                return
            }
            guard PowerModeConfiguration.current()?.requestsShutdown == true else {
                shutdownRequested = false
                return
            }
            guard lidMonitor.currentStateIsClosed() == true,
                  !shutdownRequested else {
                return
            }
            shutdownRequested = true
            requestShutdown(reason: reason)
        }
    }

    private func requestShutdown(reason: String) {
        guard let consoleUser = PowerModeConfiguration.consoleUser() else {
            shutdownRequested = false
            logger.error("Could not identify the console user before shutdown")
            return
        }
        guard LoginSessionRelaunchState.clear(for: consoleUser.name) else {
            shutdownRequested = false
            logger.error("Shutdown cancelled because login session relaunch state could not be cleared")
            return
        }
        logger.notice("Login session relaunch state cleared")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
        process.arguments = ["-h", "now", "Meno: MacBook lid closed"]
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit,
                  process.terminationStatus == 0 else {
                shutdownRequested = false
                logger.error(
                    "System shutdown command failed with status \(process.terminationStatus)"
                )
                return
            }
            logger.notice("System shutdown requested: \(reason, privacy: .public)")
        } catch {
            shutdownRequested = false
            logger.error("Could not request system shutdown: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let modeChangedCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let daemon = Unmanaged<PowerHelperDaemon>
            .fromOpaque(observer)
            .takeUnretainedValue()
        daemon.evaluateCurrentState(reason: "mode-changed")
    }
}

private enum LoginSessionRelaunchState {
    private static let applicationID = "com.apple.loginwindow"
    private static let savesStateKey = "TALLogoutSavesState"
    private static let appsToRelaunchKey = "TALAppsToRelaunchAtLogin"

    static func clear(for userName: String) -> Bool {
        let preferenceApplicationID = applicationID as CFString
        let preferenceSavesStateKey = savesStateKey as CFString
        let preferenceAppsToRelaunchKey = appsToRelaunchKey as CFString
        let preferenceUser = userName as CFString

        // Immediate shutdown can otherwise reuse a stale loginwindow relaunch list.
        CFPreferencesSetValue(
            preferenceSavesStateKey,
            kCFBooleanFalse,
            preferenceApplicationID,
            preferenceUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSetValue(
            preferenceAppsToRelaunchKey,
            [] as CFArray,
            preferenceApplicationID,
            preferenceUser,
            kCFPreferencesCurrentHost
        )

        guard CFPreferencesSynchronize(
            preferenceApplicationID,
            preferenceUser,
            kCFPreferencesAnyHost
        ), CFPreferencesSynchronize(
            preferenceApplicationID,
            preferenceUser,
            kCFPreferencesCurrentHost
        ), let savedState = CFPreferencesCopyValue(
            preferenceSavesStateKey,
            preferenceApplicationID,
            preferenceUser,
            kCFPreferencesAnyHost
        ) as? Bool, !savedState,
        let apps = CFPreferencesCopyValue(
            preferenceAppsToRelaunchKey,
            preferenceApplicationID,
            preferenceUser,
            kCFPreferencesCurrentHost
        ) as? [Any] else {
            return false
        }
        return apps.isEmpty
    }
}
