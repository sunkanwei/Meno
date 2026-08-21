import Foundation

enum ClosedLidShutdownContract {
    private static let supportedOSMajorVersions: Set<Int> = [26, 27]
    static let helperLabel = "com.sunkanwei.Meno.PowerHelper"
    static let helperFileName = helperLabel
    static let helperSigningCertificateHash = "5ca0e2d630dbafa3341117b16732169a664c6181"
    static let modeFileName = "ClosedLidPowerMode.plist"
    static let modeKey = "mode"
    static let shutdownModeValue = "shutdown"
    static let modeChangedNotification = "com.sunkanwei.Meno.closedLidPowerModeChanged"

    static let installedExecutablePath =
        "/Library/PrivilegedHelperTools/\(helperFileName)"
    static let bundledExecutablePath =
        "/Applications/Meno.app/Contents/Library/PrivilegedHelperTools/\(helperFileName)"
    static let launchDaemonPath =
        "/Library/LaunchDaemons/\(helperLabel).plist"

    static var isSupportedOperatingSystem: Bool {
        supports(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static func supports(majorVersion: Int) -> Bool {
        supportedOSMajorVersions.contains(majorVersion)
    }

    static var helperCodeRequirement: String {
        "=identifier \"\(helperLabel)\" and certificate root = H\"\(helperSigningCertificateHash)\""
    }

    static var launchDaemonPropertyList: [String: Any] {
        [
            "Label": helperLabel,
            "ProgramArguments": [installedExecutablePath],
            "RunAtLoad": true,
            "KeepAlive": ["Crashed": true],
            "ProcessType": "Background",
            "ThrottleInterval": 10
        ]
    }
}
