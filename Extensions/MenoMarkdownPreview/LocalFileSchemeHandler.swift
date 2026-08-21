import Foundation
@preconcurrency import WebKit

final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let maximumResourceBytes = 2 * 1024 * 1024

    private let lock = NSLock()
    private var allowedPaths = Set<String>()

    func configure(allowedURLs: Set<URL>) {
        lock.lock()
        allowedPaths = Set(allowedURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url,
              let fileURL = allowedFileURL(for: requestURL) else {
            task.didFailWithError(PreviewError.localResourceDenied)
            return
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumResourceBytes + 1) ?? Data()
            guard data.count <= Self.maximumResourceBytes else {
                task.didFailWithError(PreviewError.localResourceDenied)
                return
            }
            task.didReceive(URLResponse(
                url: requestURL,
                mimeType: mimeType(for: fileURL),
                expectedContentLength: data.count,
                textEncodingName: nil
            ))
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    func allowedFileURL(for requestURL: URL) -> URL? {
        let path = resolvedPath(from: requestURL)
        let fileURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL

        lock.lock()
        defer { lock.unlock() }
        return allowedPaths.contains(fileURL.path) ? fileURL : nil
    }

    private func resolvedPath(from url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let cleanURL = components?.url ?? url
        if let host = cleanURL.host, !host.isEmpty {
            return "/" + host + cleanURL.path
        }
        return cleanURL.path
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }
}
