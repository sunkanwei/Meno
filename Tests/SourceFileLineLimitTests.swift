import XCTest

final class SourceFileLineLimitTests: XCTestCase {
    private let warningLimit = 600
    private let hardLimit = 700
    private let productionDirectories = ["Extensions", "Features", "Helpers", "MenoApp", "Platform"]

    @MainActor
    func testProductionSourceFilesStayWithinLineLimits() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        let fileManager = FileManager.default
        var warnings: [(path: String, lines: Int)] = []
        var violations: [(path: String, lines: Int)] = []

        for directory in productionDirectories {
            let directoryURL = repositoryURL.appendingPathComponent(directory, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                XCTFail("Cannot inspect production source directory: \(directory)")
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }

                let lines = lineCount(in: try Data(contentsOf: fileURL))
                let path = relativePath(of: fileURL, from: repositoryURL)

                if lines > hardLimit {
                    violations.append((path, lines))
                } else if lines > warningLimit {
                    warnings.append((path, lines))
                }
            }
        }

        warnings.sort { $0.path < $1.path }
        violations.sort { $0.path < $1.path }

        recordWarnings(warnings)

        XCTAssertTrue(
            violations.isEmpty,
            "Source files above the \(hardLimit)-line hard limit:\n\(report(for: violations))"
        )
    }

    private func lineCount(in data: Data) -> Int {
        let newlineCount = data.reduce(into: 0) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        }

        if data.isEmpty || data.last == 0x0A {
            return newlineCount
        }
        return newlineCount + 1
    }

    private func relativePath(of fileURL: URL, from repositoryURL: URL) -> String {
        let prefix = repositoryURL.path + "/"
        guard fileURL.path.hasPrefix(prefix) else { return fileURL.path }
        return String(fileURL.path.dropFirst(prefix.count))
    }

    @MainActor
    private func recordWarnings(_ warnings: [(path: String, lines: Int)]) {
        guard !warnings.isEmpty else { return }

        let warningReport = report(for: warnings)
        print("Source files between \(warningLimit + 1) and \(hardLimit) lines:\n\(warningReport)")
        XCTContext.runActivity(
            named: "Source files between \(warningLimit + 1) and \(hardLimit) lines"
        ) { activity in
            let attachment = XCTAttachment(string: warningReport)
            attachment.name = "Source line-limit warnings"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private func report(for files: [(path: String, lines: Int)]) -> String {
        files.map { "\($0.path): \($0.lines) lines" }.joined(separator: "\n")
    }
}
