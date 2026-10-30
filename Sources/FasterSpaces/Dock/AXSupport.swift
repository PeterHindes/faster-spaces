import ApplicationServices
import CoreGraphics
import Foundation

enum AXAttr {
    static let role = kAXRoleAttribute as String
    static let subrole = kAXSubroleAttribute as String
    static let title = kAXTitleAttribute as String
    static let description = kAXDescriptionAttribute as String
    static let children = kAXChildrenAttribute as String
    static let parent = kAXParentAttribute as String
    static let position = kAXPositionAttribute as String
    static let size = kAXSizeAttribute as String
    static let enabled = kAXEnabledAttribute as String
    static let hidden = kAXHiddenAttribute as String
    static let menuBar = kAXMenuBarAttribute as String
    static let isApplicationRunning = kAXIsApplicationRunningAttribute as String
    static let selectedChildren = "AXSelectedChildren"
    static let url = "AXURL"
    static let menuItemCmdChar = kAXMenuItemCmdCharAttribute as String
    static let menuItemCmdModifiers = kAXMenuItemCmdModifiersAttribute as String
    static let menuItemMarkChar = kAXMenuItemMarkCharAttribute as String
    static let focusedWindow = kAXFocusedWindowAttribute as String
}

enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return error == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        guard let value = attribute(element, name) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let boolean = value as? Bool { return boolean }
        return nil
    }

    static func int(_ element: AXUIElement, _ name: String) -> Int? {
        guard let value = attribute(element, name) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func url(_ element: AXUIElement, _ name: String) -> URL? {
        guard let value = attribute(element, name) else { return nil }
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        return nil
    }

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = aboutValue(attribute(element, name)) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = aboutValue(attribute(element, name)) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard
            let origin = point(element, AXAttr.position),
            let size = size(element, AXAttr.size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func aboutValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
