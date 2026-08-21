import AppKit
import Foundation

enum FinderDocumentKind: String, CaseIterable, Sendable {
    case plainText
    case markdown

    var baseName: String {
        switch self {
        case .plainText: "新建文本文档"
        case .markdown: "新建 Markdown 文档"
        }
    }

    var filenameExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown: "md"
        }
    }
}

struct FinderCreateDocumentRequest: Equatable, Sendable {
    let directoryURL: URL
    let kind: FinderDocumentKind
    let position: CGPoint?
}

enum FinderExtensionCommandBridge {
    private static let mainApplicationBundleIdentifier = "com.sunkanwei.Meno"
    private static let commandURLScheme = "meno-sunkanwei-internal"
    private static let createDocumentCommandHost = "create-document"

    static var isMainApplicationRunning: Bool {
        mainApplicationPID != nil
    }

    static func requestCreateDocument(
        directoryURL: URL,
        kind: FinderDocumentKind,
        position: CGPoint?,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) -> Bool {
        guard let mainApplication,
              let applicationURL = mainApplication.bundleURL else { return false }
        let request = FinderCreateDocumentRequest(
            directoryURL: directoryURL,
            kind: kind,
            position: position
        )
        guard let commandURL = createDocumentCommandURL(for: request) else { return false }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(
            [commandURL],
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { _, error in
            completionHandler(error)
        }
        return true
    }

    static func createDocumentRequest(from commandURL: URL) -> FinderCreateDocumentRequest? {
        guard commandURL.absoluteString.utf8.count <= 8 * 1_024,
              commandURL.scheme?.lowercased() == commandURLScheme,
              commandURL.host?.lowercased() == createDocumentCommandHost,
              commandURL.path.isEmpty,
              commandURL.fragment == nil,
              let components = URLComponents(url: commandURL, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }

        let allowedNames: Set<String> = ["directoryPath", "kind", "x", "y"]
        guard queryItems.allSatisfy({ allowedNames.contains($0.name) }) else { return nil }

        func singleValue(_ name: String) -> String? {
            let matches = queryItems.filter { $0.name == name }
            guard matches.count == 1 else { return nil }
            return matches[0].value
        }

        guard let directoryPath = singleValue("directoryPath"),
              !directoryPath.isEmpty,
              directoryPath.utf8.count <= 4_096,
              directoryPath.hasPrefix("/"),
              let kindText = singleValue("kind"),
              let kind = FinderDocumentKind(rawValue: kindText) else { return nil }

        let xValues = queryItems.filter { $0.name == "x" }
        let yValues = queryItems.filter { $0.name == "y" }
        let position: CGPoint?
        if xValues.isEmpty && yValues.isEmpty {
            position = nil
        } else {
            guard xValues.count == 1,
                  yValues.count == 1,
                  let xText = xValues[0].value,
                  let yText = yValues[0].value,
                  let x = Double(xText),
                  let y = Double(yText),
                  x.isFinite,
                  y.isFinite,
                  Int32(exactly: x.rounded()) != nil,
                  Int32(exactly: y.rounded()) != nil else { return nil }
            position = CGPoint(x: x, y: y)
        }

        return FinderCreateDocumentRequest(
            directoryURL: URL(fileURLWithPath: directoryPath, isDirectory: true),
            kind: kind,
            position: position
        )
    }

    static func createDocumentCommandURL(for request: FinderCreateDocumentRequest) -> URL? {
        guard request.directoryURL.isFileURL,
              request.directoryURL.path.hasPrefix("/") else { return nil }
        var components = URLComponents()
        components.scheme = commandURLScheme
        components.host = createDocumentCommandHost
        components.queryItems = [
            URLQueryItem(name: "directoryPath", value: request.directoryURL.path),
            URLQueryItem(name: "kind", value: request.kind.rawValue),
        ]
        if let position = request.position,
           position.x.isFinite,
           position.y.isFinite,
           Int32(exactly: position.x.rounded()) != nil,
           Int32(exactly: position.y.rounded()) != nil {
            components.queryItems?.append(URLQueryItem(name: "x", value: String(Double(position.x))))
            components.queryItems?.append(URLQueryItem(name: "y", value: String(Double(position.y))))
        } else if request.position != nil {
            return nil
        }
        return components.url
    }

    static func fileLocationsMatch(_ firstURL: URL, _ secondURL: URL) -> Bool {
        firstURL.resolvingSymlinksInPath().standardizedFileURL
            == secondURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static var mainApplication: NSRunningApplication? {
        let applications = NSRunningApplication
            .runningApplications(withBundleIdentifier: mainApplicationBundleIdentifier)
        guard let containingApplicationURL else { return applications.first }
        return applications.first { application in
            guard let bundleURL = application.bundleURL else { return false }
            return fileLocationsMatch(bundleURL, containingApplicationURL)
        }
    }

    private static var containingApplicationURL: URL? {
        let extensionURL = Bundle.main.bundleURL
        guard extensionURL.pathExtension == "appex" else { return nil }
        return extensionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var mainApplicationPID: Int32? {
        mainApplication?.processIdentifier
    }
}
