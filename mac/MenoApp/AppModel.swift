import AppKit
import Combine
import FinderSync

@MainActor
final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard
    private let finderContextMenuPreferences = FinderContextMenuPreferences()
    private let markdownPreviewWindowPreferences = MarkdownPreviewWindowPreferences()
    private let notifications = AppNotifications()
    private let finderFeedback = FinderFeedbackPresenter()
    let windowsAgent = WindowsAgentController()

    @Published private(set) var finderShortcutsStatus: FinderShortcutsStatus = .off
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var postEventGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var finderAutomationPermissionStatus:
        FinderAutomationPermissionStatus = .checking
    @Published private(set) var hasCutState = false
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var pasteSoundEnabled = true
    @Published private(set) var notificationPermissionPending = false
    @Published private(set) var notificationAuthorization: AppNotificationAuthorization = .checking
    @Published private(set) var notificationTestPending = false
    @Published private(set) var notificationTestMessage: String?
    @Published private(set) var menuBarGlassStatus: MenuBarGlassStatus = .off
    @Published private(set) var scrollingStatus: ScrollingStatus = .off
    @Published private(set) var activityMonitorShortcutStatus: ActivityMonitorShortcutStatus = .off
    @Published private(set) var closedLidBehaviorStatus: ClosedLidBehaviorStatus = .followingSystem
    @Published private(set) var closedLidShutdownHelperStatus: ClosedLidShutdownHelperStatus = .missing
    @Published private(set) var clipboardSharingStatus: ClipboardSharingStatus = .off
    @Published private(set) var microphoneSharingStatus: MicrophoneSharingStatus = .off
    @Published private(set) var crossScreenMouseStatus: CrossScreenMouseStatus = .off
    @Published private(set) var softKVMStatus: SoftKVMStatus = .disabled
    @Published var finderShortcutsEnabled: Bool
    @Published var goToParentEnabled: Bool
    @Published var openSelectionEnabled: Bool
    @Published var renameEnabled: Bool
    @Published var cutAndMoveEnabled: Bool
    @Published var moveToTrashEnabled: Bool
    @Published var menuBarGlassEnabled: Bool
    @Published var scrollingEnabled: Bool
    @Published var activityMonitorShortcutEnabled: Bool
    @Published var closedLidMode: ClosedLidMode = .keepRunning
    @Published var clipboardSharingEnabled: Bool
    @Published var microphoneSharingEnabled: Bool
    @Published private(set) var microphoneActivationKey: MicrophoneActivationKey
    @Published var crossScreenMouseEnabled: Bool
    @Published private(set) var displayHandoffEnabled: Bool
    @Published private(set) var displayHandoffAlignment: DisplayHandoffAlignment
    @Published private(set) var softKVMShortcut: SoftKVMShortcut
    @Published private(set) var softKVMShortcutTestMessage: String?
    private var softKVMStarted = false
    private var lastSoftKVMShortcutAt: ContinuousClock.Instant?
    private var finderAutomationPermissionTask: Task<Void, Never>?
    private var finderAutomationPermissionGeneration: UInt64 = 0
    @Published private(set) var terminalApplications: [TerminalApplication] = []
    @Published var finderContextMenuEnabled: Bool
    @Published var selectedTerminalBundleIdentifier: String
    @Published private(set) var markdownPreviewDefaultWidth = Int(
        MarkdownPreviewWindowPreferences.recommendedSize.width
    )
    @Published private(set) var markdownPreviewDefaultHeight = Int(
        MarkdownPreviewWindowPreferences.recommendedSize.height
    )

    private lazy var finderShortcuts = FinderShortcutsController(
        onStatusChanged: { [weak self] status in
            self?.finderShortcutsStatus = status
        },
        onCutStateChanged: { [weak self] hasCutState in
            self?.hasCutState = hasCutState
        },
        onFeedbackEvent: { [weak self] event in
            guard let self, notificationsEnabled else { return }
            finderFeedback.show(event)
        }
    )

    private lazy var menuBarGlass = MenuBarGlassController { [weak self] in self?.menuBarGlassStatus = $0 }

    private lazy var scrolling = ScrollingController { [weak self] in self?.scrollingStatus = $0 }

    private lazy var activityMonitorShortcut = ActivityMonitorShortcutController(
        onStatusChanged: { [weak self] status in
            self?.activityMonitorShortcutStatus = status
        }
    )

    private lazy var softKVMHotKey = SoftKVMHotKeyController { [weak self] in self?.handleSoftKVMShortcut() }

    private lazy var softKVMShortcutTest: SoftKVMShortcutTestController = {
        let controller = SoftKVMShortcutTestController()
        controller.onMessageChanged = { [weak self] message in
            self?.softKVMShortcutTestMessage = message
        }
        return controller
    }()

    private lazy var closedLidShutdown: ClosedLidShutdownCoordinator = {
        let coordinator = ClosedLidShutdownCoordinator(defaults: defaults)
        coordinator.onModeChanged = { [weak self] mode in
            self?.closedLidMode = mode
        }
        coordinator.onModeApplied = { [weak self] mode in
            self?.closedLidBehavior.setMode(mode)
        }
        coordinator.onHelperStatusChanged = { [weak self] status in
            self?.closedLidShutdownHelperStatus = status
        }
        coordinator.onFailure = { [weak self] message in
            self?.closedLidBehaviorStatus = .failed(message)
        }
        return coordinator
    }()

    private lazy var closedLidBehavior = ClosedLidBehaviorController(
        shutdownHelperIsReady: { [weak self] in
            self?.closedLidShutdownHelperStatus.isReady == true
        },
        onStatusChanged: { [weak self] status in
            self?.closedLidBehaviorStatus = status
        }
    )

    private lazy var crossScreenMouse = CrossScreenMouseController(
        sharedDisplayID: FixedDisplayConfiguration.philipsUUID,
        onStatusChanged: { [weak self] status in self?.setCrossScreenMouseStatus(status) },
        onSoftKVMToggle: { [weak self] in
            self?.handleSoftKVMShortcut()
        },
        onMicrophoneActivationChanged: { [weak self] active in
            self?.setMicrophoneActivationHeld(active)
        }
    )

    private lazy var windowsCompanion = WindowsCompanionController(
        crossScreenMouse: crossScreenMouse,
        onClipboardStatusChanged: { [weak self] status in
            self?.clipboardSharingStatus = status
        },
        onMicrophoneStatusChanged: { [weak self] status in
            self?.microphoneSharingStatus = status
        },
        onMouseReadinessChanged: { [weak self] in self?.setWindowsMouseReadiness($0) },
        onWindowsOnline: { [weak self] in self?.notifications.sendWindowsOnline() }
    )

    private lazy var softKVM = SoftKVMCoordinator(
        displaySwitch: makeFullSwitchController(),
        crossScreenMouse: crossScreenMouse,
        setMouseServiceEnabled: { [weak self] enabled in
            self?.applyMouseServiceEnabled(enabled)
        },
        onStatusChanged: { [weak self] status in
            self?.softKVMStatus = status
        },
        onEnabledStateChanged: { [weak self] enabled in
            self?.applySoftKVMEnabledState(enabled)
        }
    )

    private func setCrossScreenMouseStatus(_ status: CrossScreenMouseStatus) {
        guard status != crossScreenMouseStatus else { return }
        crossScreenMouseStatus = status
        if softKVMStarted { softKVM.updateMouseStatus(status) }
    }

    private func setWindowsMouseReadiness(_ readiness: WindowsMouseReadiness?) {
        guard softKVMStarted else { return }
        softKVM.updateReadiness(readiness)
    }

    private func applyMouseServiceEnabled(_ enabled: Bool) { windowsCompanion.setMouseServiceEnabled(enabled) }

    private func setMicrophoneActivationHeld(_ held: Bool) { windowsCompanion.setMicrophoneActivationHeld(held) }

    init() {
        finderShortcutsEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.finderShortcutsEnabled,
            default: true
        )
        goToParentEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.finderGoToParentEnabled,
            default: true
        )
        openSelectionEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.finderOpenSelectionEnabled,
            default: true
        )
        renameEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.finderRenameEnabled,
            default: true
        )
        cutAndMoveEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.finderCutAndMoveEnabled,
            default: true
        )
        moveToTrashEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.finderMoveToTrashEnabled,
            default: true
        )
        menuBarGlassEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.menuBarGlassEnabled,
            default: true
        )
        scrollingEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.scrollingEnabled,
            default: true
        )
        activityMonitorShortcutEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.activityMonitorShortcutEnabled,
            default: true
        )
        clipboardSharingEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.clipboardSharingEnabled,
            default: true
        )
        microphoneSharingEnabled = defaults.bool(forKey: AppPreferenceKey.microphoneSharingEnabled)
        if let data = defaults.data(forKey: AppPreferenceKey.microphoneActivationKey),
           let savedKey = try? JSONDecoder().decode(MicrophoneActivationKey.self, from: data),
           savedKey.isValid {
            microphoneActivationKey = savedKey
        } else {
            microphoneActivationKey = .defaultValue
        }
        crossScreenMouseEnabled = defaults.bool(forKey: AppPreferenceKey.crossScreenMouseEnabled)
        displayHandoffEnabled = defaults.boolValue(
            forKey: AppPreferenceKey.displayHandoffEnabled,
            default: true
        )
        if let rawAlignment = defaults.string(forKey: AppPreferenceKey.displayHandoffAlignment),
           let savedAlignment = DisplayHandoffAlignment(rawValue: rawAlignment) {
            displayHandoffAlignment = savedAlignment
        } else {
            displayHandoffAlignment = .bottom
            defaults.set(
                DisplayHandoffAlignment.bottom.rawValue,
                forKey: AppPreferenceKey.displayHandoffAlignment
            )
        }
        if let data = defaults.data(forKey: AppPreferenceKey.softKVMShortcut),
           let savedShortcut = try? JSONDecoder().decode(SoftKVMShortcut.self, from: data),
           savedShortcut.isValid {
            let resolvedShortcut = SoftKVMShortcut.replacingSupersededDefault(savedShortcut)
            softKVMShortcut = resolvedShortcut
            if resolvedShortcut != savedShortcut,
               let updatedData = try? JSONEncoder().encode(resolvedShortcut) {
                defaults.set(updatedData, forKey: AppPreferenceKey.softKVMShortcut)
            }
        } else {
            softKVMShortcut = .defaultValue
        }
        softKVMShortcutTestMessage = nil
        finderContextMenuEnabled = finderContextMenuPreferences.isEnabled
        selectedTerminalBundleIdentifier = finderContextMenuPreferences.terminalBundleIdentifier
        notificationsEnabled = notifications.isEnabled
        pasteSoundEnabled = finderFeedback.pasteSoundEnabled
        let markdownPreviewSize = markdownPreviewWindowPreferences.defaultSize
        markdownPreviewDefaultWidth = Int(markdownPreviewSize.width)
        markdownPreviewDefaultHeight = Int(markdownPreviewSize.height)
        closedLidMode = closedLidShutdown.mode
        closedLidShutdownHelperStatus = closedLidShutdown.helperStatus
        softKVMHotKey.onKeyboardFallbackNeededChanged = { [weak self] in self?.crossScreenMouse.setLocalKeyboardCaptureRequired($0) }
        closedLidShutdown.synchronizeConfiguration()
        windowsAgent.start()
        refreshPermissionsAndRuntime()
    }

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

    func refreshPermissionsAndRuntime() {
        accessibilityGranted = AccessibilityPermission.canReadAccessibility
        postEventGranted = AccessibilityPermission.canPostEvents
        inputMonitoringGranted = AccessibilityPermission.canListenToKeyboard
        refreshFinderAutomationPermission()
        refreshNotificationAuthorization()
        finderShortcuts.setEnabledFeatures(enabledShortcutFeatures)
        finderShortcuts.setEnabled(finderShortcutsEnabled)
        menuBarGlass.setEnabled(menuBarGlassEnabled)
        scrolling.setEnabled(scrollingEnabled)
        activityMonitorShortcut.setEnabled(activityMonitorShortcutEnabled)
        softKVMHotKey.setShortcut(softKVMShortcut)
        closedLidShutdown.refreshHelperStatus()
        closedLidBehavior.setMode(closedLidMode)
        applyDisplayHandoffConfiguration()
        crossScreenMouse.setMicrophoneActivationKey(microphoneActivationKey)
        windowsCompanion.setMicrophoneEnabled(microphoneSharingEnabled)
        windowsCompanion.setClipboardEnabled(clipboardSharingEnabled)
        if !softKVMStarted {
            softKVMStarted = true
            softKVM.start(enabled: crossScreenMouseEnabled, shortcut: softKVMShortcut)
        }
    }
    func stopForApplicationExit() {
        cancelSoftKVMShortcutTest()
        finderFeedback.stop()
        finderAutomationPermissionGeneration &+= 1
        finderAutomationPermissionTask?.cancel()
        finderAutomationPermissionTask = nil
        finderShortcuts.stopForApplicationExit()
        menuBarGlass.stopForApplicationExit()
        scrolling.stopForApplicationExit()
        activityMonitorShortcut.stopForApplicationExit()
        softKVMHotKey.stopForApplicationExit()
        closedLidBehavior.stopForApplicationExit()
        softKVM.stopForApplicationExit()
        windowsCompanion.stopForApplicationExit()
        windowsAgent.stopForApplicationExit()
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

    private func refreshFinderAutomationPermission(askUserIfNeeded: Bool = false) {
        finderAutomationPermissionGeneration &+= 1
        let generation = finderAutomationPermissionGeneration
        finderAutomationPermissionTask?.cancel()
        finderAutomationPermissionStatus = .checking
        finderAutomationPermissionTask = Task { [weak self] in
            let status = await FinderAutomationPermission.determine(askUserIfNeeded: askUserIfNeeded)
            guard let self,
                  !Task.isCancelled,
                  finderAutomationPermissionGeneration == generation else { return }
            finderAutomationPermissionStatus = status
            finderAutomationPermissionTask = nil
        }
    }

    private var enabledShortcutFeatures: FinderShortcutFeatures {
        var features: FinderShortcutFeatures = []
        if goToParentEnabled { features.insert(.goToParent) }
        if openSelectionEnabled { features.insert(.openSelection) }
        if renameEnabled { features.insert(.rename) }
        if cutAndMoveEnabled { features.insert(.cutAndMove) }
        if moveToTrashEnabled { features.insert(.moveToTrash) }
        return features
    }
}

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

    private func handleSoftKVMShortcut() {
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
    private func applySoftKVMEnabledState(_ enabled: Bool) {
        if !enabled {
            cancelSoftKVMShortcutTest()
        }
        crossScreenMouseEnabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.crossScreenMouseEnabled)
        softKVMHotKey.setEnabled(enabled)
    }

    private func cancelSoftKVMShortcutTest() {
        softKVMShortcutTest.cancel()
        lastSoftKVMShortcutAt = nil
    }

    private func applyDisplayHandoffConfiguration() {
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
