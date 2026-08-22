import AppKit
import Foundation
import OSLog
@preconcurrency import QuickLookUI
@preconcurrency import WebKit

final class PreviewViewController: NSViewController,
    @preconcurrency QLPreviewingController,
    WKNavigationDelegate,
    WKScriptMessageHandler
{
    private struct PendingPreview {
        let content: String
        let documentURL: URL
        let imageData: [String: String]
        let renderVersion: Int
    }

    private static let maxPreviewBytes = 500 * 1024
    private static let transparentPageStyle = """
    for (const element of [
        document.documentElement,
        document.body,
        document.getElementById("markdown-preview")
    ]) {
        element?.style.setProperty("background-color", "transparent", "important");
    }
    """

    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno.MarkdownPreview",
        category: "Preview"
    )
    private var webView: InteractivePreviewWebView!
    private var rendererHandler: RendererBundleSchemeHandler?
    private var localFileHandler: LocalFileSchemeHandler?
    private var currentPreview: PendingPreview?
    private var documentMonitor: MarkdownDocumentMonitor?
    private var securityScopedURL: URL?
    private var securityScopedAccessActive = false
    private var rendererReady = false
    private var renderVersion = 0
    private var activeRenderVersion: Int?
    private var renderedPreviewVersion: Int?
    private var renderTimeoutTask: Task<Void, Never>?
    private let windowState = MarkdownPreviewWindowState()
    private var setupError: Error?
    private weak var observedWindow: NSWindow?
    private var liveResizeWindowIdentifier: ObjectIdentifier?

    override func loadView() {
        let initialSize = constrainedToScreen(windowState.initialSize())
        let materialView = NSVisualEffectView(frame: NSRect(origin: .zero, size: initialSize))
        materialView.material = .underWindowBackground
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        view = materialView
        preferredContentSize = initialSize
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            try configureWebView()
        } catch {
            setupError = error
            logger.error("Preview setup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        observeWindowResize()
        view.window?.makeFirstResponder(webView)
    }

    override func viewWillDisappear() {
        if liveResizeWindowIdentifier != nil {
            saveCurrentWindowSize()
        }
        stopObservingWindowResize()
        cancelPendingRender()
        currentPreview = nil
        renderedPreviewVersion = nil
        localFileHandler?.configure(allowedURLs: [])
        cleanupWebView()
        stopAccessingCurrentDocument()
        super.viewWillDisappear()
    }

    isolated deinit {
        cleanupWebView()
        stopAccessingCurrentDocument()
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        if let setupError {
            handler(setupError)
            return
        }

        if webView == nil {
            do {
                try configureWebView()
            } catch {
                setupError = error
                handler(error)
                return
            }
        }

        let renderWasActive = activeRenderVersion != nil
        stopAccessingCurrentDocument()
        cancelPendingRender()
        currentPreview = nil
        renderedPreviewVersion = nil
        localFileHandler?.configure(allowedURLs: [])
        securityScopedURL = url
        securityScopedAccessActive = url.startAccessingSecurityScopedResource()
        preferredContentSize = constrainedToScreen(windowState.initialSize())

        if renderWasActive {
            cleanupWebView()
            do {
                try configureWebView()
            } catch {
                setupError = error
                stopAccessingCurrentDocument()
                handler(error)
                return
            }
        }

        webView.pageZoom = 1.0
        webView.magnification = 1.0

        startMonitoringDocument(at: url)
        do {
            let content = try readMarkdown(at: url)
            stagePreview(content: content, documentURL: url)
            handler(nil)
        } catch {
            stopAccessingCurrentDocument()
            handler(error)
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.webView === webView, message.frameInfo.isMainFrame else { return }
        switch message.name {
        case "logger":
            guard let text = message.body as? String else { return }
            if text == "rendererReady" {
                rendererReady = true
                renderIfReady()
            } else if text.range(of: "error", options: .caseInsensitive) != nil {
                logger.error("\(text, privacy: .private)")
            }
        case "linkClicked":
            guard let href = message.body as? String else { return }
            openLink(href)
        case "wheelZoom":
            guard let delta = message.body as? Double else { return }
            adjustPageZoom(by: delta)
        default:
            break
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        logger.error("Web content process terminated unexpectedly")
        failCurrentRender(message: "预览渲染进程意外退出。")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        logger.error("Renderer navigation failed: \(error.localizedDescription, privacy: .public)")
        failCurrentRender(message: "预览渲染器无法加载。")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if url == RendererBundleSchemeHandler.indexURL {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        } else {
            logger.notice("Blocked renderer navigation: \(url.absoluteString, privacy: .private)")
        }
        decisionHandler(.cancel)
    }

    private func configureWebView() throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()

        let userContentController = WKUserContentController()
        userContentController.addUserScript(
            WKUserScript(
                source: Self.transparentPageStyle,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        userContentController.add(WeakScriptMessageHandler(delegate: self), name: "logger")
        userContentController.add(WeakScriptMessageHandler(delegate: self), name: "linkClicked")
        userContentController.add(WeakScriptMessageHandler(delegate: self), name: "wheelZoom")
        configuration.userContentController = userContentController

        let localHandler = LocalFileSchemeHandler()
        configuration.setURLSchemeHandler(localHandler, forURLScheme: "local-md")
        localFileHandler = localHandler

        guard let rendererHandler = RendererBundleSchemeHandler(bundle: Bundle(for: Self.self)) else {
            throw PreviewError.rendererResourceUnavailable
        }
        configuration.setURLSchemeHandler(rendererHandler, forURLScheme: RendererBundleSchemeHandler.scheme)
        self.rendererHandler = rendererHandler

        webView = InteractivePreviewWebView(frame: view.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .clear
        webView.enableTransparentBackground()
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        view.subviews.filter { $0.identifier?.rawValue == "MenoPreviewFallback" }
            .forEach { $0.removeFromSuperview() }
        view.addSubview(webView)
        webView.load(URLRequest(url: RendererBundleSchemeHandler.indexURL))
    }

    private func renderIfReady() {
        guard rendererReady, let currentPreview, let webView else { return }
        guard renderedPreviewVersion != currentPreview.renderVersion else { return }
        renderedPreviewVersion = currentPreview.renderVersion
        let version = currentPreview.renderVersion
        activeRenderVersion = version
        startRenderTimeout(renderVersion: version)
        let options: [String: Any] = [
            "baseUrl": currentPreview.documentURL.deletingLastPathComponent().path,
            "theme": "system",
            "imageData": currentPreview.imageData,
            "fontSize": 14,
            "codeHighlightTheme": "default",
            "enableMermaid": true,
            "enableKatex": true,
            "enableTypst": true,
            "enableEmoji": true,
            "context": "quicklook",
            "uiLanguage": "system",
            "showLineNumbers": false,
            "renderVersion": currentPreview.renderVersion
        ]

        webView.callAsyncJavaScript(
            "return window.renderMarkdown(content, options);",
            arguments: ["content": currentPreview.content, "options": options],
            in: nil,
            in: .page
        ) { [weak self] result in
            guard let self, self.activeRenderVersion == version else { return }
            self.activeRenderVersion = nil
            self.renderTimeoutTask?.cancel()
            self.renderTimeoutTask = nil
            switch result {
            case .success:
                break
            case .failure(let error):
                self.logger.error("Markdown rendering failed: \(error.localizedDescription, privacy: .public)")
                self.failCurrentRender(message: "预览渲染失败。")
            }
        }
    }

    private func stagePreview(content: String, documentURL: URL) {
        renderVersion += 1
        let imageResources = MarkdownImageDataCollector.collect(
            from: documentURL,
            markdown: content
        )
        localFileHandler?.configure(allowedURLs: imageResources.allowedFileURLs)
        currentPreview = PendingPreview(
            content: content,
            documentURL: documentURL,
            imageData: imageResources.dataURLs,
            renderVersion: renderVersion
        )
        renderedPreviewVersion = nil
        renderIfReady()
    }

    private func startMonitoringDocument(at url: URL) {
        documentMonitor?.stop()
        let monitor = MarkdownDocumentMonitor(fileURL: url) { [weak self] in
            self?.refreshDocumentIfNeeded(at: url)
        }
        documentMonitor = monitor
        guard monitor.start() else {
            documentMonitor = nil
            logger.error("Unable to monitor the previewed document for changes")
            return
        }
    }

    private func refreshDocumentIfNeeded(at url: URL) {
        guard securityScopedURL == url else { return }
        do {
            let content = try readMarkdown(at: url)
            guard content != currentPreview?.content else { return }

            let renderWasActive = activeRenderVersion != nil
            cancelPendingRender()
            if renderWasActive {
                cleanupWebView()
                try configureWebView()
            }
            stagePreview(content: content, documentURL: url)
        } catch {
            logger.error(
                "Unable to reload changed Markdown document: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func startRenderTimeout(renderVersion: Int) {
        renderTimeoutTask?.cancel()
        renderTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  let self,
                  self.activeRenderVersion == renderVersion else { return }
            self.logger.error("Markdown rendering exceeded the eight second deadline")
            self.failCurrentRender(message: "预览渲染超时。")
        }
    }

    private func failCurrentRender(message: String) {
        cancelPendingRender()
        currentPreview = nil
        renderedPreviewVersion = nil
        localFileHandler?.configure(allowedURLs: [])
        stopAccessingCurrentDocument()
        cleanupWebView()
        presentFallback(message)
    }

    private func presentFallback(_ message: String) {
        view.subviews.filter { $0.identifier?.rawValue == "MenoPreviewFallback" }
            .forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: message)
        label.identifier = NSUserInterfaceItemIdentifier("MenoPreviewFallback")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func cancelPendingRender() {
        renderTimeoutTask?.cancel()
        renderTimeoutTask = nil
        activeRenderVersion = nil
    }

    private func readMarkdown(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxPreviewBytes + 1) ?? Data()
        let wasTruncated = data.count > Self.maxPreviewBytes
        var prefix = Data(data.prefix(Self.maxPreviewBytes))
        var content: String?
        for _ in 0...3 {
            if let decoded = String(data: prefix, encoding: .utf8) {
                content = decoded
                break
            }
            guard !prefix.isEmpty else { break }
            prefix.removeLast()
        }
        guard var content else {
            throw PreviewError.invalidEncoding
        }
        if wasTruncated {
            if let newline = content.lastIndex(of: "\n") {
                content = String(content[...newline])
            }
            content += "\n\n> **预览内容已截断。**"
        }
        return content
    }

    private func openLink(_ href: String) {
        if let url = URL(string: href),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        logger.notice("Blocked unsupported Markdown link: \(href, privacy: .private)")
    }

    private func adjustPageZoom(by rawDelta: Double) {
        guard rawDelta.isFinite, let webView else { return }
        let delta = min(max(rawDelta, -0.1), 0.1)
        webView.pageZoom = min(max(webView.pageZoom + CGFloat(delta), 0.5), 3.0)
    }

    private func stopAccessingCurrentDocument() {
        documentMonitor?.stop()
        documentMonitor = nil
        if securityScopedAccessActive {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        securityScopedAccessActive = false
    }

    private func observeWindowResize() {
        guard let window = view.window, observedWindow !== window else { return }
        stopObservingWindowResize()
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillStartLiveResize),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidEndLiveResize),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
    }

    private func stopObservingWindowResize() {
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willStartLiveResizeNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didEndLiveResizeNotification,
            object: observedWindow
        )
        self.observedWindow = nil
        liveResizeWindowIdentifier = nil
    }

    @objc private func windowWillStartLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === observedWindow else { return }
        liveResizeWindowIdentifier = ObjectIdentifier(window)
    }

    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === observedWindow,
              liveResizeWindowIdentifier == ObjectIdentifier(window) else { return }
        saveCurrentWindowSize()
        liveResizeWindowIdentifier = nil
    }

    private func saveCurrentWindowSize() {
        let size = view.bounds.size
        guard MarkdownPreviewWindowPreferences.isValidRememberedSize(size) else { return }
        windowState.saveLastSize(size)
    }

    private func constrainedToScreen(_ size: CGSize) -> CGSize {
        guard let screen = viewIfLoaded?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return size
        }
        let maximumSize = CGSize(
            width: screen.visibleFrame.width * 0.95,
            height: screen.visibleFrame.height * 0.95
        )
        let scale = min(1, maximumSize.width / size.width, maximumSize.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func cleanupWebView() {
        renderTimeoutTask?.cancel()
        renderTimeoutTask = nil
        activeRenderVersion = nil
        rendererReady = false
        guard let webView else {
            rendererHandler = nil
            localFileHandler = nil
            return
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        let userContentController = webView.configuration.userContentController
        userContentController.removeScriptMessageHandler(forName: "logger")
        userContentController.removeScriptMessageHandler(forName: "linkClicked")
        userContentController.removeScriptMessageHandler(forName: "wheelZoom")
        webView.removeFromSuperview()
        self.webView = nil
        rendererHandler = nil
        localFileHandler = nil
    }
}
