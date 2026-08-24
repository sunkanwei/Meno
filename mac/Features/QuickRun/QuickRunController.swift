import Foundation

@MainActor
final class QuickRunController: ObservableObject {
    static let defaultDirectoryURL = URL(
        fileURLWithPath: "/Users/sunkanwei/Myapp/Meno/mac/QuickScripts",
        isDirectory: true
    )

    @Published private(set) var directoryURL: URL
    @Published private(set) var scripts: [QuickScript] = []
    @Published private(set) var directoryIssue: String?
    private var runningScriptIDs: Set<String> = []

    private let defaults: UserDefaults
    private let runner: QuickScriptRunner
    private let defaultDirectoryURL: URL
    private let preferenceKey: String

    init(
        defaults: UserDefaults = .standard,
        runner: QuickScriptRunner = QuickScriptRunner(),
        defaultDirectoryURL: URL = QuickRunController.defaultDirectoryURL,
        preferenceKey: String = AppPreferenceKey.quickRunDirectoryPath
    ) {
        self.defaults = defaults
        self.runner = runner
        self.defaultDirectoryURL = defaultDirectoryURL.standardizedFileURL
        self.preferenceKey = preferenceKey
        if let savedPath = defaults.string(forKey: preferenceKey), !savedPath.isEmpty {
            directoryURL = URL(fileURLWithPath: savedPath, isDirectory: true).standardizedFileURL
        } else {
            directoryURL = self.defaultDirectoryURL
        }
        refresh()
    }

    func setDirectory(_ url: URL) {
        directoryURL = url.standardizedFileURL
        defaults.set(directoryURL.path, forKey: preferenceKey)
        refresh()
    }

    func restoreDefaultDirectory() {
        directoryURL = defaultDirectoryURL
        defaults.removeObject(forKey: preferenceKey)
        refresh()
    }

    func refresh() {
        do {
            scripts = try QuickScriptCatalog.load(from: directoryURL)
            directoryIssue = nil
        } catch {
            scripts = []
            directoryIssue = error.localizedDescription
        }
    }

    func isRunning(_ script: QuickScript) -> Bool {
        runningScriptIDs.contains(script.id)
    }

    var isUsingDefaultDirectory: Bool {
        directoryURL == defaultDirectoryURL
    }

    func run(
        _ script: QuickScript,
        completion: @MainActor @escaping (QuickScriptRunResult) -> Void
    ) -> Bool {
        guard scripts.contains(script), !isRunning(script) else { return false }
        runningScriptIDs.insert(script.id)
        runner.run(script) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.runningScriptIDs.remove(result.script.id)
                self.refresh()
                completion(result)
            }
        }
        return true
    }

    func stopForApplicationExit() {
        runner.shutdown()
        runningScriptIDs.removeAll()
    }
}
