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
    func currentContext(
        expectedPID: Int32,
        requiresSingleSelection: Bool = false
    ) -> FinderContextSnapshot? {
        guard AccessibilityPermission.canReadAndPostEvents,
              isFrontmostFinder(pid: expectedPID) else {
            return nil
        }

        let application = AXUIElementCreateApplication(expectedPID)
        guard AXReader.element(application, attribute: kAXShownMenuUIElementAttribute) == nil else {
            return nil
        }

        if let context = browserWindowContext(
            application: application,
            finderPID: expectedPID,
            requiresSingleSelection: requiresSingleSelection
        ) {
            return context
        }
        return desktopContext(
            application: application,
            finderPID: expectedPID,
            requiresSingleSelection: requiresSingleSelection
        )
    }

    func isFrontmostFinder(pid: Int32) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication else { return false }
        return application.bundleIdentifier == FinderProcess.bundleIdentifier
            && application.processIdentifier == pid
    }

    private func browserWindowContext(
        application: AXUIElement,
        finderPID: Int32,
        requiresSingleSelection: Bool
    ) -> FinderContextSnapshot? {
        guard let focusedWindow = AXReader.element(application, attribute: kAXFocusedWindowAttribute),
              AXReader.string(focusedWindow, attribute: kAXRoleAttribute) == kAXWindowRole as String,
              AXReader.string(focusedWindow, attribute: kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              AXReader.string(focusedWindow, attribute: kAXIdentifierAttribute) == "FinderWindow",
              let focusedElement = AXReader.element(application, attribute: kAXFocusedUIElementAttribute),
              let ancestry = ancestry(from: focusedElement, through: focusedWindow),
              let fileViewIndex = ancestry.firstIndex(where: isFileView),
              !containsUnsafeFocus(in: ancestry),
              !hasActiveSearch(in: focusedWindow) else {
            return nil
        }

        // Finder can rename selected items even when its view does not expose their URLs.
        guard !requiresSingleSelection || hasSingleSelection(in: ancestry[...fileViewIndex]) else {
            return nil
        }
        return FinderContextSnapshot(
            finderPID: finderPID,
            scope: .browserWindow,
            selectedItemURLs: requiresSingleSelection ? [] : selectedFileURLs(in: ancestry)
        )
    }

    private func desktopContext(
        application: AXUIElement,
        finderPID: Int32,
        requiresSingleSelection: Bool
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
        guard !requiresSingleSelection || selectedURLs.count == 1 else { return nil }

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

    private func isFileView(_ element: AXUIElement) -> Bool {
        switch AXReader.string(element, attribute: kAXIdentifierAttribute) {
        case "IconView", "ListView", "ColumnView", "GalleryView":
            return true
        default:
            return false
        }
    }

    private func hasSingleSelection(in fileViewAncestry: ArraySlice<AXUIElement>) -> Bool {
        if let count = selectedItemCount(in: fileViewAncestry) {
            return count == 1
        }
        guard let fileView = fileViewAncestry.last,
              AXReader.string(fileView, attribute: kAXIdentifierAttribute) == "ColumnView" else {
            return false
        }

        // Column View can report focus on the browser while the selection lives in a column list.
        for column in AXReader.elements(fileView, attribute: kAXColumnsAttribute).reversed() {
            let lists = AXReader.elements(column, attribute: kAXChildrenAttribute).filter {
                AXReader.string($0, attribute: kAXRoleAttribute) == kAXListRole as String
            }
            if let count = selectedItemCount(in: lists), count > 0 {
                return count == 1
            }
        }
        return false
    }

    private func selectedItemCount(in elements: some Sequence<AXUIElement>) -> Int? {
        for element in elements {
            let rows = AXReader.value(element, attribute: kAXSelectedRowsAttribute) as? [AXUIElement]
            let children = AXReader.value(element, attribute: kAXSelectedChildrenAttribute) as? [AXUIElement]
            if rows != nil || children != nil {
                return max(rows?.count ?? 0, children?.count ?? 0)
            }
        }
        return nil
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
