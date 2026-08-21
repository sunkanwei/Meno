import AppKit
import Darwin
import OSLog

@MainActor
final class FinderDesktopPositionController {
    private let logger = Logger(
        subsystem: "com.sunkanwei.Meno",
        category: "FinderCreateDocument"
    )
    func handle(commandURL: URL) {
        guard let request = FinderExtensionCommandBridge.createDocumentRequest(
            from: commandURL
        ) else {
            logger.error("Rejected an invalid Finder create-document command URL")
            return
        }
        do {
            try perform(request)
        } catch {
            logger.error("Finder create-document request failed: \(error.localizedDescription, privacy: .public)")
            showFailure(message: error.localizedDescription)
        }
    }

    private func perform(_ request: FinderCreateDocumentRequest) throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == FinderProcess.bundleIdentifier,
              currentFinderDirectories().contains(where: {
                  FinderExtensionCommandBridge.fileLocationsMatch(
                      request.directoryURL,
                      $0
                  )
              }) else {
            throw requestError("Finder 当前目录已经变化，请重新打开右键菜单。")
        }

        let directory = request.directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              !directory.isInTrashLocation else {
            throw requestError("目标位置不是可用的普通文件夹。")
        }

        let fileURL = try createEmptyDocument(in: directory, kind: request.kind)
        if let position = request.position,
           let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
           ).first,
           FinderExtensionCommandBridge.fileLocationsMatch(directory, desktopURL) {
            do {
                try positionDesktopItem(fileURL, at: position)
            } catch {
                logger.error("Finder desktop positioning failed: \(error.localizedDescription, privacy: .public)")
                showFailure(message: error.localizedDescription)
            }
        }
    }

    private func currentFinderDirectories() -> [URL] {
        let scriptSource = """
        tell application "Finder"
            set targetFolders to {insertion location}
            try
                set selectedItems to selection
                if (count of selectedItems) is 1 then
                    set selectedItem to item 1 of selectedItems
                    if class of selectedItem is folder then set end of targetFolders to selectedItem
                end if
            end try
            set targetPaths to {}
            repeat with targetFolder in targetFolders
                set end of targetPaths to POSIX path of (targetFolder as alias)
            end repeat
            return targetPaths
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            guard let path = result.atIndex(index)?.stringValue,
                  path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
    }

    private func createEmptyDocument(
        in directoryURL: URL,
        kind: FinderDocumentKind
    ) throws -> URL {
        for index in 1...9_999 {
            let suffix = index == 1 ? "" : " \(index)"
            let fileURL = directoryURL.appendingPathComponent(
                "\(kind.baseName)\(suffix).\(kind.filenameExtension)",
                isDirectory: false
            )
            let (descriptor, code) = fileURL.withUnsafeFileSystemRepresentation {
                path -> (Int32, Int32) in
                guard let path else { return (-1, EINVAL) }
                let descriptor = Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
                )
                return (descriptor, descriptor < 0 ? errno : 0)
            }
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return fileURL
            }
            if code != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        throw requestError("该文件夹中没有可用的新文档名称。")
    }

    private func positionDesktopItem(_ fileURL: URL, at position: CGPoint) throws {
        guard position.x.isFinite,
              position.y.isFinite,
              let x = Int32(exactly: position.x.rounded()),
              let y = Int32(exactly: position.y.rounded()),
              isVisibleDesktopPosition(position) else {
            throw requestError("桌面位置已经失效，新文档已创建但未移动图标。")
        }
        let scriptSource = """
        set targetItem to POSIX file \(appleScriptString(fileURL.path)) as alias
        tell application "Finder"
            set desktop position of targetItem to {\(x), \(y)}
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else {
            throw requestError("无法准备 Finder 桌面定位命令。")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? "Finder 没有接受桌面定位命令。"
            throw requestError("新文档已创建，但无法放到鼠标位置：\(message)")
        }
    }

    private func isVisibleDesktopPosition(_ position: CGPoint) -> Bool {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return false }
        return FinderDesktopCoordinateSpace.containsFinderPosition(
            position,
            primaryScreenFrame: primary.frame,
            screenFrames: screens.map(\.frame)
        )
    }

    private func appleScriptString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func requestError(_ message: String) -> NSError {
        NSError(
            domain: "com.sunkanwei.Meno.FinderCreateDocument",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func showFailure(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法新建文档"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
