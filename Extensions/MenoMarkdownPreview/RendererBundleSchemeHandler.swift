import Foundation
@preconcurrency import WebKit

final class RendererBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "meno-renderer"

    private let rootDirectory: URL

    init?(bundle: Bundle) {
        guard let indexURL = bundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "dist"
        ) else {
            return nil
        }
        rootDirectory = indexURL.deletingLastPathComponent().resolvingSymlinksInPath()
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url,
              let fileURL = containedFileURL(for: requestURL) else {
            task.didFailWithError(PreviewError.rendererResourceUnavailable)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            task.didReceive(response(for: requestURL, fileURL: fileURL, length: data.count))
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    static var indexURL: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "bundle"
        components.path = "/index.html"
        return components.url!
    }

    private func containedFileURL(for requestURL: URL) -> URL? {
        var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        let encodedPath = components?.percentEncodedPath ?? requestURL.path
        let relativePath = (encodedPath.removingPercentEncoding ?? encodedPath)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = rootDirectory
            .appendingPathComponent(relativePath.isEmpty ? "index.html" : relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return fileURL.isContained(in: rootDirectory) ? fileURL : nil
    }

    private func response(for requestURL: URL, fileURL: URL, length: Int) -> URLResponse {
        let headers = [
            "Content-Type": mimeType(for: fileURL),
            "Content-Length": String(length),
            "Cache-Control": "no-cache"
        ]
        return HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? URLResponse(
            url: requestURL,
            mimeType: mimeType(for: fileURL),
            expectedContentLength: length,
            textEncodingName: nil
        )
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "application/javascript; charset=utf-8"
        case "wasm": "application/wasm"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        default: "application/octet-stream"
        }
    }
}

extension URL {
    func isContained(in directory: URL) -> Bool {
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = resolvingSymlinksInPath().standardizedFileURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }
}
