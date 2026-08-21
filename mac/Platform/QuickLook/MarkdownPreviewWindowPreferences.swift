import Foundation

struct MarkdownPreviewWindowPreferences {
    static let recommendedSize = CGSize(width: 1100, height: 800)
    static let widthRange = 800...1800
    static let heightRange = 600...1200

    private enum Key {
        static let defaultWidth = "com.sunkanwei.Meno.MarkdownPreviewDefaultWidth"
        static let defaultHeight = "com.sunkanwei.Meno.MarkdownPreviewDefaultHeight"
        static let revision = "com.sunkanwei.Meno.MarkdownPreviewSizeRevision"
    }

    private let testDefaults: UserDefaults?
    private let testDomainName: String?

    init(defaults: UserDefaults? = nil, domainName: String? = nil) {
        precondition((defaults == nil) == (domainName == nil))
        testDefaults = defaults
        testDomainName = domainName
    }

    var defaultSize: CGSize {
        let width = (value(forKey: Key.defaultWidth) as? NSNumber)?.doubleValue
            ?? Self.recommendedSize.width
        let height = (value(forKey: Key.defaultHeight) as? NSNumber)?.doubleValue
            ?? Self.recommendedSize.height
        return Self.clampedDefaultSize(CGSize(width: width, height: height))
    }

    var revision: String {
        value(forKey: Key.revision) as? String ?? "built-in-v1"
    }

    func setDefaultSize(_ size: CGSize) {
        let size = Self.clampedDefaultSize(size)
        guard size != defaultSize else { return }
        setValues([
            Key.defaultWidth: NSNumber(value: size.width),
            Key.defaultHeight: NSNumber(value: size.height),
            Key.revision: UUID().uuidString as NSString
        ])
    }

    static func isValidRememberedSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
            && size.width >= 480 && size.height >= 320
            && size.width <= 10_000 && size.height <= 10_000
    }

    private static func clampedDefaultSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(
                max(size.width, CGFloat(widthRange.lowerBound)),
                CGFloat(widthRange.upperBound)
            ),
            height: min(
                max(size.height, CGFloat(heightRange.lowerBound)),
                CGFloat(heightRange.upperBound)
            )
        )
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

    private func setValues(_ values: [String: Any]) {
        if let testDefaults, let testDomainName {
            var domain = testDefaults.persistentDomain(forName: testDomainName) ?? [:]
            values.forEach { domain[$0.key] = $0.value }
            testDefaults.setPersistentDomain(domain, forName: testDomainName)
            return
        }
        values.forEach {
            CFPreferencesSetValue(
                $0.key as CFString,
                $0.value as CFPropertyList,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
