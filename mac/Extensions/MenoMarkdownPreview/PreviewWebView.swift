import AppKit
@preconcurrency import WebKit

final class InteractivePreviewWebView: WKWebView {
    override var isOpaque: Bool { false }

    func enableTransparentBackground() {
        setValue(false, forKey: "drawsBackground")
    }

    override func setValue(_ value: Any?, forUndefinedKey key: String) {
        guard key != "drawsBackground" else { return }
        super.setValue(value, forUndefinedKey: key)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
