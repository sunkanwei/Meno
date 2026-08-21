import Foundation

enum MarkdownImageDataCollector {
    struct Resources {
        let dataURLs: [String: String]
        let allowedFileURLs: Set<URL>
    }

    struct Limits {
        let maxImageCount: Int
        let maxImageBytes: UInt64
        let maxTotalBytes: UInt64

        static let `default` = Limits(
            maxImageCount: 32,
            maxImageBytes: 2 * 1024 * 1024,
            maxTotalBytes: 8 * 1024 * 1024
        )
    }

    static func collect(
        from documentURL: URL,
        markdown: String,
        limits: Limits = .default
    ) -> Resources {
        var dataURLs: [String: String] = [:]
        var allowedFileURLs = Set<URL>()
        var dataURLByFilePath: [String: String] = [:]
        var totalBytes: UInt64 = 0

        for reference in references(from: documentURL, markdown: markdown) {
            let filePath = reference.url.path
            if let existingDataURL = dataURLByFilePath[filePath] {
                add(existingDataURL, for: reference.source, to: &dataURLs)
                continue
            }

            guard allowedFileURLs.count < limits.maxImageCount else { break }
            guard let values = try? reference.url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize,
                  fileSize >= 0 else { continue }
            let byteCount = UInt64(fileSize)
            guard byteCount <= limits.maxImageBytes,
                  byteCount <= limits.maxTotalBytes,
                  totalBytes <= limits.maxTotalBytes - byteCount,
                  let data = readData(at: reference.url, maximumBytes: limits.maxImageBytes),
                  let mimeType = mimeType(for: reference.url) else { continue }

            let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
            dataURLByFilePath[filePath] = dataURL
            add(dataURL, for: reference.source, to: &dataURLs)
            allowedFileURLs.insert(reference.url)
            totalBytes += UInt64(data.count)
        }
        return Resources(dataURLs: dataURLs, allowedFileURLs: allowedFileURLs)
    }

    private struct Reference {
        let location: Int
        let source: String
        let url: URL
    }

    private static func references(from documentURL: URL, markdown: String) -> [Reference] {
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        var matches: [(Int, String)] = []

        let markdownPattern = #"!\[[^\]]*\]\(([^)\"]+(?:\s+\"[^\"]*\")?)\)"#
        if let regex = try? NSRegularExpression(pattern: markdownPattern) {
            for match in regex.matches(in: markdown, range: fullRange) where match.numberOfRanges > 1 {
                let source = stripTitle(nsMarkdown.substring(with: match.range(at: 1)))
                matches.append((match.range.location, source))
            }
        }

        let htmlPattern = #"<img\b[^>]*?\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: htmlPattern, options: .caseInsensitive) {
            for match in regex.matches(in: markdown, range: fullRange) {
                for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                    matches.append((match.range.location, nsMarkdown.substring(with: match.range(at: index))))
                    break
                }
            }
        }

        let baseDirectory = documentURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var seen = Set<String>()
        let references: [Reference] = matches.sorted { $0.0 < $1.0 }.compactMap {
            (match: (Int, String)) -> Reference? in
            let (location, rawSource) = match
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isRelativeImagePath(source) else { return nil }
            let decodedSource = source.removingPercentEncoding ?? source
            let url = baseDirectory
                .appendingPathComponent(decodedSource)
                .standardizedFileURL
            guard url.resolvingSymlinksInPath().standardizedFileURL == url,
                  mimeType(for: url) != nil,
                  seen.insert("\(source)\u{0}\(url.path)").inserted else { return nil }
            return Reference(location: location, source: source, url: url)
        }
        return references
    }

    private static func stripTitle(_ reference: String) -> String {
        guard let quote = reference.firstIndex(of: "\"") else { return reference }
        return String(reference[..<quote]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isRelativeImagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), URL(string: path)?.scheme == nil else { return false }
        return true
    }

    private static func add(
        _ dataURL: String,
        for source: String,
        to result: inout [String: String]
    ) {
        result[source] = dataURL
        if source.hasPrefix("./") {
            result[String(source.dropFirst(2))] = dataURL
        } else {
            result["./\(source)"] = dataURL
        }
    }

    private static func readData(at url: URL, maximumBytes: UInt64) -> Data? {
        guard maximumBytes < UInt64(Int.max),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: Int(maximumBytes) + 1),
              data.count <= maximumBytes else { return nil }
        return data
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: nil
        }
    }
}
