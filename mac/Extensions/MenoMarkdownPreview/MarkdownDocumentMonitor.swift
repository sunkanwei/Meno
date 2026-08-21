import Darwin
import Foundation

@MainActor
final class MarkdownDocumentMonitor {
    typealias ChangeHandler = @MainActor () -> Void

    private static let eventMask: DispatchSource.FileSystemEvent = [
        .write,
        .extend,
        .attrib,
        .link,
        .rename,
        .delete,
        .revoke,
    ]

    private let fileURL: URL
    private let debounceDuration: Duration
    private let retryDuration: Duration
    private let changeHandler: ChangeHandler
    private var source: DispatchSourceFileSystemObject?
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false

    init(
        fileURL: URL,
        debounceDuration: Duration = .milliseconds(150),
        retryDuration: Duration = .milliseconds(500),
        changeHandler: @escaping ChangeHandler
    ) {
        self.fileURL = fileURL
        self.debounceDuration = debounceDuration
        self.retryDuration = retryDuration
        self.changeHandler = changeHandler
    }

    @discardableResult
    func start() -> Bool {
        isRunning = true
        return installSource()
    }

    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        source?.cancel()
        source = nil
    }

    private func installSource() -> Bool {
        source?.cancel()
        source = nil

        let descriptor = open(fileURL.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.eventMask,
            queue: .main
        )
        newSource.setEventHandler { [weak self] in
            self?.scheduleRefresh()
        }
        newSource.setCancelHandler {
            close(descriptor)
        }
        source = newSource
        newSource.resume()
        return true
    }

    private func scheduleRefresh() {
        guard isRunning else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounceDuration)
            guard !Task.isCancelled else { return }
            await reopenAndNotify()
        }
    }

    private func reopenAndNotify() async {
        source?.cancel()
        source = nil

        while true {
            guard isRunning, !Task.isCancelled else { return }
            if installSource() {
                changeHandler()
                return
            }
            try? await Task.sleep(for: retryDuration)
        }
    }
}
