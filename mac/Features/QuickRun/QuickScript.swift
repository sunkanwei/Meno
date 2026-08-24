import Foundation

struct QuickScript: Hashable, Identifiable, Sendable {
    let url: URL

    var id: String {
        url.standardizedFileURL.path
    }

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}

enum QuickScriptCatalogError: LocalizedError, Equatable {
    case directoryUnavailable
    case unreadableDirectory(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable:
            "脚本目录不存在或不是文件夹。"
        case let .unreadableDirectory(message):
            "无法读取脚本目录：\(message)"
        }
    }
}

enum QuickScriptCatalog {
    static func load(
        from directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> [QuickScript] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw QuickScriptCatalogError.directoryUnavailable
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isHiddenKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw QuickScriptCatalogError.unreadableDirectory(error.localizedDescription)
        }

        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "zsh" else { return nil }
            guard let values = try? url.resourceValues(
                forKeys: [.isHiddenKey, .isRegularFileKey, .isSymbolicLinkKey]
            ) else { return nil }
            guard values.isHidden != true,
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return QuickScript(url: url.standardizedFileURL)
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
