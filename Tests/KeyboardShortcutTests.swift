import XCTest

final class KeyboardShortcutTests: XCTestCase {
    func testCompatibilityIsRestrictedToVerifiedMajorVersions() {
        XCTAssertTrue(FinderShortcutsCompatibility.supports(majorVersion: 26))
        XCTAssertTrue(FinderShortcutsCompatibility.supports(majorVersion: 27))
        XCTAssertFalse(FinderShortcutsCompatibility.supports(majorVersion: 25))
        XCTAssertFalse(FinderShortcutsCompatibility.supports(majorVersion: 28))
    }

    func testSupportedShortcutsAreRecognized() {
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x33, modifiers: [], isRepeat: false, hasCutState: false),
            .goToParent
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x78, modifiers: [], isRepeat: false, hasCutState: false),
            .rename
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x24, modifiers: [], isRepeat: false, hasCutState: false),
            .openSelection
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x4C, modifiers: [], isRepeat: false, hasCutState: false),
            .openSelection
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x75, modifiers: [], isRepeat: false, hasCutState: false),
            .moveToTrash
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(
                keyCode: 0x75,
                modifiers: [],
                isRepeat: false,
                isFunctionModified: true,
                hasCutState: false
            ),
            .moveToTrash
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x07, modifiers: [.command], isRepeat: false, hasCutState: false),
            .beginCut
        )
        XCTAssertEqual(
            KeyboardShortcut.intent(keyCode: 0x09, modifiers: [.command], isRepeat: false, hasCutState: true),
            .movePaste
        )
    }

    func testNormalCopyPasteAndAmbiguousModifiersPassThrough() {
        XCTAssertNil(
            KeyboardShortcut.intent(keyCode: 0x08, modifiers: [.command], isRepeat: false, hasCutState: false)
        )
        XCTAssertNil(
            KeyboardShortcut.intent(keyCode: 0x09, modifiers: [.command], isRepeat: false, hasCutState: false)
        )
        XCTAssertNil(
            KeyboardShortcut.intent(keyCode: 0x07, modifiers: [.control], isRepeat: false, hasCutState: false)
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x07,
                modifiers: [.command, .shift],
                isRepeat: false,
                hasCutState: false
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(keyCode: 0x33, modifiers: [], isRepeat: true, hasCutState: false)
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x33,
                modifiers: [],
                isRepeat: false,
                isFunctionModified: true,
                hasCutState: false
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(keyCode: 0x75, modifiers: [.shift], isRepeat: false, hasCutState: false)
        )
        XCTAssertNil(
            KeyboardShortcut.intent(keyCode: 0x2, modifiers: [.control], isRepeat: false, hasCutState: false)
        )
    }

    func testMappedFileCopyIsObservedWithoutBecomingAReplacementIntent() {
        XCTAssertTrue(
            KeyboardShortcut.isFileCopy(
                keyCode: 0x08,
                modifiers: [.command],
                isRepeat: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcut.isFileCopy(
                keyCode: 0x08,
                modifiers: [.control],
                isRepeat: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcut.isFileCopy(
                keyCode: 0x08,
                modifiers: [.command],
                isRepeat: true
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x08,
                modifiers: [.command],
                isRepeat: false,
                hasCutState: false
            )
        )
    }

    func testMappedFilePasteIsObservedWithoutBecomingAReplacementIntent() {
        XCTAssertTrue(
            KeyboardShortcut.isFilePaste(
                keyCode: 0x09,
                modifiers: [.command],
                isRepeat: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcut.isFilePaste(
                keyCode: 0x09,
                modifiers: [.control],
                isRepeat: false
            )
        )
        XCTAssertFalse(
            KeyboardShortcut.isFilePaste(
                keyCode: 0x09,
                modifiers: [.command],
                isRepeat: true
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x09,
                modifiers: [.command],
                isRepeat: false,
                hasCutState: false
            )
        )
    }

    func testUncheckedShortcutFeaturesPassThrough() {
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x33,
                modifiers: [],
                isRepeat: false,
                hasCutState: false,
                enabledFeatures: [.rename, .cutAndMove]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x78,
                modifiers: [],
                isRepeat: false,
                hasCutState: false,
                enabledFeatures: [.goToParent, .cutAndMove]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x07,
                modifiers: [.command],
                isRepeat: false,
                hasCutState: false,
                enabledFeatures: [.goToParent, .rename]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x09,
                modifiers: [.command],
                isRepeat: false,
                hasCutState: true,
                enabledFeatures: [.goToParent, .rename]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x35,
                modifiers: [],
                isRepeat: false,
                hasCutState: true,
                enabledFeatures: [.goToParent, .rename]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x24,
                modifiers: [],
                isRepeat: false,
                hasCutState: false,
                enabledFeatures: [.goToParent, .rename, .cutAndMove]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x4C,
                modifiers: [],
                isRepeat: false,
                hasCutState: false,
                enabledFeatures: [.goToParent, .rename, .cutAndMove]
            )
        )
        XCTAssertNil(
            KeyboardShortcut.intent(
                keyCode: 0x75,
                modifiers: [],
                isRepeat: false,
                hasCutState: false,
                enabledFeatures: [.goToParent, .rename, .cutAndMove]
            )
        )
    }

    func testDesktopSupportsFileEditingIntents() {
        XCTAssertTrue(FinderShortcutIntent.openSelection.isSupportedOnDesktop)
        XCTAssertTrue(FinderShortcutIntent.rename.isSupportedOnDesktop)
        XCTAssertTrue(FinderShortcutIntent.beginCut.isSupportedOnDesktop)
        XCTAssertTrue(FinderShortcutIntent.movePaste.isSupportedOnDesktop)
        XCTAssertTrue(FinderShortcutIntent.moveToTrash.isSupportedOnDesktop)
        XCTAssertTrue(FinderShortcutIntent.cancelCut.isSupportedOnDesktop)
        XCTAssertFalse(FinderShortcutIntent.goToParent.isSupportedOnDesktop)
    }

    func testTrashSelectionRejectsEmptyNonFileAndTrashLocations() {
        XCTAssertFalse(KeyboardShortcut.canMoveSelectionToTrash([]))
        XCTAssertFalse(
            KeyboardShortcut.canMoveSelectionToTrash([URL(string: "https://example.com/file")!])
        )
        XCTAssertFalse(
            KeyboardShortcut.canMoveSelectionToTrash([
                URL(fileURLWithPath: "/Users/example/.Trash/file.txt")
            ])
        )
        XCTAssertFalse(
            KeyboardShortcut.canMoveSelectionToTrash([
                URL(fileURLWithPath: "/Volumes/Drive/.Trashes/501/file.txt")
            ])
        )
        XCTAssertFalse(
            KeyboardShortcut.canMoveSelectionToTrash([
                URL(fileURLWithPath: "/Users/example/Desktop/file.txt"),
                URL(fileURLWithPath: "/Users/example/.Trash/trashed.txt")
            ])
        )
        XCTAssertTrue(
            KeyboardShortcut.canMoveSelectionToTrash([
                URL(fileURLWithPath: "/Users/example/Desktop/file.txt"),
                URL(fileURLWithPath: "/Users/example/Documents/folder")
            ])
        )
        XCTAssertTrue(
            KeyboardShortcut.canMoveSelectionToTrash([
                URL(fileURLWithPath: "/Users/example/Documents/.TrashBackup/file.txt")
            ])
        )
    }
}
