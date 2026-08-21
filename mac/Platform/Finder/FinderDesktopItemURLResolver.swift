import Foundation

enum FinderDesktopItemURLResolver {
    static func resolve(
        reportedURL: URL?,
        filename: String?,
        desktopURL: URL
    ) -> URL? {
        let desktopURL = desktopURL.standardizedFileURL

        if let reportedURL, reportedURL.isFileURL {
            let reportedURL = reportedURL.standardizedFileURL
            guard reportedURL.deletingLastPathComponent() == desktopURL else { return nil }
            return reportedURL
        }

        // Finder may retain an unresolvable file reference after replacing a desktop item.
        guard let filename, !filename.isEmpty else { return nil }
        let candidate = desktopURL.appendingPathComponent(filename).standardizedFileURL
        guard candidate.deletingLastPathComponent() == desktopURL,
              (try? FileManager.default.attributesOfItem(
                  atPath: candidate.path(percentEncoded: false)
              )) != nil else {
            return nil
        }
        return candidate
    }
}
