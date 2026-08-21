import AppKit
import Foundation

struct TerminalApplication: Identifiable, Hashable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

enum TerminalApplicationDetector {
    private static var searchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    static func detect() -> [TerminalApplication] {
        var applicationsByBundleIdentifier: [String: TerminalApplication] = [:]
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let applicationURL as URL in enumerator {
                guard applicationURL.pathExtension == "app",
                      let bundle = Bundle(url: applicationURL),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      applicationsByBundleIdentifier[bundleIdentifier] == nil,
                      declaresTerminalCapabilities(bundle: bundle) else {
                    continue
                }

                let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? applicationURL.deletingPathExtension().lastPathComponent
                applicationsByBundleIdentifier[bundleIdentifier] = TerminalApplication(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName
                )
            }
        }

        if applicationsByBundleIdentifier[FinderContextMenuPreferences.systemTerminalBundleIdentifier] == nil,
           NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: FinderContextMenuPreferences.systemTerminalBundleIdentifier
           ) != nil {
            applicationsByBundleIdentifier[FinderContextMenuPreferences.systemTerminalBundleIdentifier] =
                TerminalApplication(
                    bundleIdentifier: FinderContextMenuPreferences.systemTerminalBundleIdentifier,
                    displayName: "Terminal"
                )
        }

        return applicationsByBundleIdentifier.values.sorted { lhs, rhs in
            if lhs.bundleIdentifier == FinderContextMenuPreferences.systemTerminalBundleIdentifier {
                return true
            }
            if rhs.bundleIdentifier == FinderContextMenuPreferences.systemTerminalBundleIdentifier {
                return false
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func declaresTerminalCapabilities(bundle: Bundle) -> Bool {
        let documentTypes = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes")
            as? [[String: Any]] ?? []
        var opensFolders = false
        var handlesShellExecutables = false

        for documentType in documentTypes {
            let contentTypes = documentType["LSItemContentTypes"] as? [String] ?? []
            let role = documentType["CFBundleTypeRole"] as? String ?? ""
            if contentTypes.contains("public.folder") || contentTypes.contains("public.directory") {
                opensFolders = true
            }
            if contentTypes.contains("public.unix-executable"),
               role.caseInsensitiveCompare("Shell") == .orderedSame {
                handlesShellExecutables = true
            }
        }

        return opensFolders && handlesShellExecutables
    }
}
