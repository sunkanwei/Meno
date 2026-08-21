import AppKit
import CoreServices

enum FinderAutomationPermissionStatus: Equatable, Sendable {
    case checking
    case notDetermined
    case allowed
    case denied
    case finderUnavailable
    case unavailable
}

enum FinderAutomationPermission {
    static func determine(
        askUserIfNeeded: Bool
    ) async -> FinderAutomationPermissionStatus {
        await Task.detached(priority: .userInitiated) {
            determineSynchronously(askUserIfNeeded: askUserIfNeeded)
        }.value
    }

    @MainActor
    static func openSystemSettings() {
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        ) else {
            return
        }
        NSWorkspace.shared.open(settingsURL)
    }

    static func status(for result: OSStatus) -> FinderAutomationPermissionStatus {
        if result == noErr {
            return .allowed
        }
        if result == OSStatus(errAEEventWouldRequireUserConsent) {
            return .notDetermined
        }
        if result == OSStatus(errAEEventNotPermitted) {
            return .denied
        }
        if result == OSStatus(procNotFound) {
            return .finderUnavailable
        }
        return .unavailable
    }

    private static func determineSynchronously(
        askUserIfNeeded: Bool
    ) -> FinderAutomationPermissionStatus {
        var target = AEAddressDesc()
        let identifierData = Data(FinderProcess.bundleIdentifier.utf8)
        let descriptorStatus = identifierData.withUnsafeBytes { bytes in
            AECreateDesc(
                typeApplicationBundleID,
                bytes.baseAddress,
                identifierData.count,
                &target
            )
        }
        guard descriptorStatus == noErr else {
            return .unavailable
        }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(
            &target,
            kAECoreSuite,
            kAESetData,
            askUserIfNeeded
        )
        return status(for: result)
    }
}
