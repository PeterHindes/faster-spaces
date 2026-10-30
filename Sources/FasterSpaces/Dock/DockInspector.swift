import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum DockInspectionResult {
    case application(DockTile)
    case notApplication
    case unavailable
}

final class DockInspector {
    static let applicationDockSubrole = "AXApplicationDockItem"
    private static let itemHoverSlop: CGFloat = 8

    private let lock = NSLock()
    private var cachedDockPID: pid_t = 0
    private var cachedDockElement: AXUIElement?
    private var cachedDockList: AXUIElement?

    func invalidateDockElement() {
        lock.lock()
        cachedDockPID = 0
        cachedDockElement = nil
        cachedDockList = nil
        lock.unlock()
    }

    func scan() -> DockSnapshot {
        guard let list = dockListElement() else {
            return .empty
        }

        var tiles: [DockTile] = []
        for item in AX.elements(list, AXAttr.children) {
            let subrole = AX.string(item, AXAttr.subrole) ?? ""
            guard Self.isApplicationDockItem(subrole: subrole),
                  let tile = makeTile(from: item) else { continue }
            tiles.append(tile)
        }
        return DockSnapshot(tiles: tiles, capturedAt: CACurrentMediaTime())
    }

    /// Mirrors DockDoor's proven approach: ask the Dock list which child is
    /// selected (hovered), then verify the pointer is actually inside that
    /// item's current frame. This tracks magnification and Dock autohide
    /// without maintaining a separate geometric model.
    func inspectApplicationTile(at point: CGPoint) -> DockInspectionResult {
        guard let list = dockListElement() else { return .unavailable }

        if let selected = AX.elements(list, AXAttr.selectedChildren).first {
            let subrole = AX.string(selected, AXAttr.subrole) ?? ""
            if Self.isApplicationDockItem(subrole: subrole),
               let tile = makeTile(from: selected) {
                if tile.frame.insetBy(dx: -Self.itemHoverSlop, dy: -Self.itemHoverSlop).contains(point) {
                    return .application(tile)
                }
            } else if let frame = AX.frame(selected),
                      frame.insetBy(dx: -Self.itemHoverSlop, dy: -Self.itemHoverSlop).contains(point) {
                return .notApplication
            }
        }

        return inspectByPosition(point: point)
    }

    private func inspectByPosition(point: CGPoint) -> DockInspectionResult {
        guard let dock = dockElement() else { return .unavailable }

        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            dock,
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard error == .success, var element = hit else {
            Log.debug("Dock position hit-test failed at \(point.debugDescription): \(error.rawValue)")
            return .unavailable
        }

        for _ in 0..<4 {
            let subrole = AX.string(element, AXAttr.subrole) ?? ""
            if Self.isApplicationDockItem(subrole: subrole) {
                if let tile = makeTile(from: element) {
                    return .application(tile)
                }
                return .notApplication
            }

            guard let parent = AX.element(element, AXAttr.parent),
                  !CFEqual(parent, element) else {
                break
            }
            element = parent
        }

        return .notApplication
    }

    private func makeTile(from element: AXUIElement) -> DockTile? {
        guard let frame = AX.frame(element), frame.width > 1, frame.height > 1 else {
            return nil
        }

        let applicationURL = AX.url(element, AXAttr.url)
        let bundleIdentifier = applicationURL.flatMap { Bundle(url: $0)?.bundleIdentifier }

        var title = (AX.string(element, AXAttr.title) ??
                     AX.string(element, AXAttr.description) ??
                     "").trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty, let applicationURL {
            title = applicationURL.deletingPathExtension().lastPathComponent
        }
        guard !title.isEmpty else { return nil }

        let running = AX.bool(element, AXAttr.isApplicationRunning) ??
            RunningApplicationResolver.isRunning(titled: title)

        return DockTile(
            title: title,
            frame: frame,
            isRunning: running,
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL
        )
    }

    static func isApplicationDockItem(subrole: String) -> Bool {
        subrole == applicationDockSubrole ||
            (subrole.hasSuffix("DockItem") && subrole.contains("Application"))
    }

    private func dockListElement() -> AXUIElement? {
        guard let dock = dockElement() else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let cachedDockList {
            var roleValue: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                cachedDockList,
                kAXRoleAttribute as CFString,
                &roleValue
            )
            if error == .success {
                return cachedDockList
            }
            self.cachedDockList = nil
        }

        let list = AX.elements(dock, AXAttr.children).first {
            (AX.string($0, AXAttr.role) ?? "") == (kAXListRole as String)
        }
        cachedDockList = list
        return list
    }

    private func dockElement() -> AXUIElement? {
        guard let dockApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock")
            .first else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }

        if cachedDockPID != dockApplication.processIdentifier || cachedDockElement == nil {
            let element = AXUIElementCreateApplication(dockApplication.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            cachedDockPID = dockApplication.processIdentifier
            cachedDockElement = element
            cachedDockList = nil
            Log.debug("Connected to Dock pid \(dockApplication.processIdentifier)")
        }

        return cachedDockElement
    }
}
