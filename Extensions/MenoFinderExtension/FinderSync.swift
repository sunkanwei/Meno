import AppKit
import FinderSync

private final class FinderMenuContext: NSObject {
    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }
}

private func finderMenuImage(symbolName: String, description: String) -> NSImage? {
    let foregroundColor: NSColor = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        ? .white
        : .black
    let pointSizeConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
    let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [foregroundColor])
    let configuration = pointSizeConfiguration.applying(colorConfiguration)

    guard let symbol = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: description
    )?.withSymbolConfiguration(configuration),
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 48,
        pixelsHigh: 48,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: representation) else {
        return nil
    }

    let size = NSSize(width: 24, height: 24)
    representation.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: 2, y: 2)
    symbol.draw(
        in: NSRect(origin: .zero, size: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: nil
    )
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(representation)
    image.accessibilityDescription = description
    image.isTemplate = false
    return image
}

final class FinderSync: FIFinderSync {
    private let contextMenuPreferences = FinderContextMenuPreferences()
    // Finder can invoke a copied menu item without preserving its represented object.
    private var presentedMenuContext: FinderMenuContext?

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/", isDirectory: true)
        ]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard FinderExtensionCommandBridge.isMainApplicationRunning,
              contextMenuPreferences.isEnabled,
              let directoryURL = targetDirectoryURL(for: menuKind) else {
            return nil
        }

        let context = FinderMenuContext(directoryURL: directoryURL)
        presentedMenuContext = context
        return contextMenu(context: context)
    }
}

private extension FinderSync {
    private func contextMenu(context: FinderMenuContext) -> NSMenu {
        let menu = NSMenu(title: "Meno")

        let terminalItem = NSMenuItem(
            title: "在终端中打开",
            action: #selector(openInTerminal),
            keyEquivalent: ""
        )
        terminalItem.target = self
        terminalItem.representedObject = context
        terminalItem.image = finderMenuImage(symbolName: "terminal", description: "在终端中打开")
        menu.addItem(terminalItem)

        let newDocumentItem = NSMenuItem(title: "新建文档", action: nil, keyEquivalent: "")
        newDocumentItem.image = finderMenuImage(symbolName: "doc.badge.plus", description: "新建文档")
        let newDocumentMenu = NSMenu(title: "新建文档")
        newDocumentMenu.addItem(documentMenuItem(
            title: "文本文档",
            kind: .plainText,
            context: context
        ))
        newDocumentMenu.addItem(documentMenuItem(
            title: "Markdown 文档",
            kind: .markdown,
            context: context
        ))
        newDocumentItem.submenu = newDocumentMenu
        menu.addItem(newDocumentItem)

        return menu
    }

    private func documentMenuItem(
        title: String,
        kind: FinderDocumentKind,
        context: FinderMenuContext
    ) -> NSMenuItem {
        let selector: Selector = switch kind {
        case .plainText:
            #selector(createPlainTextDocument)
        case .markdown:
            #selector(createMarkdownDocument)
        }
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = context
        item.image = finderMenuImage(symbolName: "doc.text", description: title)
        return item
    }

    private func targetDirectoryURL(for menuKind: FIMenuKind) -> URL? {
        let controller = FIFinderSyncController.default()
        let candidate: URL?

        switch menuKind {
        case .contextualMenuForContainer:
            candidate = controller.targetedURL()
        case .contextualMenuForItems:
            let selectedURLs = controller.selectedItemURLs() ?? []
            if selectedURLs.isEmpty {
                candidate = controller.targetedURL()
            } else {
                candidate = selectedURLs.count == 1 ? selectedURLs[0] : nil
            }
        default:
            return nil
        }

        return validatedDirectoryURL(candidate)
    }

    private func validatedDirectoryURL(_ candidate: URL?) -> URL? {
        guard let candidate,
              candidate.isFileURL,
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              !candidate.isInTrashLocation else {
            return nil
        }
        return candidate.standardizedFileURL
    }

    private func desktopPosition(directoryURL: URL) -> CGPoint? {
        guard let desktopURL = FileManager.default.urls(
                  for: .desktopDirectory,
                  in: .userDomainMask
              ).first,
              FinderExtensionCommandBridge.fileLocationsMatch(directoryURL, desktopURL) else {
            return nil
        }
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else { return nil }
        return FinderDesktopCoordinateSpace.finderPosition(
            for: NSEvent.mouseLocation,
            primaryScreenFrame: primaryScreen.frame,
            screenFrames: screens.map(\.frame)
        )
    }

    @objc private func openInTerminal(_ sender: NSMenuItem) {
        guard let context = menuContext(from: sender) else { return }
        let directoryURL = context.directoryURL

        var bundleIdentifier = contextMenuPreferences.terminalBundleIdentifier
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) == nil {
            bundleIdentifier = FinderContextMenuPreferences.systemTerminalBundleIdentifier
            contextMenuPreferences.terminalBundleIdentifier = bundleIdentifier
        }

        runShellCommand(
            "/usr/bin/open -b \(shellQuoted(bundleIdentifier)) \(shellQuoted(directoryURL.path))",
            errorTitle: "无法打开终端"
        )
    }

    @objc private func createPlainTextDocument(_ sender: NSMenuItem) {
        createDocument(.plainText, sender: sender)
    }

    @objc private func createMarkdownDocument(_ sender: NSMenuItem) {
        createDocument(.markdown, sender: sender)
    }

    private func createDocument(_ kind: FinderDocumentKind, sender: NSMenuItem) {
        guard let context = menuContext(from: sender) else { return }
        let directoryURL = context.directoryURL
        let requestWasSent = FinderExtensionCommandBridge.requestCreateDocument(
            directoryURL: directoryURL,
            kind: kind,
            position: desktopPosition(directoryURL: directoryURL)
        ) { error in
            guard let error else { return }
            FinderSync.showError(
                title: "无法新建文档",
                message: error.localizedDescription
            )
        }
        if !requestWasSent {
            Self.showError(
                title: "无法新建文档",
                message: "Meno 没有运行，或系统无法向 Meno 发送创建命令。"
            )
        }
    }

    private func menuContext(from sender: NSMenuItem) -> FinderMenuContext? {
        if let context = sender.representedObject as? FinderMenuContext,
           validatedDirectoryURL(context.directoryURL) == context.directoryURL {
            return context
        }
        if let context = presentedMenuContext,
           validatedDirectoryURL(context.directoryURL) == context.directoryURL {
            return context
        }
        guard let directoryURL = validatedDirectoryURL(
            FIFinderSyncController.default().targetedURL()
        ) else {
            return nil
        }
        return FinderMenuContext(directoryURL: directoryURL)
    }

    private func runShellCommand(
        _ command: String,
        errorTitle: String
    ) {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escapedCommand)\"") else {
            Self.showError(title: errorTitle, message: "无法准备该操作。")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "操作失败。"
            Self.showError(title: errorTitle, message: message)
            return
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func showError(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
