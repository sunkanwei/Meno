import Foundation
import XCTest

final class MarkdownPreviewWindowStateTests: XCTestCase {
    private var sharedSuiteName: String!
    private var localSuiteName: String!
    private var sharedDefaults: UserDefaults!
    private var localDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        sharedSuiteName = "com.sunkanwei.Meno.Tests.Shared.\(UUID().uuidString)"
        localSuiteName = "com.sunkanwei.Meno.Tests.Local.\(UUID().uuidString)"
        sharedDefaults = UserDefaults(suiteName: sharedSuiteName)
        localDefaults = UserDefaults(suiteName: localSuiteName)
    }

    override func tearDown() {
        sharedDefaults.removePersistentDomain(forName: sharedSuiteName)
        localDefaults.removePersistentDomain(forName: localSuiteName)
        sharedDefaults = nil
        localDefaults = nil
        sharedSuiteName = nil
        localSuiteName = nil
        super.tearDown()
    }

    func testUsesRecommendedSizeBeforeAnySettingOrResize() {
        XCTAssertEqual(makeState().initialSize(), CGSize(width: 1100, height: 800))
    }

    func testRemembersLastResizedPreview() {
        let state = makeState()
        _ = state.initialSize()
        state.saveLastSize(CGSize(width: 1320, height: 910))

        XCTAssertEqual(state.initialSize(), CGSize(width: 1320, height: 910))
    }

    func testChangedDefaultOverridesPreviouslyRememberedSizeOnce() {
        let preferences = makePreferences()
        let state = MarkdownPreviewWindowState(
            preferences: preferences,
            defaults: localDefaults
        )
        _ = state.initialSize()
        state.saveLastSize(CGSize(width: 1320, height: 910))

        preferences.setDefaultSize(CGSize(width: 1450, height: 950))
        state.saveLastSize(CGSize(width: 1320, height: 910))

        XCTAssertEqual(state.initialSize(), CGSize(width: 1450, height: 950))
    }

    func testClampsConfiguredDefaultSize() {
        let preferences = makePreferences()

        preferences.setDefaultSize(CGSize(width: 200, height: 4000))

        XCTAssertEqual(preferences.defaultSize, CGSize(width: 800, height: 1200))
    }

    func testSavingUnchangedDefaultDoesNotResetRememberedSize() {
        let preferences = makePreferences()
        let state = MarkdownPreviewWindowState(
            preferences: preferences,
            defaults: localDefaults
        )
        _ = state.initialSize()
        state.saveLastSize(CGSize(width: 1320, height: 910))

        preferences.setDefaultSize(preferences.defaultSize)

        XCTAssertEqual(state.initialSize(), CGSize(width: 1320, height: 910))
    }

    private func makeState() -> MarkdownPreviewWindowState {
        MarkdownPreviewWindowState(
            preferences: makePreferences(),
            defaults: localDefaults
        )
    }

    private func makePreferences() -> MarkdownPreviewWindowPreferences {
        MarkdownPreviewWindowPreferences(
            defaults: sharedDefaults,
            domainName: sharedSuiteName
        )
    }
}
