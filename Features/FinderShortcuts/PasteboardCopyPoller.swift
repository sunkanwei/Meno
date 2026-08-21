import AppKit

@MainActor
enum PasteboardCopyPoller {
    static let confirmationTimeout: TimeInterval = 1.5
    static let pollInterval: TimeInterval = 0.04

    struct ConfirmedChange {
        let changeCount: Int
        let fileURLs: [URL]
    }

    enum Failure: String, Equatable {
        case confirmationTimedOut
        case contextInvalidated
    }

    enum Result {
        case confirmed(ConfirmedChange)
        case failed(Failure)
    }

    static func poll(
        pasteboard: NSPasteboard = .general,
        baselineChangeCount: Int,
        deadline: Date,
        pollInterval: TimeInterval = PasteboardCopyPoller.pollInterval,
        isCurrent: @escaping () -> Bool,
        contextIsValid: @escaping () -> Bool,
        onResult: @escaping (Result) -> Void
    ) {
        guard isCurrent() else { return }
        guard Date() <= deadline else {
            onResult(.failed(.confirmationTimedOut))
            return
        }
        guard contextIsValid() else {
            onResult(.failed(.contextInvalidated))
            return
        }

        let countBeforeRead = pasteboard.changeCount
        if countBeforeRead == baselineChangeCount {
            retry(
                pasteboard: pasteboard,
                baselineChangeCount: baselineChangeCount,
                deadline: deadline,
                pollInterval: pollInterval,
                isCurrent: isCurrent,
                contextIsValid: contextIsValid,
                onResult: onResult
            )
            return
        }

        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.compactMap { ($0 as? NSURL).map { $0 as URL } } ?? []
        guard pasteboard.changeCount == countBeforeRead, !fileURLs.isEmpty else {
            retry(
                pasteboard: pasteboard,
                baselineChangeCount: baselineChangeCount,
                deadline: deadline,
                pollInterval: pollInterval,
                isCurrent: isCurrent,
                contextIsValid: contextIsValid,
                onResult: onResult
            )
            return
        }
        onResult(.confirmed(ConfirmedChange(
            changeCount: pasteboard.changeCount,
            fileURLs: fileURLs
        )))
    }

    private static func retry(
        pasteboard: NSPasteboard,
        baselineChangeCount: Int,
        deadline: Date,
        pollInterval: TimeInterval,
        isCurrent: @escaping () -> Bool,
        contextIsValid: @escaping () -> Bool,
        onResult: @escaping (Result) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
            poll(
                pasteboard: pasteboard,
                baselineChangeCount: baselineChangeCount,
                deadline: deadline,
                pollInterval: pollInterval,
                isCurrent: isCurrent,
                contextIsValid: contextIsValid,
                onResult: onResult
            )
        }
    }
}
