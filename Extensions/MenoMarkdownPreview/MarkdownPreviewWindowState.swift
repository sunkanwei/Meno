import Foundation

struct MarkdownPreviewWindowState {
    private enum Key {
        static let width = "MarkdownPreviewLastWidth"
        static let height = "MarkdownPreviewLastHeight"
        static let appliedRevision = "MarkdownPreviewAppliedSizeRevision"
    }

    private let preferences: MarkdownPreviewWindowPreferences
    private let defaults: UserDefaults

    init(
        preferences: MarkdownPreviewWindowPreferences = .init(),
        defaults: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.defaults = defaults
    }

    func initialSize() -> CGSize {
        let revision = preferences.revision
        guard defaults.string(forKey: Key.appliedRevision) == revision else {
            let size = preferences.defaultSize
            save(size, revision: revision)
            return size
        }

        let size = CGSize(
            width: defaults.double(forKey: Key.width),
            height: defaults.double(forKey: Key.height)
        )
        return MarkdownPreviewWindowPreferences.isValidRememberedSize(size)
            ? size
            : preferences.defaultSize
    }

    func saveLastSize(_ size: CGSize) {
        let currentRevision = preferences.revision
        guard defaults.string(forKey: Key.appliedRevision) == currentRevision,
              MarkdownPreviewWindowPreferences.isValidRememberedSize(size) else { return }
        save(size, revision: currentRevision)
    }

    private func save(_ size: CGSize, revision: String) {
        defaults.set(size.width, forKey: Key.width)
        defaults.set(size.height, forKey: Key.height)
        defaults.set(revision, forKey: Key.appliedRevision)
    }
}
