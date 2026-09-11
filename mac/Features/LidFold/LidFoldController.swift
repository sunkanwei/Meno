import AppKit
import Combine
import MetalKit
import ScreenCaptureKit
import OSLog

@MainActor
final class LidFoldController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var status = "开启后，桌面随 MacBook 开合而变化。"
    @Published private(set) var needsPermission = false
    private let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "LidFold")
    private var displayRetryAt: TimeInterval = 0
    private let defaults: UserDefaults
    private let capture = LidFoldCapture()
    private var sensor: LidFoldSensor?
    private var renderer: LidFoldRenderer?
    private var view: MTKView?
    private var panel: NSPanel?
    private var timer: Timer?
    private var permissionTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var generation = 0
    private var monitorGeneration = 0
    private var ready = false
    private var systemAwake = true
    private var displayAwake = true
    private var sessionActive = true
    private var angle: Double?
    private var clearAngle: Double?
    private var motionAnchor: Double?
    private var lastReading: TimeInterval = 0
    private var lastMotion: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var lastPresented: TimeInterval = 0
    private var awaitingFirstPresentation = false
    private var captureStarted: TimeInterval = 0
    private var progress = 0.0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var displayObserver: NSObjectProtocol?
    private lazy var escape = LidFoldEscape { [weak self] in
        self?.setEnabled(false)
        self?.status = "已停止翻盖动效。"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        capture.onFrame = { [weak self] frame in
            guard let self else { return }
            if renderer?.frame == nil { logger.notice("First desktop frame received.") }
            renderer?.frame = frame
        }
        capture.onUnavailable = { [weak self] in self?.waitForDisplay() }
        capture.onFailure = { [weak self] error in
            guard let self else { return }
            let failure = error as NSError
            logger.error("Capture stopped: \(failure.domain, privacy: .public) / \(failure.code)")
            if failure.domain == SCStreamErrorDomain,
               failure.code == SCStreamError.Code.userStopped.rawValue {
                setEnabled(false)
                status = "已按系统中的停止操作关闭翻盖动效。"
            } else if failure.domain == SCStreamErrorDomain,
                      [SCStreamError.Code.systemStoppedStream.rawValue,
                       SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue,
                       SCStreamError.Code.noCaptureSource.rawValue].contains(failure.code) {
                // Display transitions can terminate capture before the workspace notification arrives.
                waitForDisplay()
            } else {
                fail("桌面捕获已暂停，请关闭翻盖动效后重新开启。")
            }
        }
        observeWorkspace()
        if defaults.bool(forKey: AppPreferenceKey.lidFoldEnabled) {
            // Restoring a preference must not raise a permission prompt at launch.
            if CGPreflightScreenCaptureAccess() { setEnabled(true) }
            else {
                enabled = true
                needsPermission = true
                status = "需要允许 Meno 录制屏幕，再开启翻盖动效。"
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        generation += 1
        self.enabled = enabled
        defaults.set(enabled, forKey: AppPreferenceKey.lidFoldEnabled)
        permissionTask?.cancel(); permissionTask = nil
        ready = false
        stopMonitoring()
        clearAngle = nil
        needsPermission = false
        if !enabled { status = "翻盖动效已关闭。"; return }
        status = "正在检查屏幕权限…"
        let token = generation
        permissionTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard generation == token, !Task.isCancelled, self.enabled else { return }
                ready = true
                status = "正在读取屏幕开合角度…"
                startMonitoring()
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                let failure = error as NSError
                let denied = failure.domain == SCStreamErrorDomain
                    && failure.code == SCStreamError.Code.userDeclined.rawValue
                fail(denied ? "请在系统设置中允许 Meno 录制屏幕，然后重新开启。"
                            : "屏幕捕获暂时不可用，请重新开启翻盖动效。")
                needsPermission = denied
            }
        }
    }

    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func stopForApplicationExit() {
        generation += 1
        enabled = false
        permissionTask?.cancel()
        stopMonitoring()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
    }

    private var canRun: Bool { enabled && ready && systemAwake && displayAwake && sessionActive }

    private func startMonitoring() {
        guard canRun, sensor == nil else { return }
        let token = monitorGeneration
        lastReading = ProcessInfo.processInfo.systemUptime
        lastTick = lastReading
        angle = nil; motionAnchor = nil; lastMotion = 0
        sensor = LidFoldSensor { [weak self] value in
            guard let self, monitorGeneration == token, canRun else { return }
            guard let value else {
                angle = nil
                motionAnchor = nil
                lastMotion = 0
                clearOverlay()
                status = "正在等待开合角度恢复，翻盖动效仍保持开启。"
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            lastReading = now
            if clearAngle == nil { clearAngle = min(140, max(60, value)) }
            if let anchor = motionAnchor {
                if abs(value - anchor) >= 1 {
                    motionAnchor = value
                    lastMotion = now
                }
            } else { motionAnchor = value }
            angle = value
            if displayRetryAt == 0, status != "已开启，缓慢开合 MacBook 即可查看。" {
                status = "已开启，缓慢开合 MacBook 即可查看。"
            }
        }
        sensor?.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopMonitoring() {
        monitorGeneration += 1
        sensor?.stop(); sensor = nil
        timer?.invalidate(); timer = nil
        clearOverlay()
        panel?.close(); panel = nil
        view = nil; renderer = nil
        angle = nil; motionAnchor = nil
        displayRetryAt = 0
    }

    private func tick() {
        guard canRun else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        guard now - lastReading < 1 else {
            clearOverlay()
            status = "正在等待开合角度恢复，翻盖动效仍保持开启。"
            return
        }
        if displayRetryAt > 0 {
            guard now >= displayRetryAt else { return }
            guard activeBuiltInScreen() != nil else { displayRetryAt = now + 0.25; return }
            displayRetryAt = 0
            status = "已开启，缓慢开合 MacBook 即可查看。"
            logger.notice("Built-in display available again.")
        }
        guard let angle, let clearAngle else { return }
        guard angle > 7 else { clearOverlay(); return }
        let travel = min(1, max(0, (clearAngle - angle) / (clearAngle - 5)))
        let target = now - lastMotion < 1.25 ? travel * travel * (3 - 2 * travel) : 0
        progress += (target - progress) * (1 - exp(-dt / 0.055))
        if target == 0, progress < 0.0002 { clearOverlay(); return }
        do {
            let displayID = try prepareOverlay()
            renderer?.uniforms.progress = Float(progress)
            if !capture.isRunning, captureTask == nil {
                captureStarted = now
                captureTask = Task { [weak self] in
                    guard let self, canRun, !Task.isCancelled else { return }
                    do { try await capture.start(displayID: displayID) }
                    catch {
                        guard !Task.isCancelled else { return }
                        let failure = error as NSError
                        if case LidFoldError.displayUnavailable = error {
                            waitForDisplay()
                        } else if failure.domain == SCStreamErrorDomain,
                                  [SCStreamError.Code.noDisplayList.rawValue,
                                   SCStreamError.Code.noCaptureSource.rawValue].contains(failure.code) {
                            waitForDisplay()
                        } else {
                            logger.error("Capture start failed: \(failure.domain, privacy: .public) / \(failure.code)")
                            fail("无法捕获桌面，请关闭翻盖动效后重新开启。")
                        }
                    }
                }
            }
            if renderer?.frame != nil, panel?.isVisible != true {
                guard escape.register() else {
                    fail("无法启用 Esc 停止键，翻盖动效未启动。")
                    return
                }
                lastPresented = now
                awaitingFirstPresentation = true
                // A zero-alpha window can be occluded before Metal ever acquires its first drawable.
                // Keep the window drawable; its clear background remains transparent until rendering.
                panel?.alphaValue = 1
                panel?.orderFrontRegardless()
                view?.isPaused = false
                if let view { view.draw() }
            }
            if panel?.isVisible == true, now - lastPresented > 1 {
                fail("翻盖渲染未能及时完成，已恢复桌面。")
            } else if renderer?.frame == nil, now - captureStarted > 2 {
                fail("未能取得桌面画面，翻盖动效已停止。")
            }
        } catch LidFoldError.displayUnavailable {
            waitForDisplay()
        } catch {
            logger.error("Renderer preparation failed: \(error.localizedDescription, privacy: .public)")
            fail("图形渲染暂时不可用，请关闭翻盖动效后重新开启。")
        }
    }

    private func activeBuiltInScreen() -> NSScreen? {
        NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
                && CGDisplayIsActive(number.uint32Value) != 0
                && CGDisplayIsInMirrorSet(number.uint32Value) == 0
        })
    }

    private func waitForDisplay() {
        if displayRetryAt == 0 { logger.notice("Waiting for built-in display; monitoring remains active.") }
        clearOverlay()
        displayRetryAt = ProcessInfo.processInfo.systemUptime + 0.25
        status = "正在等待内建屏幕恢复，翻盖动效仍保持开启。"
    }

    private func prepareOverlay() throws -> CGDirectDisplayID {
        guard let screen = activeBuiltInScreen(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw LidFoldError.displayUnavailable
        }
        if panel != nil { return number.uint32Value }
        guard let device = MTLCreateSystemDefaultDevice() else { throw LidFoldError.message("图形设备不可用。") }
        let renderer = try LidFoldRenderer(device: device)
        renderer.onFailure = { [weak self, weak renderer] in
            guard let self, self.renderer === renderer else { return }
            fail("翻盖渲染已停止，桌面已恢复。")
        }
        renderer.onPresented = { [weak self, weak renderer] in
            guard let self, self.renderer === renderer, canRun, panel?.isVisible == true, capture.isRunning else { return }
            if awaitingFirstPresentation {
                logger.notice("First desktop frame rendered.")
                awaitingFirstPresentation = false
            }
            lastPresented = ProcessInfo.processInfo.systemUptime
            panel?.alphaValue = 1
        }
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Consume clicks rather than sending them to invisible transformed controls.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        let view = LidFoldView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.onClick = { [weak self] in self?.setEnabled(false) }
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true; view.delegate = renderer
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
        self.renderer = renderer; self.panel = panel; self.view = view
        return number.uint32Value
    }

    private func clearOverlay() {
        panel?.orderOut(nil)
        view?.isPaused = true
        escape.stop()
        captureTask?.cancel(); captureTask = nil
        if capture.isRunning { capture.stop() }
        renderer?.clearFrame()
        progress = 0
    }

    private func fail(_ message: String) {
        // A runtime failure must never rewrite the user's enabled preference.
        ready = false
        stopMonitoring()
        status = message
        logger.error("\(message, privacy: .public)")
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, Int, Bool)] = [
            (NSWorkspace.willSleepNotification, 0, false), (NSWorkspace.didWakeNotification, 0, true),
            (NSWorkspace.screensDidSleepNotification, 1, false), (NSWorkspace.screensDidWakeNotification, 1, true),
            (NSWorkspace.sessionDidResignActiveNotification, 2, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, 2, true)
        ]
        for (name, kind, awake) in events {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if kind == 0 { self.systemAwake = awake }
                    if kind == 1 { self.displayAwake = awake }
                    if kind == 2 { self.sessionActive = awake }
                    self.logger.notice("Workspace transition: kind=\(kind), awake=\(awake)")
                    self.stopMonitoring()
                    if self.canRun { self.startMonitoring() }
                }
            })
        }
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearOverlay() }
        })
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopMonitoring()
                if self.canRun { self.startMonitoring() }
            }
        }
    }
}

@MainActor
private final class LidFoldView: MTKView {
    var onClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func otherMouseDown(with event: NSEvent) { onClick?() }
}
