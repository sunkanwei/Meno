import AppKit

enum FinderProcess {
    static let bundleIdentifier = "com.apple.finder"

    static var currentPID: Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?
            .processIdentifier
    }
}
