import ApplicationServices

enum AXReader {
    static func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    static func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let attributeValue = value(element, attribute: attribute),
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        value(element, attribute: attribute) as? [AXUIElement] ?? []
    }

    static func string(_ element: AXUIElement, attribute: String) -> String? {
        value(element, attribute: attribute) as? String
    }

    static func bool(_ element: AXUIElement, attribute: String) -> Bool? {
        value(element, attribute: attribute) as? Bool
    }

    static func url(_ element: AXUIElement, attribute: String) -> URL? {
        if let url = value(element, attribute: attribute) as? URL {
            return url
        }
        if let text = string(element, attribute: attribute) {
            return URL(string: text)
        }
        return nil
    }

    static func isSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }
}
