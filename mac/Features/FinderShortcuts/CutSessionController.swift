import AppKit
import OSLog

enum FinderFeedbackEvent {
    case copied
    case cutArmed
    case pasteSubmitted
}

@MainActor
final class CutSessionController {
    private static let healthCheckInterval: TimeInterval = 1

    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "FinderShortcuts"
    )

    private let contextInspector: FinderContextInspector
    private let onStateChanged: (_ hasCutState: Bool) -> Void
    private let onFeedbackEvent: (FinderFeedbackEvent) -> Void

    private var stateMachine = CutStateMachine()
    private var healthTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        contextInspector: FinderContextInspector,
        onStateChanged: @escaping (_ hasCutState: Bool) -> Void,
        onFeedbackEvent: @escaping (FinderFeedbackEvent) -> Void
    ) {
        self.contextInspector = contextInspector
        self.onStateChanged = onStateChanged
        self.onFeedbackEvent = onFeedbackEvent
        observeInvalidatingSystemEvents()
    }

    var hasArmedCut: Bool {
        stateMachine.hasArmedSession
    }

    var isAwaitingCopy: Bool {
        if case .awaitingCopy = stateMachine.phase { return true }
        return false
    }

    func beginCut(using context: FinderContextSnapshot) {
        guard !context.selectedItemURLs.isEmpty,
              contextInspector.isFrontmostFinder(pid: context.finderPID),
              context.selectedItemURLs.allExist() else {
            cancel()
            return
        }

        cancel()
        let pasteboard = NSPasteboard.general
        guard let attempt = stateMachine.beginCopy(
            finderPID: context.finderPID,
            baselinePasteboardChangeCount: pasteboard.changeCount,
            sourceURLs: context.selectedItemURLs,
            now: Date()
        ) else {
            return
        }

        guard FinderCommandSender.postCopy(to: context.finderPID) else {
            logger.error("Cut skipped: Finder copy event could not be posted")
            stateMachine.cancel()
            return
        }
        pollForCopyConfirmation(attempt: attempt)
    }

    func cancelPendingCopy() {
        guard isAwaitingCopy else { return }
        stateMachine.cancel()
    }

    @discardableResult
    func consumeForMove(finderPID: Int32) -> Bool {
        guard case let .armed(session) = stateMachine.phase else {
            cancel()
            return false
        }

        let now = Date()
        let immediateHealth = CutHealthSnapshot(
            finderPID: FinderProcess.currentPID,
            pasteboardChangeCount: NSPasteboard.general.changeCount,
            sourcesExist: session.sourceURLs.allExist(),
            checkedAt: now
        )
        guard immediateHealth.finderPID == finderPID,
              stateMachine.consumeForMove(health: immediateHealth, now: now) != nil else {
            finishInvalidation()
            return false
        }

        stopHealthMonitoring()
        onStateChanged(false)
        DispatchQueue.main.async { [onFeedbackEvent] in
            onFeedbackEvent(.pasteSubmitted)
        }
        return true
    }

    func cancel() {
        let wasArmed = stateMachine.hasArmedSession
        stateMachine.cancel()
        stopHealthMonitoring()
        if wasArmed {
            onStateChanged(false)
        }
    }

    private func pollForCopyConfirmation(attempt: CutAttempt) {
        PasteboardCopyPoller.poll(
            baselineChangeCount: attempt.baselinePasteboardChangeCount,
            deadline: attempt.confirmationDeadline,
            isCurrent: { [weak self] in
                guard let self,
                      case let .awaitingCopy(currentAttempt) = self.stateMachine.phase else {
                    return false
                }
                return currentAttempt.token == attempt.token
            },
            contextIsValid: {
                FinderProcess.currentPID == attempt.finderPID
            },
            onResult: { [weak self] result in
                guard let self else { return }
                guard case let .confirmed(change) = result else {
                    self.stateMachine.cancel()
                    return
                }
                let now = Date()
                guard self.stateMachine.confirmCopy(
                    token: attempt.token,
                    finderPID: attempt.finderPID,
                    pasteboardChangeCount: change.changeCount,
                    copiedURLs: change.fileURLs,
                    sourcesExist: attempt.sourceURLs.allExist(),
                    now: now
                ) else {
                    return
                }

                self.startHealthMonitoring()
                self.onStateChanged(true)
                self.onFeedbackEvent(.cutArmed)
            }
        )
    }

    private func startHealthMonitoring() {
        stopHealthMonitoring()
        let timer = Timer(timeInterval: Self.healthCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHealth() }
        }
        timer.tolerance = 0.2
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHealthMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func refreshHealth() {
        guard case let .armed(session) = stateMachine.phase else {
            stopHealthMonitoring()
            return
        }

        let now = Date()
        let health = CutHealthSnapshot(
            finderPID: FinderProcess.currentPID,
            pasteboardChangeCount: NSPasteboard.general.changeCount,
            sourcesExist: session.sourceURLs.allExist(),
            checkedAt: now
        )
        if stateMachine.invalidateIfNeeded(health: health, now: now) {
            finishInvalidation()
        }
    }

    private func finishInvalidation() {
        stateMachine.cancel()
        stopHealthMonitoring()
        onStateChanged(false)
    }

    private func observeInvalidatingSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      application.bundleIdentifier == FinderProcess.bundleIdentifier else {
                    return
                }
                Task { @MainActor in self?.cancel() }
            }
        )
        workspaceObservers.append(
            center.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.cancel() }
            }
        )
    }
}
