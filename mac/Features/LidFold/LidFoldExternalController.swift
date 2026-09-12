import AppKit
import ScreenCaptureKit
import OSLog

@MainActor
final class LidFoldExternalController {
    @MainActor
    private final class Surface {
        let id: CGDirectDisplayID
        let overlay: LidFoldOverlay
        let capture = LidFoldCapture()
        var captureTask: Task<Void, Never>?
        var lastPresented: TimeInterval
        var hasPresented = false
        var isBlack = false

        init(id: CGDirectDisplayID, overlay: LidFoldOverlay, now: TimeInterval) {
            self.id = id
            self.overlay = overlay
            self.lastPresented = now
        }

        func stopCapture() {
            captureTask?.cancel(); captureTask = nil
            capture.stop()
            overlay.renderer.clearFrame()
        }

        func close() {
            stopCapture()
            overlay.close()
        }
    }

    private let logger = Logger(subsystem: "com.sunkanwei.Meno", category: "LidFoldExternal")
    private let onStopRequested: () -> Void
    private let onWillShow: () -> Bool
    private let onVisibilityChanged: () -> Void
    private var enabled = false
    private var sessionActive = true
    private var surfaces: [CGDirectDisplayID: Surface] = [:]
    private var failedDisplays: Set<CGDirectDisplayID> = []
    private var policy = LidFoldExternalPolicy()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var blackStarted = false
    private var progress = 0.0
    private var lastTick: TimeInterval = 0
    private lazy var lid = LidStateMonitor { [weak self] in
        Task { @MainActor [weak self] in self?.lidChanged() }
    }

    var hasVisibleOverlay: Bool { surfaces.values.contains { $0.overlay.panel.isVisible } }

    init(onStopRequested: @escaping () -> Void, onWillShow: @escaping () -> Bool,
         onVisibilityChanged: @escaping () -> Void) {
        self.onStopRequested = onStopRequested
        self.onWillShow = onWillShow
        self.onVisibilityChanged = onVisibilityChanged
    }

    func start() {
        enabled = true
        if !lid.start() { logger.error("Lid state notifications unavailable; angle readings remain active.") }
    }

    func stop() {
        enabled = false
        lid.stop()
        cancel()
    }

    func read(angle: Double, reference: Double) {
        guard enabled, sessionActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = policy.phase
        policy.read(angle: angle, reference: reference, now: now)
        if previous != .closing, policy.phase == .closing { failedDisplays.removeAll() }
        switch policy.phase {
        case .idle:
            clearSurfaces()
        case .closing:
            setTimer(interval: 1.0 / 60)
        case .black:
            updateBlack(now: now)
        case .waitingForOpening:
            clearSurfaces()
        }
    }

    func angleUnavailable() {
        if lid.currentState() == .closed {
            if case .black = policy.phase { return }
            if policy.phase == .waitingForOpening { return }
        }
        cancel()
    }

    func cancel() {
        policy.cancel()
        clearSurfaces()
        failedDisplays.removeAll()
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        if !active { cancel() }
    }

    func willSleep() {
        guard enabled, sessionActive else { return }
        if lid.currentState() == .closed {
            policy.didClose(now: ProcessInfo.processInfo.systemUptime)
            updateBlack(now: ProcessInfo.processInfo.systemUptime)
        } else {
            cancel()
        }
    }

    func didWake() {
        // A display can wake while the lid is still closed. Do not expose the
        // desktop during the existing power controller's next sleep request.
        if lid.currentState() != .closed { cancel() }
    }

    func spaceChanged() {
        if lid.currentState() == .closed { displaysChanged() }
        else { cancel() }
    }

    func displaysChanged() {
        // Capture may report a disappearing display before AppKit reports the
        // new topology. A configuration change makes that display retryable.
        failedDisplays.removeAll()
        if enabled, sessionActive, lid.currentState() == .closed {
            let now = ProcessInfo.processInfo.systemUptime
            policy.didClose(now: now)
            updateBlack(now: now)
        }
        let screens = externalScreens()
        for surface in Array(surfaces.values) {
            guard let screen = screens[surface.id] else {
                remove(surface)
                continue
            }
            if surface.overlay.panel.frame != screen.frame {
                // An animated capture is no longer aligned after reconfiguration.
                // A plain black window can safely follow the same display.
                if surface.isBlack { surface.overlay.panel.setFrame(screen.frame, display: false) }
                else { remove(surface) }
            }
        }
    }

    private func lidChanged() {
        guard enabled, sessionActive else { return }
        switch lid.currentState() {
        case .closed:
            let now = ProcessInfo.processInfo.systemUptime
            policy.didClose(now: now)
            updateBlack(now: now)
        case .open:
            cancel()
        case .unavailable:
            angleUnavailable()
        }
    }

    private func externalScreens() -> [CGDirectDisplayID: NSScreen] {
        var result: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            guard CGDisplayIsBuiltin(id) == 0, CGDisplayIsActive(id) != 0,
                  CGDisplayIsInMirrorSet(id) == 0 else { continue }
            result[id] = screen
        }
        return result
    }

    private func prepareSurfaces(now: TimeInterval) {
        for (id, screen) in externalScreens() where surfaces[id] == nil && !failedDisplays.contains(id) {
            do {
                let overlay = try LidFoldOverlay(screen: screen, onClick: onStopRequested)
                let surface = Surface(id: id, overlay: overlay, now: now)
                surfaces[id] = surface
                surface.capture.onFrame = { [weak self, weak surface] frame in
                    guard let self, let surface, surfaces[id] === surface, !surface.isBlack else { return }
                    surface.overlay.renderer.frame = frame
                }
                surface.capture.onUnavailable = { [weak self, weak surface] in
                    guard let self, let surface else { return }
                    captureInterrupted(surface)
                }
                surface.capture.onFailure = { [weak self, weak surface] error in
                    guard let self, let surface, surfaces[id] === surface else { return }
                    let failure = error as NSError
                    if failure.domain == SCStreamErrorDomain, failure.code == SCStreamError.Code.userStopped.rawValue {
                        onStopRequested()
                    } else { captureInterrupted(surface) }
                }
                overlay.renderer.onFailure = { [weak self, weak surface] in
                    guard let self, let surface else { return }
                    fail(surface)
                }
                overlay.renderer.onPresented = { [weak self, weak surface] in
                    guard let self, let surface, surfaces[id] === surface, !surface.isBlack else { return }
                    if !surface.hasPresented { logger.notice("First external frame rendered: display=\(id)") }
                    surface.hasPresented = true
                    surface.lastPresented = ProcessInfo.processInfo.systemUptime
                }
            } catch {
                failedDisplays.insert(id)
                logger.error("External overlay unavailable: display=\(id), \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func tick() {
        guard enabled, sessionActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if case .black = policy.phase { updateBlack(now: now); return }
        let target = policy.target(now: now)
        let dt = min(0.1, max(0, now - lastTick))
        lastTick = now
        progress += (target - progress) * (1 - exp(-dt / 0.055))
        if target == 0, progress < 0.0002 { cancel(); return }
        prepareSurfaces(now: now)
        for surface in Array(surfaces.values) {
            let id = surface.id
            guard CGDisplayIsActive(id) != 0 else { remove(surface); continue }
            surface.overlay.renderer.uniforms.progress = Float(progress)
            if surface.captureTask == nil {
                surface.captureTask = Task { [weak self, weak surface] in
                    guard let self, let surface, surfaces[id] === surface, !Task.isCancelled else { return }
                    do { try await surface.capture.start(displayID: id) }
                    catch {
                        guard !Task.isCancelled, surfaces[id] === surface else { return }
                        captureInterrupted(surface)
                    }
                }
            }
            if surface.overlay.renderer.frame != nil, !surface.overlay.panel.isVisible {
                guard onWillShow() else { return }
                surface.lastPresented = now
                surface.overlay.panel.orderFrontRegardless()
                surface.overlay.view.isPaused = false
                surface.overlay.view.draw()
            }
            if now - surface.lastPresented > (surface.overlay.panel.isVisible ? 1 : 2) {
                logger.error("External capture/render timeout: display=\(id)")
                fail(surface)
            }
        }
    }

    private func updateBlack(now: TimeInterval) {
        guard policy.target(now: now) == 1 else { clearSurfaces(); return }
        if !blackStarted {
            blackStarted = true
            failedDisplays.removeAll()
        }
        prepareSurfaces(now: now)
        for surface in Array(surfaces.values) {
            guard CGDisplayIsActive(surface.id) != 0 else { remove(surface); continue }
            if !surface.isBlack {
                guard onWillShow() else { return }
                surface.isBlack = true
                surface.stopCapture()
                surface.overlay.showBlack()
                logger.notice("External display waiting in black: display=\(surface.id)")
            }
        }
        // Black needs no screen capture or GPU render loop. Only check whether
        // each monitor has gone to sleep and whether the handoff has timed out.
        setTimer(interval: 0.1)
    }

    private func captureInterrupted(_ surface: Surface) {
        guard surfaces[surface.id] === surface, !surface.isBlack else { return }
        if lid.currentState() == .closed {
            let now = ProcessInfo.processInfo.systemUptime
            policy.didClose(now: now)
            updateBlack(now: now)
        } else {
            fail(surface)
        }
    }

    private func fail(_ surface: Surface) {
        guard surfaces[surface.id] === surface else { return }
        // Do not retry a failed capture every frame. Normal display sleep or
        // reconfiguration can recreate its surface within the same lid gesture.
        failedDisplays.insert(surface.id)
        remove(surface)
    }

    private func remove(_ surface: Surface) {
        guard surfaces[surface.id] === surface else { return }
        surfaces.removeValue(forKey: surface.id)
        surface.close()
        onVisibilityChanged()
    }

    private func clearSurfaces() {
        timer?.invalidate(); timer = nil
        timerInterval = 0
        let old = Array(surfaces.values)
        surfaces.removeAll()
        old.forEach { $0.close() }
        progress = 0
        blackStarted = false
        onVisibilityChanged()
    }

    private func setTimer(interval: TimeInterval) {
        guard timer == nil || timerInterval != interval else { return }
        timer?.invalidate()
        timerInterval = interval
        lastTick = ProcessInfo.processInfo.systemUptime
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
}
