import AppKit
import CoreGraphics

enum MenuBarGlassStatus: Equatable {
    case off
    case running
    case failed(String)

    var title: String {
        switch self {
        case .off:
            return "已关闭"
        case .running:
            return "运行中"
        case let .failed(message):
            return message
        }
    }
}

@MainActor
final class MenuBarGlassController {
    private let onStatusChanged: (MenuBarGlassStatus) -> Void
    private var status: MenuBarGlassStatus = .off
    private var enabled = false
    private var sessionActive = true
    private var screensAwake = true
    private var panel: MenuBarGlassPanel?
    private var refreshWorkItem: DispatchWorkItem?
    private var applicationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(onStatusChanged: @escaping (MenuBarGlassStatus) -> Void) {
        self.onStatusChanged = onStatusChanged
        observeSystemChanges()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        refresh()
    }

    func refresh() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        guard enabled else {
            hidePanel()
            updateStatus(.off)
            return
        }

        guard sessionActive, screensAwake, menuBarCanBeShown else {
            hidePanel()
            updateStatus(.running)
            return
        }

        guard let screen = systemMainScreen() else {
            hidePanel()
            updateStatus(.failed("未找到系统主显示器"))
            return
        }

        let frame = MenuBarGlassLayout.frame(in: screen.frame)
        guard frame.width > 0 else {
            hidePanel()
            updateStatus(.failed("主显示器尺寸无效"))
            return
        }

        let panel = panel ?? MenuBarGlassPanel()
        self.panel = panel
        panel.updateAccessibilityAppearance()
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        updateStatus(.running)
    }

    func stopForApplicationExit() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        hidePanel()
        panel = nil

        let applicationCenter = NotificationCenter.default
        applicationObservers.forEach(applicationCenter.removeObserver)
        applicationObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func scheduleRefresh() {
        guard enabled else { return }
        refreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func hidePanel() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }

    private func updateStatus(_ status: MenuBarGlassStatus) {
        guard self.status != status else { return }
        self.status = status
        onStatusChanged(status)
    }

    private func systemMainScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            guard let displayNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(displayNumber.uint32Value) == mainDisplayID
        }
    }

    private var menuBarCanBeShown: Bool {
        let options = NSApp.currentSystemPresentationOptions
        return !options.contains(.hideMenuBar) && !options.contains(.autoHideMenuBar)
    }

    private func observeSystemChanges() {
        let applicationCenter = NotificationCenter.default
        applicationObservers.append(
            applicationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefresh()
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ] {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.scheduleRefresh()
                    }
                }
            )
        }
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screensAwake = false
                    self?.hidePanel()
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.screensAwake = true
                    self?.scheduleRefresh()
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sessionActive = false
                    self?.hidePanel()
                }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sessionActive = true
                    self?.scheduleRefresh()
                }
            }
        )
    }
}

private enum MenuBarGlassLayout {
    static let height: CGFloat = 30
    static let horizontalMargin: CGFloat = 4

    static func frame(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + horizontalMargin,
            y: screenFrame.maxY - height,
            width: max(0, screenFrame.width - horizontalMargin * 2),
            height: height
        )
    }
}

@MainActor
private final class MenuBarGlassPanel: NSPanel {
    private let glassView = MenuBarGlassView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = glassView
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func updateAccessibilityAppearance() {
        glassView.setReduceTransparency(
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
private final class MenuBarGlassView: NSView {
    private let glassView = NSGlassEffectView()
    private let borderView = NSView()
    private var reducesTransparency = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glassView.style = .clear
        glassView.cornerRadius = 12
        glassView.tintColor = NSColor.white.withAlphaComponent(CGFloat(0x15) / 255)
        addSubview(glassView)

        borderView.wantsLayer = true
        borderView.layer?.cornerRadius = 12
        borderView.layer?.borderWidth = 1
        addSubview(borderView)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func setReduceTransparency(_ reducesTransparency: Bool) {
        guard self.reducesTransparency != reducesTransparency else { return }
        self.reducesTransparency = reducesTransparency
        glassView.isHidden = reducesTransparency
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        glassView.frame = bounds
        borderView.frame = bounds
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            borderView.layer?.backgroundColor = reducesTransparency
                ? NSColor.windowBackgroundColor.cgColor
                : NSColor.clear.cgColor
            borderView.layer?.borderColor = reducesTransparency
                ? NSColor.separatorColor.cgColor
                : NSColor.white.withAlphaComponent(CGFloat(0x50) / 255).cgColor
        }
    }
}
