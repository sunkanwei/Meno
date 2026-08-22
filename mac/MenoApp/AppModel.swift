import AppKit
import Combine
import FinderSync

@MainActor
final class AppModel: ObservableObject {
    let defaults = UserDefaults.standard
    let finderContextMenuPreferences = FinderContextMenuPreferences()
    let markdownPreviewWindowPreferences = MarkdownPreviewWindowPreferences()
    let notifications = AppNotifications()
    let finderFeedback = FinderFeedbackPresenter()
    let windowsAgent = WindowsAgentController()

    @Published private(set) var finderShortcutsStatus: FinderShortcutsStatus = .off
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var postEventGranted = false
    @Published private(set) var inputMonitoringGranted = false
    @Published private(set) var finderAutomationPermissionStatus:
        FinderAutomationPermissionStatus = .checking
    @Published private(set) var hasCutState = false
    @Published var notificationsEnabled = false
    @Published var pasteSoundEnabled = true
    @Published var notificationPermissionPending = false
    @Published var notificationAuthorization: AppNotificationAuthorization = .checking
    @Published var notificationTestPending = false
    @Published var notificationTestMessage: String?
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
    @Published var microphoneActivationKey: MicrophoneActivationKey
    @Published var crossScreenMouseEnabled: Bool
    @Published var displayHandoffEnabled: Bool
    @Published var displayHandoffAlignment: DisplayHandoffAlignment
    @Published var softKVMShortcut: SoftKVMShortcut
    @Published var softKVMShortcutTestMessage: String?
    private var softKVMStarted = false
    var lastSoftKVMShortcutAt: ContinuousClock.Instant?
    private var finderAutomationPermissionTask: Task<Void, Never>?
    private var finderAutomationPermissionGeneration: UInt64 = 0
    @Published var terminalApplications: [TerminalApplication] = []
    @Published var finderContextMenuEnabled: Bool
    @Published var selectedTerminalBundleIdentifier: String
    @Published var markdownPreviewDefaultWidth = Int(
        MarkdownPreviewWindowPreferences.recommendedSize.width
    )
    @Published var markdownPreviewDefaultHeight = Int(
        MarkdownPreviewWindowPreferences.recommendedSize.height
    )

    lazy var finderShortcuts = FinderShortcutsController(
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

    lazy var menuBarGlass = MenuBarGlassController { [weak self] in self?.menuBarGlassStatus = $0 }

    lazy var scrolling = ScrollingController { [weak self] in self?.scrollingStatus = $0 }

    lazy var activityMonitorShortcut = ActivityMonitorShortcutController(
        onStatusChanged: { [weak self] status in
            self?.activityMonitorShortcutStatus = status
        }
    )

    lazy var softKVMHotKey = SoftKVMHotKeyController { [weak self] in self?.handleSoftKVMShortcut() }

    lazy var softKVMShortcutTest: SoftKVMShortcutTestController = {
        let controller = SoftKVMShortcutTestController()
        controller.onMessageChanged = { [weak self] message in
            self?.softKVMShortcutTestMessage = message
        }
        return controller
    }()

    lazy var closedLidShutdown: ClosedLidShutdownCoordinator = {
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

    lazy var crossScreenMouse = CrossScreenMouseController(
        sharedDisplayID: FixedDisplayConfiguration.philipsUUID,
        onStatusChanged: { [weak self] status in self?.setCrossScreenMouseStatus(status) },
        onSoftKVMToggle: { [weak self] in
            self?.handleSoftKVMShortcut()
        },
        onMicrophoneActivationChanged: { [weak self] active in
            self?.setMicrophoneActivationHeld(active)
        }
    )

    lazy var windowsCompanion = WindowsCompanionController(
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

    lazy var softKVM = SoftKVMCoordinator(
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

    func refreshFinderAutomationPermission(askUserIfNeeded: Bool = false) {
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

    var enabledShortcutFeatures: FinderShortcutFeatures {
        var features: FinderShortcutFeatures = []
        if goToParentEnabled { features.insert(.goToParent) }
        if openSelectionEnabled { features.insert(.openSelection) }
        if renameEnabled { features.insert(.rename) }
        if cutAndMoveEnabled { features.insert(.cutAndMove) }
        if moveToTrashEnabled { features.insert(.moveToTrash) }
        return features
    }
}
