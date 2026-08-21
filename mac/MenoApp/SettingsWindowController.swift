import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private static let frameAutosaveName = "MenoSettingsWindow"

    init(model: AppModel) {
        let hostingController = NSHostingController(rootView: SettingsView(model: model))
        hostingController.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.setAccessibilityLabel("Meno 设置")
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 900, height: 650))
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
