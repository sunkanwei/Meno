@preconcurrency import CoreGraphics
import Foundation

enum FinderShortcutsCompatibility {
    private static let supportedOSMajorVersions: Set<Int> = [26, 27]

    static func supports(majorVersion: Int) -> Bool {
        supportedOSMajorVersions.contains(majorVersion)
    }
}

struct ShortcutModifiers: OptionSet, Sendable {
    let rawValue: UInt8

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let control = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(eventFlags: CGEventFlags) {
        var modifiers: ShortcutModifiers = []
        if eventFlags.contains(.maskCommand) { modifiers.insert(.command) }
        if eventFlags.contains(.maskControl) { modifiers.insert(.control) }
        if eventFlags.contains(.maskAlternate) { modifiers.insert(.option) }
        if eventFlags.contains(.maskShift) { modifiers.insert(.shift) }
        self = modifiers
    }
}

struct FinderShortcutFeatures: OptionSet, Sendable {
    let rawValue: UInt8

    static let goToParent = FinderShortcutFeatures(rawValue: 1 << 0)
    static let rename = FinderShortcutFeatures(rawValue: 1 << 1)
    static let cutAndMove = FinderShortcutFeatures(rawValue: 1 << 2)
    static let openSelection = FinderShortcutFeatures(rawValue: 1 << 3)
    static let moveToTrash = FinderShortcutFeatures(rawValue: 1 << 4)
    static let all: FinderShortcutFeatures = [
        .goToParent,
        .rename,
        .cutAndMove,
        .openSelection,
        .moveToTrash
    ]
}

enum FinderShortcutIntent: Equatable, Sendable {
    case goToParent
    case openSelection
    case rename
    case beginCut
    case movePaste
    case moveToTrash
    case cancelCut

    var isSupportedOnDesktop: Bool {
        switch self {
        case .openSelection, .rename, .beginCut, .movePaste, .moveToTrash, .cancelCut:
            return true
        case .goToParent:
            return false
        }
    }
}

enum KeyboardShortcut {
    private static let backspaceKeyCode: Int64 = 0x33
    private static let returnKeyCode: Int64 = 0x24
    private static let keypadEnterKeyCode: Int64 = 0x4C
    private static let forwardDeleteKeyCode: Int64 = 0x75
    private static let escapeKeyCode: Int64 = 0x35
    private static let f2KeyCode: Int64 = 0x78
    private static let cKeyCode: Int64 = 0x08
    private static let xKeyCode: Int64 = 0x07
    private static let vKeyCode: Int64 = 0x09

    static func intent(
        keyCode: Int64,
        modifiers: ShortcutModifiers,
        isRepeat: Bool,
        isFunctionModified: Bool = false,
        hasCutState: Bool,
        enabledFeatures: FinderShortcutFeatures = .all
    ) -> FinderShortcutIntent? {
        guard !isRepeat else { return nil }

        switch (keyCode, modifiers) {
        case (backspaceKeyCode, [])
            where !isFunctionModified && enabledFeatures.contains(.goToParent):
            return .goToParent
        case (returnKeyCode, []) where enabledFeatures.contains(.openSelection):
            return .openSelection
        case (keypadEnterKeyCode, []) where enabledFeatures.contains(.openSelection):
            return .openSelection
        case (f2KeyCode, []) where enabledFeatures.contains(.rename):
            return .rename
        case (xKeyCode, [.command]) where enabledFeatures.contains(.cutAndMove):
            return .beginCut
        case (vKeyCode, [.command]) where hasCutState && enabledFeatures.contains(.cutAndMove):
            return .movePaste
        case (forwardDeleteKeyCode, []) where enabledFeatures.contains(.moveToTrash):
            return .moveToTrash
        case (escapeKeyCode, []) where hasCutState && enabledFeatures.contains(.cutAndMove):
            return .cancelCut
        default:
            return nil
        }
    }

    static func isFileCopy(
        keyCode: Int64,
        modifiers: ShortcutModifiers,
        isRepeat: Bool
    ) -> Bool {
        !isRepeat && keyCode == cKeyCode && modifiers == [.command]
    }

    static func isFilePaste(
        keyCode: Int64,
        modifiers: ShortcutModifiers,
        isRepeat: Bool
    ) -> Bool {
        !isRepeat && keyCode == vKeyCode && modifiers == [.command]
    }

    static func canMoveSelectionToTrash(_ selectedURLs: [URL]) -> Bool {
        guard !selectedURLs.isEmpty else { return false }

        return selectedURLs.allSatisfy { url in
            url.isFileURL && !url.standardizedFileURL.isInTrashLocation
        }
    }
}
