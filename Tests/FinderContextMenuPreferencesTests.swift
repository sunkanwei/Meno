import XCTest

final class FinderContextMenuPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.sunkanwei.Meno.Tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsToEnabledAndSystemTerminal() {
        let preferences = FinderContextMenuPreferences(
            defaults: defaults,
            domainName: suiteName
        )

        XCTAssertTrue(preferences.isEnabled)
        XCTAssertEqual(
            preferences.terminalBundleIdentifier,
            FinderContextMenuPreferences.systemTerminalBundleIdentifier
        )
    }

    func testPersistsMenuAndTerminalSelection() {
        let preferences = FinderContextMenuPreferences(
            defaults: defaults,
            domainName: suiteName
        )

        preferences.isEnabled = false
        preferences.terminalBundleIdentifier = "com.example.Terminal"

        let reloaded = FinderContextMenuPreferences(
            defaults: defaults,
            domainName: suiteName
        )
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.terminalBundleIdentifier, "com.example.Terminal")
    }
}
