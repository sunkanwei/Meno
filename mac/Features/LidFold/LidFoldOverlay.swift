import AppKit
import MetalKit

@MainActor
final class LidFoldOverlay {
    let panel: NSPanel
    let view: MTKView
    let renderer: LidFoldRenderer

    init(screen: NSScreen, onClick: @escaping () -> Void) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LidFoldError.message("图形设备不可用。")
        }
        renderer = try LidFoldRenderer(device: device)
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        let view = LidFoldView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.onClick = onClick
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.delegate = renderer
        self.view = view
        panel.contentView = view
        panel.setFrame(screen.frame, display: false)
    }

    func showBlack() {
        view.isPaused = true
        // Hide the Metal surface rather than relying on a last GPU submission
        // while the display is disappearing. The window itself supplies black.
        panel.backgroundColor = .black
        panel.isOpaque = true
        view.layer?.opacity = 0
        renderer.clearFrame()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        view.isPaused = true
        renderer.clearFrame()
        panel.close()
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
