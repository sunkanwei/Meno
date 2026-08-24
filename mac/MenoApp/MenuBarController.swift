import AppKit
import Combine
import QuartzCore
import SwiftUI

private enum CrossScreenMenuBarIndicator {
    case neutral
    case unavailable
    case ready

    init(status: CrossScreenMouseStatus) {
        switch status {
        case .standby, .connected, .controlling:
            self = .ready
        case .waiting, .failed:
            self = .unavailable
        case .off, .needsArrangement:
            self = .neutral
        }
    }

    var color: NSColor? {
        switch self {
        case .neutral: nil
        case .unavailable: NSColor(srgbRed: 1, green: 0.29, blue: 0.12, alpha: 1)
        case .ready: .systemGreen
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .neutral: "Meno"
        case .unavailable: "Meno：Windows 跨屏当前不可用"
        case .ready: "Meno：Windows 跨屏已就绪"
        }
    }
}

private final class CrossScreenStatusOverlayView: NSView {
    private let colorLayer = CAShapeLayer()
    private let maskLayer = CAShapeLayer()

    var indicator: CrossScreenMenuBarIndicator = .neutral {
        didSet { updateAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        colorLayer.mask = maskLayer
        layer?.addSublayer(colorLayer)
        setAccessibilityElement(false)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let iconSize = NSSize(width: 19, height: 19)
        colorLayer.frame = NSRect(
            x: (bounds.width - iconSize.width) / 2,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        maskLayer.frame = colorLayer.bounds
        maskLayer.path = foldPath(in: colorLayer.bounds).cgPath
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.backgroundColor = indicator.color?.cgColor
        colorLayer.isHidden = indicator.color == nil
        CATransaction.commit()
    }

    private func foldPath(in rect: NSRect) -> NSBezierPath {
        func point(_ normalizedX: CGFloat, _ normalizedY: CGFloat) -> NSPoint {
            NSPoint(
                x: rect.minX + rect.width * normalizedX,
                y: rect.minY + rect.height * normalizedY
            )
        }

        let path = NSBezierPath()
        path.move(to: point(0.3047, 0.5156))
        path.line(to: point(0.3047, 0.2773))
        path.line(to: point(0.4883, 0.1475))
        path.line(to: point(0.6475, 0.2773))
        path.close()
        return path
    }
}

private struct QuickRunSuccessView: View {
    let scriptName: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(scriptName)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let launchAtLogin = LaunchAtLoginController()
    private let model: AppModel
    private let showSettings: () -> Void
    private var crossScreenStatusCancellable: AnyCancellable?
    private var softKVMFailureCancellable: AnyCancellable?
    private var quickRunPopover: NSPopover?
    private var quickRunPopoverDismissWorkItem: DispatchWorkItem?

    init(model: AppModel, showSettings: @escaping () -> Void) {
        self.model = model
        self.showSettings = showSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "m.circle.fill", accessibilityDescription: "Meno")
            image?.isTemplate = true
            image?.size = NSSize(width: 19, height: 19)
            image?.accessibilityDescription = "Meno"
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            let overlay = CrossScreenStatusOverlayView(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            button.addSubview(overlay)
            crossScreenStatusCancellable = model.$crossScreenMouseStatus
                .removeDuplicates()
                .sink { [weak button, weak overlay] status in
                    let indicator = CrossScreenMenuBarIndicator(status: status)
                    overlay?.indicator = indicator
                    button?.toolTip = indicator.accessibilityLabel
                    button?.setAccessibilityLabel(indicator.accessibilityLabel)
                }
        }

        softKVMFailureCancellable = model.$softKVMSwitchFailure
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self else { return }
                self.presentError(title: "无法切换画面与键鼠", message: message)
                self.model.clearSoftKVMSwitchFailure()
            }

        launchAtLogin.configureDefaultIfNeeded()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        statusItem.menu = makeMenu()
        sender.performClick(nil)
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        launchAtLogin.refreshStatus()
        let menu = NSMenu()
        let canSwitch = model.crossScreenMouseEnabled && model.softKVMStatus.actionEnabled
        let softKVMItem = menuItem(
            title: model.softKVMStatus.actionTitle,
            action: #selector(toggleSoftKVM)
        )
        softKVMItem.isEnabled = canSwitch
        menu.addItem(softKVMItem)

        let remoteWakeItem = menuItem(
            title: "远程开启 Windows",
            action: #selector(wakeWindows)
        )
        menu.addItem(remoteWakeItem)

        let remoteShutdownItem = menuItem(
            title: model.remoteShutdownActionTitle,
            action: #selector(forceShutdownWindows)
        )
        remoteShutdownItem.isEnabled = model.canForceShutdownWindows
        menu.addItem(remoteShutdownItem)

        let windowsAgentItem = menuItem(
            title: "Windows Agent：\(model.windowsAgent.menuTitle)",
            symbolName: "server.rack",
            action: #selector(refreshWindowsAgent)
        )
        windowsAgentItem.toolTip = model.windowsAgent.phase.detail
        menu.addItem(windowsAgentItem)

        let quickRunItem = menuItem(
            title: "快捷运行",
            symbolName: "play.circle",
            action: nil
        )
        quickRunItem.submenu = makeQuickRunMenu()
        menu.addItem(quickRunItem)
        menu.addItem(.separator())

        let closedLidModeItem = menuItem(
            title: "合盖行为",
            symbolName: "laptopcomputer",
            action: nil
        )
        let closedLidModeMenu = NSMenu()
        for mode in ClosedLidMode.allCases {
            let item = NSMenuItem(
                title: mode.title,
                action: #selector(selectClosedLidMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = model.closedLidMode == mode ? .on : .off
            closedLidModeMenu.addItem(item)
        }
        closedLidModeItem.submenu = closedLidModeMenu
        menu.addItem(closedLidModeItem)

        let launchAtLoginItem = menuItem(
            title: launchAtLoginTitle,
            action: #selector(toggleLaunchAtLogin)
        )
        switch launchAtLogin.status {
        case .enabled:
            launchAtLoginItem.image = NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: "已开启"
            )
            launchAtLoginItem.image?.isTemplate = true
        case .disabled:
            launchAtLoginItem.attributedTitle = NSAttributedString(
                string: launchAtLoginTitle,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]
            )
        case .requiresApproval:
            break
        }
        menu.addItem(launchAtLoginItem)

        let settingsItem = menuItem(
            title: "设置…",
            symbolName: "gearshape",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = menuItem(
            title: "退出 Meno",
            symbolName: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        return menu
    }

    private func makeQuickRunMenu() -> NSMenu {
        model.quickRun.refresh()
        let menu = NSMenu(title: "快捷运行")

        if let issue = model.quickRun.directoryIssue {
            let item = NSMenuItem(title: issue, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if model.quickRun.scripts.isEmpty {
            let item = NSMenuItem(title: "没有可运行的脚本", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for script in model.quickRun.scripts {
                let running = model.quickRun.isRunning(script)
                let item = NSMenuItem(
                    title: running ? "\(script.displayName)（正在运行）" : script.displayName,
                    action: #selector(runQuickScript(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = script.id
                item.isEnabled = !running
                item.image = NSImage(
                    systemSymbolName: running ? "clock" : "play.fill",
                    accessibilityDescription: item.title
                )
                item.image?.isTemplate = true
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let openDirectoryItem = NSMenuItem(
            title: "打开脚本目录",
            action: #selector(openQuickRunDirectory),
            keyEquivalent: ""
        )
        openDirectoryItem.target = self
        openDirectoryItem.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: "打开脚本目录"
        )
        openDirectoryItem.image?.isTemplate = true
        openDirectoryItem.isEnabled = model.quickRun.directoryIssue == nil
        menu.addItem(openDirectoryItem)
        return menu
    }

    private func menuItem(
        title: String,
        symbolName: String? = nil,
        action: Selector?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbolName {
            item.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: title
            )
            item.image?.isTemplate = true
        } else {
            item.image = Self.transparentMenuIcon
        }
        return item
    }

    private var launchAtLoginTitle: String {
        if launchAtLogin.status == .requiresApproval {
            return "登录时打开（需要确认）"
        }
        return "登录时打开"
    }

    private static let transparentMenuIcon = NSImage(
        size: NSSize(width: 18, height: 18),
        flipped: false
    ) { _ in true }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch launchAtLogin.status {
            case .enabled:
                try launchAtLogin.setEnabled(false)
            case .disabled:
                try launchAtLogin.setEnabled(true)
            case .requiresApproval:
                launchAtLogin.openApprovalSettings()
            }
        } catch {
            if launchAtLogin.status == .requiresApproval {
                launchAtLogin.openApprovalSettings()
            } else {
                presentError(
                    title: "无法更改登录启动设置",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func runQuickScript(_ sender: NSMenuItem) {
        guard let scriptID = sender.representedObject as? String,
              let script = model.quickRun.scripts.first(where: { $0.id == scriptID }) else {
            presentError(title: "无法运行脚本", message: "脚本已经移动或不再可用。")
            return
        }
        let started = model.quickRun.run(script) { [weak self] result in
            guard let self else { return }
            if result.succeeded {
                self.presentQuickRunSuccess(result)
            } else {
                self.presentError(
                    title: "无法运行“\(result.script.displayName)”",
                    message: String(result.detail.prefix(8_000))
                )
            }
        }
        if !started {
            presentError(title: "无法运行脚本", message: "脚本已经在运行或不再可用。")
        }
    }

    @objc private func openQuickRunDirectory() {
        if !NSWorkspace.shared.open(model.quickRun.directoryURL) {
            presentError(title: "无法打开脚本目录", message: "目录已经移动或不再可用。")
        }
    }

    private func presentQuickRunSuccess(_ result: QuickScriptRunResult) {
        guard let button = statusItem.button else { return }
        quickRunPopoverDismissWorkItem?.cancel()
        quickRunPopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: QuickRunSuccessView(
                scriptName: result.script.displayName,
                message: result.summary
            )
        )
        quickRunPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        let workItem = DispatchWorkItem { [weak self, weak popover] in
            popover?.close()
            if self?.quickRunPopover === popover {
                self?.quickRunPopover = nil
                self?.quickRunPopoverDismissWorkItem = nil
            }
        }
        quickRunPopoverDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: workItem)
    }

    @objc private func toggleSoftKVM() {
        model.toggleSoftKVM()
    }

    @objc private func wakeWindows() {
        model.wakeWindows { [weak self] message in
            self?.presentError(title: "无法发送 Windows 开机请求", message: message)
        }
    }

    @objc private func forceShutdownWindows() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "远程关闭 Windows？"
        alert.informativeText = "Windows 中未保存的内容可能丢失。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍要关闭")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        model.forceShutdownWindows { [weak self] message in
            self?.presentError(title: "远程关机未完全完成", message: message)
        }
    }

    @objc private func refreshWindowsAgent() {
        model.windowsAgent.refresh()
    }

    @objc private func selectClosedLidMode(_ sender: NSMenuItem) {
        guard let rawMode = sender.representedObject as? String,
              let mode = ClosedLidMode(rawValue: rawMode) else {
            return
        }
        if !model.setClosedLidMode(mode) {
            presentError(
                title: "无法更改合盖行为",
                message: model.closedLidBehaviorStatus.detail
            )
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
