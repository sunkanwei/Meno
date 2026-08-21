import Foundation

struct FinderContextMenuPreferences {
    static let systemTerminalBundleIdentifier = "com.apple.Terminal"

    private enum Key {
        static let isEnabled = "com.sunkanwei.Meno.FinderContextMenuEnabled"
        static let terminalBundleIdentifier =
            "com.sunkanwei.Meno.FinderContextMenuTerminalBundleIdentifier"
    }

    private let testDefaults: UserDefaults?
    private let testDomainName: String?

    init(defaults: UserDefaults? = nil, domainName: String? = nil) {
        precondition((defaults == nil) == (domainName == nil))
        testDefaults = defaults
        testDomainName = domainName
    }

    var isEnabled: Bool {
        get {
            guard let value = value(forKey: Key.isEnabled) else { return true }
            return (value as? NSNumber)?.boolValue ?? true
        }
        nonmutating set {
            setValue(NSNumber(value: newValue), forKey: Key.isEnabled)
        }
    }

    var terminalBundleIdentifier: String {
        get {
            return value(forKey: Key.terminalBundleIdentifier) as? String
                ?? Self.systemTerminalBundleIdentifier
        }
        nonmutating set {
            setValue(newValue as NSString, forKey: Key.terminalBundleIdentifier)
        }
    }

    private func value(forKey key: String) -> Any? {
        if let testDefaults, let testDomainName {
            return testDefaults.persistentDomain(forName: testDomainName)?[key]
        }
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private func setValue(_ value: Any, forKey key: String) {
        if let testDefaults, let testDomainName {
            var domain = testDefaults.persistentDomain(forName: testDomainName) ?? [:]
            domain[key] = value
            testDefaults.setPersistentDomain(domain, forName: testDomainName)
            return
        }
        CFPreferencesSetValue(
            key as CFString,
            value as CFPropertyList,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
