import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var settingsWindowController: SettingsWindowController?
    private var menuBarController: MenuBarController?
    private let finderDesktopPositionController = FinderDesktopPositionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let model = AppModel()
        self.model = model
        self.menuBarController = MenuBarController(model: model) { [weak self] in
            self?.showSettings()
        }

        if !UserDefaults.standard.bool(forKey: "HasCompletedFirstLaunch") {
            UserDefaults.standard.set(true, forKey: "HasCompletedFirstLaunch")
            showSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.refreshPermissionsAndRuntime()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            finderDesktopPositionController.handle(commandURL: url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopForApplicationExit()
    }

    private func showSettings() {
        guard let model else { return }
        let controller = settingsWindowController ?? SettingsWindowController(model: model)
        settingsWindowController = controller
        controller.show()
    }
}
