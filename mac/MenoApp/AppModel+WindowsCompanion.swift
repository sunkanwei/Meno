import Foundation

@MainActor
extension AppModel {
    func setClipboardSharingEnabled(_ enabled: Bool) {
        clipboardSharingEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.clipboardSharingEnabled)
        windowsCompanion.setClipboardEnabled(enabled)
    }
    func setMicrophoneSharingEnabled(_ enabled: Bool) {
        microphoneSharingEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.microphoneSharingEnabled)
        windowsCompanion.setMicrophoneEnabled(enabled)
    }
    func setMicrophoneActivationKey(_ activationKey: MicrophoneActivationKey) {
        guard activationKey.isValid else { return }
        microphoneActivationKey = activationKey
        if let data = try? JSONEncoder().encode(activationKey) {
            defaults.set(data, forKey: AppPreferenceKey.microphoneActivationKey)
        }
        crossScreenMouse.setMicrophoneActivationKey(activationKey)
    }
    func setMicrophoneActivationKeyRecording(_ recording: Bool) {
        crossScreenMouse.setSoftKVMShortcutCaptureEnabled(!recording)
        softKVMHotKey.setEnabled(!recording && crossScreenMouseEnabled)
    }
    func openMicrophoneSettings() {
        windowsCompanion.openMicrophoneSettings()
    }
    func restartWindowsCompanion() {
        windowsCompanion.restartListening()
    }
    func setCrossScreenMouseEnabled(_ enabled: Bool) {
        if !enabled {
            cancelSoftKVMShortcutTest()
        }
        softKVM.setEnabled(enabled)
    }
    func setDisplayHandoffEnabled(_ enabled: Bool) {
        displayHandoffEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.displayHandoffEnabled)
        applyDisplayHandoffConfiguration()
    }
    func setDisplayHandoffAlignment(_ alignment: DisplayHandoffAlignment) {
        displayHandoffAlignment = alignment
        defaults.set(alignment.rawValue, forKey: AppPreferenceKey.displayHandoffAlignment)
        applyDisplayHandoffConfiguration()
    }
    func toggleSoftKVM() { softKVM.toggle() }
    var canForceShutdownWindows: Bool {
        softKVM.canForceShutdownWindows
    }
    var remoteShutdownActionTitle: String {
        softKVM.remoteShutdownActionTitle
    }

    func forceShutdownWindows(onFailure: @escaping (String) -> Void) {
        softKVM.forceShutdownWindows(onFailure: onFailure)
    }

    func setSoftKVMShortcut(_ shortcut: SoftKVMShortcut) {
        guard shortcut.isValid else { return }
        cancelSoftKVMShortcutTest()
        softKVMShortcut = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: AppPreferenceKey.softKVMShortcut)
        }
        softKVM.setShortcut(shortcut)
        softKVMHotKey.setShortcut(shortcut)
    }

    func setSoftKVMShortcutRecording(_ recording: Bool) {
        if recording {
            cancelSoftKVMShortcutTest()
        }
        crossScreenMouse.setSoftKVMShortcutCaptureEnabled(!recording)
        softKVMHotKey.setEnabled(!recording && crossScreenMouseEnabled)
    }

    func beginSoftKVMShortcutTest() {
        guard crossScreenMouseEnabled else { return }
        softKVMShortcutTest.begin(
            prompt: "请按 \(softKVMShortcut.title)",
            timeoutMessage: "未识别到快捷键，请检查辅助功能和输入监听权限。"
        )
    }

    func handleSoftKVMShortcut() {
        if softKVMShortcutTest.handleShortcutPressed(
            successMessage: "快捷键识别成功，没有执行显示切换。"
        ) {
            return
        }
        guard !softKVMStatus.isBusy else { return }
        let now = ContinuousClock.now
        if let lastSoftKVMShortcutAt,
           lastSoftKVMShortcutAt.duration(to: now) < .seconds(2) {
            return
        }
        lastSoftKVMShortcutAt = now
        notifications.sendSoftKVMShortcutAcknowledgement(
            message: softKVMStatus.shortcutAcknowledgement
        )
        guard softKVMStatus.actionEnabled else {
            return
        }
        toggleSoftKVM()
    }

    func applySoftKVMEnabledState(_ enabled: Bool) {
        if !enabled {
            cancelSoftKVMShortcutTest()
        }
        crossScreenMouseEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.crossScreenMouseEnabled)
        softKVMHotKey.setEnabled(enabled)
    }

    func cancelSoftKVMShortcutTest() {
        softKVMShortcutTest.cancel()
        lastSoftKVMShortcutAt = nil
    }

    func applyDisplayHandoffConfiguration() {
        crossScreenMouse.setDisplayHandoffConfiguration(
            DisplayHandoffConfiguration(
                enabled: displayHandoffEnabled,
                alignment: displayHandoffAlignment
            )
        )
    }

    @discardableResult
    func setClosedLidMode(_ mode: ClosedLidMode) -> Bool {
        closedLidShutdown.setMode(mode)
    }

    func installClosedLidShutdownHelper() {
        closedLidShutdown.installHelper()
    }
}
