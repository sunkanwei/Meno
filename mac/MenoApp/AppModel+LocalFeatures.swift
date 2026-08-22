import AppKit
import FinderSync

@MainActor
extension AppModel {
    func setFinderContextMenuEnabled(_ enabled: Bool) {
        finderContextMenuEnabled = enabled
        finderContextMenuPreferences.isEnabled = enabled
    }

    func setSelectedTerminalBundleIdentifier(_ bundleIdentifier: String) {
        guard terminalApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        selectedTerminalBundleIdentifier = bundleIdentifier
        finderContextMenuPreferences.terminalBundleIdentifier = bundleIdentifier
    }

    func setMarkdownPreviewDefaultWidth(_ width: Int) { setMarkdownPreviewDefaultSize(width: width, height: markdownPreviewDefaultHeight) }

    func setMarkdownPreviewDefaultHeight(_ height: Int) { setMarkdownPreviewDefaultSize(width: markdownPreviewDefaultWidth, height: height) }

    func restoreRecommendedMarkdownPreviewSize() {
        let size = MarkdownPreviewWindowPreferences.recommendedSize
        setMarkdownPreviewDefaultSize(width: Int(size.width), height: Int(size.height))
    }

    func refreshTerminalApplications() {
        terminalApplications = TerminalApplicationDetector.detect()
        guard terminalApplications.contains(where: {
            $0.bundleIdentifier == selectedTerminalBundleIdentifier
        }) else {
            selectedTerminalBundleIdentifier = FinderContextMenuPreferences.systemTerminalBundleIdentifier
            finderContextMenuPreferences.terminalBundleIdentifier = selectedTerminalBundleIdentifier
            return
        }
    }

    func requestAccessibilityPermission() {
        AccessibilityPermission.requestReadAndPostEvents()
        refreshPermissionsSoon()
    }

    func requestInputMonitoringPermission() {
        AccessibilityPermission.requestKeyboardListening()
        refreshPermissionsSoon()
    }

    func requestFinderAutomationPermission() {
        refreshFinderAutomationPermission(askUserIfNeeded: true)
    }

    func openFinderAutomationSettings() {
        FinderAutomationPermission.openSystemSettings()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationPermissionPending = true
        notificationTestMessage = nil
        notificationsEnabled = enabled
        if !enabled { finderFeedback.stop() }
        notifications.setEnabled(enabled) { [weak self] authorization in
            Task { @MainActor in
                self?.notificationPermissionPending = false
                self?.notificationAuthorization = authorization
            }
        }
    }

    func setPasteSoundEnabled(_ enabled: Bool) {
        pasteSoundEnabled = enabled
        finderFeedback.setPasteSoundEnabled(enabled)
    }

    func openNotificationSettings() { notifications.openSystemSettings() }

    func openFinderExtensionSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    func refreshNotificationAuthorization() {
        notifications.refreshAuthorizationState { [weak self] authorization in
            Task { @MainActor in
                self?.notificationAuthorization = authorization
            }
        }
    }

    func sendTestNotification() {
        notificationTestPending = true
        notificationTestMessage = nil
        notifications.sendTest { [weak self] submitted in
            Task { @MainActor in
                self?.notificationTestPending = false
                self?.notificationTestMessage = submitted
                    ? "测试通知已交由系统；若没有看到横幅，请检查通知样式和专注模式。"
                    : "测试通知未能交给系统，请重新检查通知权限。"
                self?.refreshNotificationAuthorization()
            }
        }
    }

    private func refreshPermissionsSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshPermissionsAndRuntime()
        }
    }

    private func setMarkdownPreviewDefaultSize(width: Int, height: Int) {
        markdownPreviewWindowPreferences.setDefaultSize(
            CGSize(width: width, height: height)
        )
        let savedSize = markdownPreviewWindowPreferences.defaultSize
        markdownPreviewDefaultWidth = Int(savedSize.width)
        markdownPreviewDefaultHeight = Int(savedSize.height)
    }
}

@MainActor
extension AppModel {
    func setFinderShortcutsEnabled(_ enabled: Bool) {
        finderShortcutsEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.finderShortcutsEnabled)
        finderShortcuts.setEnabled(enabled)
    }
    func setGoToParentEnabled(_ enabled: Bool) {
        goToParentEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.finderGoToParentEnabled)
        finderShortcuts.setEnabledFeatures(enabledShortcutFeatures)
    }
    func setRenameEnabled(_ enabled: Bool) {
        renameEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.finderRenameEnabled)
        finderShortcuts.setEnabledFeatures(enabledShortcutFeatures)
    }
    func setOpenSelectionEnabled(_ enabled: Bool) {
        openSelectionEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.finderOpenSelectionEnabled)
        finderShortcuts.setEnabledFeatures(enabledShortcutFeatures)
    }
    func setCutAndMoveEnabled(_ enabled: Bool) {
        cutAndMoveEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.finderCutAndMoveEnabled)
        finderShortcuts.setEnabledFeatures(enabledShortcutFeatures)
    }
    func setMoveToTrashEnabled(_ enabled: Bool) {
        moveToTrashEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.finderMoveToTrashEnabled)
        finderShortcuts.setEnabledFeatures(enabledShortcutFeatures)
    }
    func setMenuBarGlassEnabled(_ enabled: Bool) {
        menuBarGlassEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.menuBarGlassEnabled)
        menuBarGlass.setEnabled(enabled)
    }
    func setScrollingEnabled(_ enabled: Bool) {
        scrollingEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.scrollingEnabled)
        scrolling.setEnabled(enabled)
    }
    func setActivityMonitorShortcutEnabled(_ enabled: Bool) {
        activityMonitorShortcutEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.activityMonitorShortcutEnabled)
        activityMonitorShortcut.setEnabled(enabled)
    }
}
