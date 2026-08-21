import AppKit
import ApplicationServices

enum FinderContextScope: Equatable, Sendable {
    case browserWindow
    case desktop
}

struct FinderContextSnapshot: Sendable {
    let finderPID: Int32
    let scope: FinderContextScope
    let selectedItemURLs: [URL]
}

final class FinderContextInspector {
    func currentContext(expectedPID: Int32) -> FinderContextSnapshot? {
        guard AccessibilityPermission.canReadAndPostEvents,
              isFrontmostFinder(pid: expectedPID) else {
            return nil
        }

        let application = AXUIElementCreateApplication(expectedPID)
        guard AXReader.element(application, attribute: kAXShownMenuUIElementAttribute) == nil else {
            return nil
        }

        if let context = browserWindowContext(application: application, finderPID: expectedPID) {
            return context
        }
        return desktopContext(application: application, finderPID: expectedPID)
    }

    func isFrontmostFinder(pid: Int32) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication else { return false }
        return application.bundleIdentifier == FinderProcess.bundleIdentifier
            && application.processIdentifier == pid
    }

    private func browserWindowContext(
        application: AXUIElement,
        finderPID: Int32
    ) -> FinderContextSnapshot? {
        guard let focusedWindow = AXReader.element(application, attribute: kAXFocusedWindowAttribute),
              AXReader.string(focusedWindow, attribute: kAXRoleAttribute) == kAXWindowRole as String,
              AXReader.string(focusedWindow, attribute: kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              AXReader.string(focusedWindow, attribute: kAXIdentifierAttribute) == "FinderWindow",
              !hasActiveSearch(in: focusedWindow),
              let focusedElement = AXReader.element(application, attribute: kAXFocusedUIElementAttribute),
              let ancestry = ancestry(from: focusedElement, through: focusedWindow),
              !containsUnsafeFocus(in: ancestry),
              let contentRoot = contentRoot(in: focusedWindow),
              ancestry.contains(where: { AXReader.isSame($0, contentRoot) }),
              ancestry.contains(where: isSelectableFileCollection) else {
            return nil
        }

        return FinderContextSnapshot(
            finderPID: finderPID,
            scope: .browserWindow,
            selectedItemURLs: selectedFileURLs(in: ancestry)
        )
    }

    private func desktopContext(
        application: AXUIElement,
        finderPID: Int32
    ) -> FinderContextSnapshot? {
        guard let desktopRoot = AXReader.element(application, attribute: kAXFocusedWindowAttribute),
              AXReader.string(desktopRoot, attribute: kAXRoleAttribute) == kAXScrollAreaRole as String,
              let focusedElement = AXReader.element(application, attribute: kAXFocusedUIElementAttribute),
              let ancestry = ancestry(from: focusedElement, through: desktopRoot),
              !containsUnsafeFocus(in: ancestry),
              let desktopURL = FileManager.default.urls(
                  for: .desktopDirectory,
                  in: .userDomainMask
              ).first else {
            return nil
        }

        let selectedURLs = selectedDesktopItemURLs(
            in: desktopRoot,
            desktopURL: desktopURL.standardizedFileURL,
            depth: 0
        )

        return FinderContextSnapshot(
            finderPID: finderPID,
            scope: .desktop,
            selectedItemURLs: selectedURLs
        )
    }

    private func ancestry(
        from focusedElement: AXUIElement,
        through focusedWindow: AXUIElement
    ) -> [AXUIElement]? {
        var result: [AXUIElement] = []
        var current: AXUIElement? = focusedElement

        for _ in 0..<20 {
            guard let element = current else { return nil }
            result.append(element)
            if AXReader.isSame(element, focusedWindow) {
                return result
            }
            current = AXReader.element(element, attribute: kAXParentAttribute)
        }
        return nil
    }

    private func containsUnsafeFocus(in ancestry: [AXUIElement]) -> Bool {
        let editingRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        let unsafeRoles = [
            kAXMenuRole as String,
            kAXMenuItemRole as String,
            kAXMenuBarRole as String,
            kAXMenuBarItemRole as String,
            kAXToolbarRole as String,
            kAXSheetRole as String
        ]

        return ancestry.contains { element in
            let role = AXReader.string(element, attribute: kAXRoleAttribute)
            let subrole = AXReader.string(element, attribute: kAXSubroleAttribute)
            return role.map(editingRoles.contains) == true
                || role.map(unsafeRoles.contains) == true
                || subrole == kAXSearchFieldSubrole as String
                || AXReader.bool(element, attribute: kAXIsEditableAttribute) == true
        }
    }

    private func contentRoot(in window: AXUIElement) -> AXUIElement? {
        guard let outerSplit = AXReader.elements(window, attribute: kAXChildrenAttribute)
            .first(where: { AXReader.string($0, attribute: kAXRoleAttribute) == kAXSplitGroupRole as String }) else {
            return nil
        }

        return AXReader.elements(outerSplit, attribute: kAXChildrenAttribute)
            .last(where: { AXReader.string($0, attribute: kAXRoleAttribute) == kAXSplitGroupRole as String })
    }

    private func isSelectableFileCollection(_ element: AXUIElement) -> Bool {
        let role = AXReader.string(element, attribute: kAXRoleAttribute)
        let subrole = AXReader.string(element, attribute: kAXSubroleAttribute)
        let identifier = AXReader.string(element, attribute: kAXIdentifierAttribute)

        if role == kAXListRole as String {
            return subrole == "AXCollectionList" || identifier == "IconView"
        }
        return role == kAXOutlineRole as String
            || role == kAXBrowserRole as String
            || role == kAXTableRole as String
            || role == kAXGridRole as String
    }

    private func selectedFileURLs(in ancestry: [AXUIElement]) -> [URL] {
        var urls: [URL] = []
        for element in ancestry {
            for attribute in [
                kAXSelectedChildrenAttribute,
                kAXSelectedRowsAttribute,
                kAXSelectedColumnsAttribute
            ] {
                for selectedElement in AXReader.elements(element, attribute: attribute) {
                    urls.append(contentsOf: fileURLs(in: selectedElement, depth: 0))
                    urls.append(contentsOf: selectedURLsWithinContainer(selectedElement, depth: 0))
                }
            }
        }

        return urls.normalizedFileURLs()
    }

    private func selectedDesktopItemURLs(
        in element: AXUIElement,
        desktopURL: URL,
        depth: Int
    ) -> [URL] {
        guard depth <= 5 else { return [] }

        let directlySelectedItems = AXReader.elements(element, attribute: kAXSelectedChildrenAttribute)
        if !directlySelectedItems.isEmpty {
            let directlySelectedURLs = directlySelectedItems
                .compactMap { desktopItemURL(in: $0, desktopURL: desktopURL) }
            guard directlySelectedURLs.count == directlySelectedItems.count else { return [] }
            return directlySelectedURLs.normalizedFileURLs()
        }

        var urls: [URL] = []
        if AXReader.bool(element, attribute: kAXSelectedAttribute) == true,
           let url = desktopItemURL(in: element, desktopURL: desktopURL) {
            urls.append(url)
        }

        for child in AXReader.elements(element, attribute: kAXChildrenAttribute).prefix(100) {
            urls.append(contentsOf: selectedDesktopItemURLs(
                in: child,
                desktopURL: desktopURL,
                depth: depth + 1
            ))
        }

        return urls.normalizedFileURLs()
    }

    private func desktopItemURL(in element: AXUIElement, desktopURL: URL) -> URL? {
        guard AXReader.string(element, attribute: kAXRoleAttribute) == kAXImageRole as String else {
            return nil
        }
        return FinderDesktopItemURLResolver.resolve(
            reportedURL: AXReader.url(element, attribute: kAXURLAttribute),
            filename: AXReader.string(element, attribute: kAXFilenameAttribute),
            desktopURL: desktopURL
        )
    }

    private func selectedURLsWithinContainer(_ element: AXUIElement, depth: Int) -> [URL] {
        guard depth < 5 else { return [] }
        var urls: [URL] = []

        for attribute in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute] {
            for selectedElement in AXReader.elements(element, attribute: attribute) {
                urls.append(contentsOf: fileURLs(in: selectedElement, depth: 0))
            }
        }

        let role = AXReader.string(element, attribute: kAXRoleAttribute)
        let structuralRoles = [
            kAXBrowserRole as String,
            kAXScrollAreaRole as String,
            kAXListRole as String,
            kAXOutlineRole as String,
            kAXTableRole as String
        ]
        guard role.map(structuralRoles.contains) == true else { return urls }

        for child in AXReader.elements(element, attribute: kAXChildrenAttribute).prefix(20) {
            urls.append(contentsOf: selectedURLsWithinContainer(child, depth: depth + 1))
        }
        return urls
    }

    private func fileURLs(in element: AXUIElement, depth: Int) -> [URL] {
        guard depth <= 4 else { return [] }
        var urls: [URL] = []
        if let url = AXReader.url(element, attribute: kAXURLAttribute), url.isFileURL {
            urls.append(url)
        }
        for child in AXReader.elements(element, attribute: kAXChildrenAttribute).prefix(20) {
            urls.append(contentsOf: fileURLs(in: child, depth: depth + 1))
        }
        return urls
    }

    private func hasActiveSearch(in window: AXUIElement) -> Bool {
        for toolbar in AXReader.elements(window, attribute: kAXChildrenAttribute)
        where AXReader.string(toolbar, attribute: kAXRoleAttribute) == kAXToolbarRole as String {
            if containsNonemptySearchField(toolbar, depth: 0) {
                return true
            }
        }
        return false
    }

    private func containsNonemptySearchField(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth <= 6 else { return false }
        let subrole = AXReader.string(element, attribute: kAXSubroleAttribute)
        if subrole == kAXSearchFieldSubrole as String,
           let value = AXReader.string(element, attribute: kAXValueAttribute),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        for child in AXReader.elements(element, attribute: kAXChildrenAttribute).prefix(30)
        where containsNonemptySearchField(child, depth: depth + 1) {
            return true
        }
        return false
    }
}
