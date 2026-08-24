import Foundation

enum AppPreferenceKey {
    static let finderShortcutsEnabled = "FinderShortcutsEnabled"
    static let finderGoToParentEnabled = "FinderGoToParentEnabled"
    static let finderOpenSelectionEnabled = "FinderOpenSelectionEnabled"
    static let finderRenameEnabled = "FinderRenameEnabled"
    static let finderCutAndMoveEnabled = "FinderCutAndMoveEnabled"
    static let finderMoveToTrashEnabled = "FinderMoveToTrashEnabled"
    static let menuBarGlassEnabled = "MenuBarGlassEnabled"
    static let scrollingEnabled = "ScrollingEnabled"
    static let activityMonitorShortcutEnabled = "ActivityMonitorShortcutEnabled"
    static let pasteSoundEnabled = "ClipboardPasteSoundEnabled"
    static let closedLidMode = "ClosedLidMode"
    static let clipboardSharingEnabled = "ClipboardSharingEnabled"
    static let microphoneSharingEnabled = "MicrophoneSharingEnabled"
    static let microphoneActivationKey = "MicrophoneActivationKey"
    static let crossScreenMouseEnabled = "CrossScreenMouseEnabled"
    static let quickRunDirectoryPath = "QuickRunDirectoryPath"

    // These legacy strings are a persistent settings compatibility boundary.
    static let displayHandoffEnabled = "LocalDisplayHandoffEnabled"
    static let displayHandoffAlignment = "LocalDisplayHandoffAlignment"
    static let softKVMShortcut = "SoftKVMShortcut"
}

extension UserDefaults {
    // Features are enabled unless the user explicitly turned them off.
    func boolValue(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
