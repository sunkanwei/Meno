import AppKit

enum SharedClipboardContent: Sendable {
    case text(Data)
    case png(Data)
    case files([URL])
}

@MainActor
final class ClipboardMonitor {
    private static let pollingInterval: TimeInterval = 1
    private static let pollingTolerance: TimeInterval = 0.1

    private let pasteboard: NSPasteboard
    private let onLocalChange: (SharedClipboardContent) -> Void
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?

    init(
        pasteboard: NSPasteboard = .general,
        onLocalChange: @escaping (SharedClipboardContent) -> Void
    ) {
        self.pasteboard = pasteboard
        self.onLocalChange = onLocalChange
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        timer.tolerance = Self.pollingTolerance
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func writeRemote(_ content: SharedClipboardContent) {
        let wrote: Bool
        switch content {
        case let .text(data):
            guard let text = String(data: data, encoding: .utf8) else { return }
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string) else { return }
            pasteboard.clearContents()
            wrote = pasteboard.writeObjects([item])
        case let .png(data):
            wrote = ClipboardImageCodec.write(png: data, to: pasteboard)
        case let .files(urls):
            wrote = writeRemoteFiles(urls)
        }
        guard wrote else { return }
        lastChangeCount = pasteboard.changeCount
        ignoredChangeCount = lastChangeCount
        FileClipboardCache.refreshProtectedPathsAndCleanup()
    }

    @discardableResult
    func writeRemoteFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        pasteboard.clearContents()
        let wrote = pasteboard.writeObjects(urls.map { $0 as NSURL })
        guard wrote else { return false }
        lastChangeCount = pasteboard.changeCount
        ignoredChangeCount = lastChangeCount
        FileClipboardCache.refreshProtectedPathsAndCleanup()
        return true
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        if ignoredChangeCount == changeCount {
            ignoredChangeCount = nil
            return
        }
        ignoredChangeCount = nil
        FileClipboardCache.refreshProtectedPathsAndCleanup()

        if pasteboard.availableType(from: [.fileURL]) != nil {
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            guard pasteboard.changeCount == changeCount, !urls.isEmpty else { return }
            onLocalChange(.files(urls))
            return
        }
        if let png = ClipboardImageCodec.pngData(from: pasteboard),
           png.count <= ClipboardWire.maximumImageSize {
            onLocalChange(.png(png))
            return
        }
        guard let text = pasteboard.string(forType: .string),
              let data = text.data(using: .utf8),
              data.count <= ClipboardWire.maximumTextSize else {
            return
        }
        onLocalChange(.text(data))
    }
}
