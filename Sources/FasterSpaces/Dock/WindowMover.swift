import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("WSMoveBridgedIsAvailable")
private func windowSpaceMoveAvailable() -> Bool

@_silgen_name("WSMoveBridged")
private func windowSpaceMove(_ windowID: UInt32, _ spaceID: UInt64) -> Bool

@_silgen_name("_AXUIElementGetWindow")
private func windowIDForAXElement(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("SLSMainConnectionID")
private func skyLightMainConnection() -> Int32

@_silgen_name("SLSCopySpacesForWindows")
private func copySpacesForWindow(
    _ connection: Int32,
    _ mask: Int32,
    _ windows: CFArray
) -> Unmanaged<CFArray>?

final class WindowMover {
    static var isAvailable: Bool {
        windowSpaceMoveAvailable()
    }

    /// Moves the app's focused (or first non-minimized) window to the active
    /// Space of the display under the mouse, raises it, and centers it there.
    func moveExistingWindowToCurrentScreen(_ app: NSRunningApplication) -> Bool {
        guard Self.isAvailable,
              !app.isTerminated,
              var target = targetWindow(for: app) else {
            return false
        }

        // A native full-screen window owns a dedicated Space and cannot be
        // moved as a normal window. Leave full screen first, wait for the
        // window to return to a desktop, then move that window here.
        if let element = target.element, isFullScreen(element) {
            guard exitFullScreen(element) else {
                Log.error("Could not leave full screen for window \(target.id)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.25)
            guard let refreshed = targetWindow(for: app) else { return false }
            target = refreshed
        }

        let screen = NSScreen.underCursor
        guard let snapshot = SpaceSwitcher.shared.snapshot(),
              let targetSpaceID = snapshot.display.currentSpace?.id else {
            return false
        }

        guard windowSpaceMove(UInt32(target.id), targetSpaceID) else {
            Log.error("Window-space move backend rejected window \(target.id)")
            return false
        }

        guard confirmMove(windowID: target.id, to: targetSpaceID) else {
            Log.error("Window-space move did not confirm for window \(target.id)")
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            WindowActivator.activate(windowID: target.id, pid: app.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                WindowActivator.center(
                    windowID: target.id,
                    pid: app.processIdentifier,
                    on: screen ?? NSScreen.main
                )
            }
        }
        return true
    }

    private struct TargetWindow {
        let id: CGWindowID
        let element: AXUIElement?
    }

    func activateExistingWindow(of app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, let target = targetWindow(for: app) else { return false }
        WindowActivator.activate(windowID: target.id, pid: app.processIdentifier)
        return true
    }

    private func isFullScreen(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXFullScreen" as CFString,
            &value
        ) == .success,
              let number = value as? NSNumber else {
            return false
        }
        return number.boolValue
    }

    private func exitFullScreen(_ element: AXUIElement) -> Bool {
        guard isFullScreen(element) else { return true }
        let result = AXUIElementSetAttributeValue(
            element,
            "AXFullScreen" as CFString,
            kCFBooleanFalse
        )
        guard result == .success else {
            Log.error("AXFullScreen exit failed: \(result.rawValue)")
            return false
        }

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if !isFullScreen(element) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func targetWindow(for app: NSRunningApplication) -> TargetWindow? {
        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)

        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        ) == .success,
           let focusedValue,
           CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            var id: CGWindowID = 0
            if windowIDForAXElement(focused, &id) == .success, id != 0 {
                return TargetWindow(id: id, element: focused)
            }
        }

        let axWindows = AX.elements(applicationElement, kAXWindowsAttribute as String)
        for window in axWindows {
            if AX.bool(window, kAXMinimizedAttribute as String) == true {
                continue
            }
            var id: CGWindowID = 0
            if windowIDForAXElement(window, &id) == .success, id != 0 {
                return TargetWindow(id: id, element: window)
            }
        }

        // Accessibility may not expose a window on another Space. Fall back to
        // the WindowServer list, which includes off-screen windows.
        let allWindows = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for raw in allWindows {
            guard let pid = raw[kCGWindowOwnerPID as String] as? Int,
                  pid == Int(app.processIdentifier),
                  let layer = raw[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = raw[kCGWindowNumber as String] as? Int,
                  let boundsDictionary = raw[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsDictionary["Width"] as? Double,
                  let height = boundsDictionary["Height"] as? Double,
                  width > 60, height > 60 else {
                continue
            }
            return TargetWindow(id: CGWindowID(windowNumber), element: nil)
        }
        return nil
    }

    private func confirmMove(windowID: CGWindowID, to spaceID: UInt64) -> Bool {
        let connection = skyLightMainConnection()
        guard connection != 0 else { return false }
        let deadline = Date().addingTimeInterval(0.65)
        while Date() < deadline {
            if let result = copySpacesForWindow(
                connection,
                0x7,
                [Int(windowID)] as CFArray
            ) {
                let spaces = result.takeRetainedValue() as? [Int] ?? []
                if spaces.contains(Int(spaceID)) {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return false
    }

}
