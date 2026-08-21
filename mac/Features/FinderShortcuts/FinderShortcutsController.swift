import AppKit
import CoreGraphics

enum FinderShortcutsStatus: Equatable {
    case off
    case waitingForPermissions
    case running
    case failed(String)

    var title: String {
        switch self {
        case .off:
            return "已关闭"
        case .waitingForPermissions:
            return "等待权限"
        case .running:
            return "运行中"
        case .failed:
            return "异常，已放行系统行为"
        }
    }
}

@MainActor
final class FinderShortcutsController {
    private struct PendingCopyObservation {
        let token: UInt64
        let finderPID: Int32
        let scope: FinderContextScope
        let baselinePasteboardChangeCount: Int
        let selectedURLs: [URL]
        let deadline: Date
    }

    private enum HeldReplacement {
        case key(keyCode: CGKeyCode, flags: CGEventFlags)
        case swallow

        func apply(to event: CGEvent) -> CGEvent? {
            switch self {
            case let .key(keyCode, flags):
                return FinderCommandSender.replace(event, keyCode: keyCode, flags: flags)
            case .swallow:
                return nil
            }
        }
    }

    private let contextInspector = FinderContextInspector()
    private let onStatusChanged: (FinderShortcutsStatus) -> Void
    private let onCutStateChanged: (_ hasCutState: Bool) -> Void
    private let onFeedbackEvent: (FinderFeedbackEvent) -> Void

    private var enabled = false
    private var enabledFeatures: FinderShortcutFeatures = .all
    private var heldReplacements: [Int64: HeldReplacement] = [:]
    private var pendingCopyObservation: PendingCopyObservation?
    private var nextCopyObservationToken: UInt64 = 0
    private var workspaceObservers: [NSObjectProtocol] = []

    private lazy var cutSession = CutSessionController(
        contextInspector: contextInspector,
        onStateChanged: onCutStateChanged,
        onFeedbackEvent: onFeedbackEvent
    )

    private lazy var eventTap = KeyboardEventTap(
        eventHandler: { [weak self] type, event in
            self?.handle(type: type, event: event) ?? event
        },
        disabledHandler: { [weak self] recovered in
            self?.eventTapWasDisabled(recovered: recovered)
        }
    )

    init(
        onStatusChanged: @escaping (FinderShortcutsStatus) -> Void,
        onCutStateChanged: @escaping (_ hasCutState: Bool) -> Void,
        onFeedbackEvent: @escaping (FinderFeedbackEvent) -> Void
    ) {
        self.onStatusChanged = onStatusChanged
        self.onCutStateChanged = onCutStateChanged
        self.onFeedbackEvent = onFeedbackEvent
        observeFinderLifecycle()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refresh()
    }

    func setEnabledFeatures(_ features: FinderShortcutFeatures) {
        let cutWasEnabled = enabledFeatures.contains(.cutAndMove)
        enabledFeatures = features
        if cutWasEnabled, !features.contains(.cutAndMove) {
            cutSession.cancel()
            pendingCopyObservation = nil
        }
    }

    func refresh() {
        guard enabled else {
            resetRuntimeState()
            onStatusChanged(.off)
            return
        }

        guard FinderShortcutsCompatibility.supports(
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ) else {
            resetRuntimeState()
            onStatusChanged(.failed("当前 macOS 大版本尚未验证"))
            return
        }

        let accessibilityMissing = !AccessibilityPermission.canReadAndPostEvents
        let inputMonitoringMissing = !AccessibilityPermission.canListenToKeyboard
        guard !accessibilityMissing, !inputMonitoringMissing else {
            resetRuntimeState()
            onStatusChanged(.waitingForPermissions)
            return
        }

        guard let finderPID = FinderProcess.currentPID else {
            resetRuntimeState()
            onStatusChanged(.failed("Finder 当前未运行"))
            return
        }

        if eventTap.isRunning {
            onStatusChanged(.running)
            return
        }

        if eventTap.start(for: finderPID) {
            onStatusChanged(.running)
        } else {
            resetRuntimeState()
            onStatusChanged(.failed("无法建立 Finder 键盘监听"))
        }
    }

    func stopForApplicationExit() { resetRuntimeState() }

    private func resetRuntimeState() {
        eventTap.stop()
        cutSession.cancel()
        heldReplacements.removeAll()
        pendingCopyObservation = nil
    }
}

private extension FinderShortcutsController {
    func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if event.getIntegerValueField(.eventSourceUserData) == FinderCommandSender.generatedEventMarker {
            return event
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event: event, keyCode: keyCode)
        case .keyUp:
            return handleKeyUp(event: event, keyCode: keyCode)
        default:
            return event
        }
    }

    private func handleKeyDown(event: CGEvent, keyCode: Int64) -> CGEvent? {
        if heldReplacements[keyCode] != nil {
            return nil
        }

        let modifiers = ShortcutModifiers(eventFlags: event.flags)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let isFunctionModified = event.flags.contains(.maskSecondaryFn)
        let isMappedPaste = KeyboardShortcut.isFilePaste(
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat
        )
        if KeyboardShortcut.isFileCopy(
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat
        ) {
            cutSession.cancel()
            observeFileCopy()
            return event
        }

        if isMappedPaste, cutSession.isAwaitingCopy {
            cutSession.cancelPendingCopy()
            emitPasteFeedbackIfFileAvailable()
            return event
        }

        guard let intent = KeyboardShortcut.intent(
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat,
            isFunctionModified: isFunctionModified,
            hasCutState: cutSession.hasArmedCut,
            enabledFeatures: enabledFeatures
        ) else {
            if isMappedPaste {
                emitPasteFeedbackIfFileAvailable()
            }
            return event
        }
        guard let finderPID = FinderProcess.currentPID,
              let context = contextInspector.currentContext(expectedPID: finderPID) else {
            if intent == .movePaste {
                emitPasteFeedbackIfFileAvailable()
            }
            return event
        }
        if context.scope == .desktop, !intent.isSupportedOnDesktop {
            return event
        }

        return perform(intent, context: context, event: event, originalKeyCode: keyCode)
    }

    private func perform(
        _ intent: FinderShortcutIntent,
        context: FinderContextSnapshot,
        event: CGEvent,
        originalKeyCode: Int64
    ) -> CGEvent? {
        switch intent {
        case .goToParent, .openSelection, .rename, .moveToTrash:
            guard let replacement = nativeReplacement(for: intent, context: context) else {
                return event
            }
            return holdReplacement(
                replacement,
                for: event,
                originalKeyCode: originalKeyCode
            )

        case .beginCut:
            guard !context.selectedItemURLs.isEmpty else { return event }
            DispatchQueue.main.async { [weak self] in
                self?.cutSession.beginCut(using: context)
            }
            return event

        case .movePaste:
            guard cutSession.consumeForMove(finderPID: context.finderPID) else {
                return event
            }
            return holdReplacement(
                .key(keyCode: 0x09, flags: [.maskCommand, .maskAlternate]),
                for: event,
                originalKeyCode: originalKeyCode
            )

        case .cancelCut:
            cutSession.cancel()
            return holdReplacement(.swallow, for: event, originalKeyCode: originalKeyCode)

        }
    }

    private func nativeReplacement(
        for intent: FinderShortcutIntent,
        context: FinderContextSnapshot
    ) -> HeldReplacement? {
        switch intent {
        case .goToParent:
            return .key(keyCode: 0x7E, flags: [.maskCommand])
        case .openSelection:
            guard context.selectedItemURLs.count == 1 else { return nil }
            return .key(keyCode: 0x1F, flags: [.maskCommand])
        case .rename:
            guard context.selectedItemURLs.count == 1 else { return nil }
            return .key(keyCode: 0x24, flags: [])
        case .moveToTrash:
            guard KeyboardShortcut.canMoveSelectionToTrash(context.selectedItemURLs) else {
                return nil
            }
            return .key(keyCode: 0x33, flags: [.maskCommand])
        case .beginCut, .movePaste, .cancelCut:
            return nil
        }
    }

    func observeFileCopy() {
        guard let finderPID = FinderProcess.currentPID else {
            return
        }
        guard let context = contextInspector.currentContext(expectedPID: finderPID) else {
            return
        }
        guard !context.selectedItemURLs.isEmpty else {
            return
        }
        beginCopyObservation(using: context)
    }

    func emitPasteFeedbackIfFileAvailable() {
        guard let finderPID = FinderProcess.currentPID,
              contextInspector.currentContext(expectedPID: finderPID) != nil else {
            return
        }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        guard NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: options
        ) else {
            return
        }
        onFeedbackEvent(.pasteSubmitted)
    }

    private func holdReplacement(
        _ replacement: HeldReplacement,
        for event: CGEvent,
        originalKeyCode: Int64
    ) -> CGEvent? {
        heldReplacements[originalKeyCode] = replacement
        return replacement.apply(to: event)
    }

    private func handleKeyUp(event: CGEvent, keyCode: Int64) -> CGEvent? {
        guard let replacement = heldReplacements.removeValue(forKey: keyCode) else {
            return event
        }
        return replacement.apply(to: event)
    }

    private func eventTapWasDisabled(recovered: Bool) {
        cutSession.cancel()
        heldReplacements.removeAll()
        pendingCopyObservation = nil
        if recovered {
            onStatusChanged(.running)
        } else {
            onStatusChanged(.failed("键盘监听已失效"))
        }
    }

    private func observeFinderLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ] {
            workspaceObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                          application.bundleIdentifier == FinderProcess.bundleIdentifier else {
                        return
                    }
                    Task { @MainActor in
                        self?.resetRuntimeState()
                        self?.refresh()
                    }
                }
            )
        }
    }

    private func beginCopyObservation(using context: FinderContextSnapshot) {
        nextCopyObservationToken &+= 1
        let observation = PendingCopyObservation(
            token: nextCopyObservationToken,
            finderPID: context.finderPID,
            scope: context.scope,
            baselinePasteboardChangeCount: NSPasteboard.general.changeCount,
            selectedURLs: context.selectedItemURLs.normalizedFileURLs(),
            deadline: Date().addingTimeInterval(PasteboardCopyPoller.confirmationTimeout)
        )
        pendingCopyObservation = observation
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteboardCopyPoller.pollInterval) { [weak self] in
            self?.pollForCopyConfirmation(observation)
        }
    }

    private func pollForCopyConfirmation(_ observation: PendingCopyObservation) {
        PasteboardCopyPoller.poll(
            baselineChangeCount: observation.baselinePasteboardChangeCount,
            deadline: observation.deadline,
            isCurrent: { [weak self] in
                self?.pendingCopyObservation?.token == observation.token
            },
            contextIsValid: {
                FinderProcess.currentPID == observation.finderPID
            },
            onResult: { [weak self] result in
                guard let self else { return }
                self.pendingCopyObservation = nil
                guard case let .confirmed(change) = result else {
                    return
                }
                let copiedURLs = change.fileURLs.normalizedFileURLs()
                guard copiedURLs == observation.selectedURLs else {
                    return
                }
                guard observation.selectedURLs.allExist() else {
                    return
                }
                self.onFeedbackEvent(.copied)
            }
        )
    }
}
