import Foundation

struct CodexMCPConfigDocument {
    private static let section = "[mcp_servers.windows_agent]"

    static func configuredURL(in text: String) -> URL? {
        let lines = text.components(separatedBy: .newlines)
        guard let bounds = sectionBounds(in: lines) else { return nil }

        for index in bounds.contentRange {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("url"),
                  let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.count >= 2,
                  value.first == "\"",
                  value.last == "\"" else { continue }
            return URL(string: String(value.dropFirst().dropLast()))
        }
        return nil
    }

    static func upsertingWindowsAgent(in text: String, url: URL) -> (text: String, changed: Bool) {
        let desiredLine = "url = \"\(url.absoluteString)\""
        var lines = text.components(separatedBy: .newlines)

        guard let bounds = sectionBounds(in: lines) else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append(section)
            lines.append(desiredLine)
            return (lines.joined(separator: "\n"), true)
        }

        for index in bounds.contentRange {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("url"), line.contains("=") else { continue }
            guard lines[index] != desiredLine else { return (text, false) }
            lines[index] = desiredLine
            return (lines.joined(separator: "\n"), true)
        }

        lines.insert(desiredLine, at: bounds.end)
        return (lines.joined(separator: "\n"), true)
    }

    private static func sectionBounds(in lines: [String]) -> (contentRange: Range<Int>, end: Int)? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == section
        }) else { return nil }

        let contentStart = start + 1
        let end = lines[contentStart...].firstIndex(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("[") && line.hasSuffix("]")
        }) ?? lines.endIndex
        return (contentStart..<end, end)
    }
}

struct CodexMCPConfigStore {
    private let fileManager: FileManager
    private let configURL: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.configURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    func configuredEndpoint() -> WindowsAgentEndpoint? {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8),
              let url = CodexMCPConfigDocument.configuredURL(in: text),
              let host = url.host,
              let port = url.port,
              let portValue = UInt16(exactly: port) else { return nil }
        return WindowsAgentEndpoint(
            name: "Codex 当前配置",
            host: host,
            port: portValue,
            path: url.path.isEmpty ? "/mcp" : url.path
        )
    }

    @discardableResult
    func synchronize(endpoint: WindowsAgentEndpoint) throws -> Bool {
        guard let url = endpoint.url else {
            throw CodexMCPConfigError.invalidEndpoint
        }

        let existingText: String
        if fileManager.fileExists(atPath: configURL.path) {
            existingText = try String(contentsOf: configURL, encoding: .utf8)
        } else {
            existingText = ""
        }
        let result = CodexMCPConfigDocument.upsertingWindowsAgent(in: existingText, url: url)
        guard result.changed else { return false }

        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let permissions = try? fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions]
        try Data(result.text.utf8).write(to: configURL, options: .atomic)
        if let permissions {
            try? fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: configURL.path
            )
        }
        return true
    }
}

private enum CodexMCPConfigError: LocalizedError {
    case invalidEndpoint

    var errorDescription: String? {
        "Windows Agent 返回了无效的连接地址。"
    }
}
