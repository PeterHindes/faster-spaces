import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Model

/// One on-screen window in the active Space. This is the unit the Option-Tab
/// switcher and the non-primary swipe both move through.
struct SwitchWindow: Equatable, Identifiable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let isHidden: Bool
    let frame: CGRect

    var id: CGWindowID { windowID }

    var displayTitle: String {
        windowTitle.isEmpty ? appName : windowTitle
    }

    var shortTitle: String {
        if displayTitle.count <= 30 { return displayTitle }
        return String(displayTitle.prefix(29)) + "…"
    }

    var shortAppName: String {
        if appName.count <= 18 { return appName }
        return String(appName.prefix(17)) + "…"
    }
}

// MARK: - Current-Space catalog

/// `CGWindowList` with `.optionOnScreenOnly` returns exactly the windows
/// composited in the active Space(s): other-Space and minimized windows are
/// excluded, which is the scope of the switcher.
enum CurrentSpaceWindows {
    static func snapshot() -> [SwitchWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleIdentifier = Bundle.main.bundleIdentifier

        // NSWorkspace can briefly expose two entries with the same PID while an
        // app launches or exits. Last value wins; never trap on the duplicate.
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appsByPID[app.processIdentifier] = app
        }

        var seen = Set<CGWindowID>()
        var result: [SwitchWindow] = []

        for raw in rawList {
            guard let layer = raw[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidValue = raw[kCGWindowOwnerPID as String] as? Int,
                  let windowNumber = raw[kCGWindowNumber as String] as? Int,
                  let alpha = raw[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let boundsDictionary = raw[kCGWindowBounds as String] as? [String: Any],
                  let width = boundsDictionary["Width"] as? Double,
                  let height = boundsDictionary["Height"] as? Double,
                  width >= 60, height >= 60 else {
                continue
            }

            let pid = pid_t(pidValue)
            guard pid != ownPID,
                  let app = appsByPID[pid],
                  app.activationPolicy == .regular,
                  app.bundleIdentifier != ownBundleIdentifier,
                  let appName = app.localizedName,
                  !appName.isEmpty else {
                continue
            }

            if let isOnscreen = raw[kCGWindowIsOnscreen as String] as? Bool, !isOnscreen {
                continue
            }

            let windowID = CGWindowID(windowNumber)
            guard !seen.contains(windowID) else { continue }
            seen.insert(windowID)

            let title = (raw[kCGWindowName as String] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let bounds = CGRect(
                x: boundsDictionary["X"] as? Double ?? 0,
                y: boundsDictionary["Y"] as? Double ?? 0,
                width: width,
                height: height
            )

            result.append(SwitchWindow(
                windowID: windowID,
                pid: pid,
                bundleIdentifier: app.bundleIdentifier ?? "",
                appName: appName,
                windowTitle: title,
                isHidden: app.isHidden,
                frame: bounds
            ))
        }

        return result
    }
}

// MARK: - Catalog cache

/// Window enumeration is cheap but not free. The switcher must open on the
/// next display refresh, so the interactive paths read this cache and a
/// background queue keeps it fresh on app/Space/screen changes.
final class WindowCatalogService {
    static let shared = WindowCatalogService()

    private let queue = DispatchQueue(
        label: "com.fasterplz.fasterspaces.window-catalog",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var cached: [SwitchWindow] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isScanning = false
    private var scanAgain = false

    private init() {}

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        installObservers()
        startTimer()
        refresh()
        Log.info("Window catalog started")
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    /// Cached windows, front-to-back. Empty only before the first scan.
    var windows: [SwitchWindow] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// The interactive path uses the cache; the synchronous scan exists only
    /// for the first invocation after launch.
    func windowsForImmediateUse() -> [SwitchWindow] {
        let current = windows
        if !current.isEmpty { return current }
        let scanned = CurrentSpaceWindows.snapshot()
        setCached(scanned)
        return scanned
    }

    func refresh() {
        guard isRunning else { return }
        if isScanning {
            scanAgain = true
            return
        }
        isScanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let scanned = CurrentSpaceWindows.snapshot()
            DispatchQueue.main.async {
                self.isScanning = false
                self.setCached(scanned)
                if self.scanAgain {
                    self.scanAgain = false
                    self.refresh()
                }
            }
        }
    }

    private func setCached(_ windows: [SwitchWindow]) {
        lock.lock()
        let changed = cached != windows
        cached = windows
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: .fasterSpacesWindowCatalogDidChange, object: nil)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
        let screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        observers.append(screenToken)
    }
}

// MARK: - Exact-window activation

@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

private struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID")
private func GetProcessForPID(
    _ pid: pid_t,
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus

/// Focuses a specific window instead of raising the app's whole window group.
/// The SkyLight path is the same technique DockDoor/New Window Plz use, with a
/// standard app activation only as a last resort.
enum WindowActivator {
    private enum SkyLight {
        typealias SetFrontProcess = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> CGError
        typealias PostEventRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> CGError

        private static let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        private static let setFrontProcess: SetFrontProcess? = {
            guard let handle, let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else {
                return nil
            }
            return unsafeBitCast(symbol, to: SetFrontProcess.self)
        }()
        private static let postEventRecord: PostEventRecord? = {
            guard let handle, let symbol = dlsym(handle, "SLPSPostEventRecordTo") else {
                return nil
            }
            return unsafeBitCast(symbol, to: PostEventRecord.self)
        }()

        static func focus(windowID: CGWindowID, pid: pid_t) -> Bool {
            guard let setFrontProcess, let postEventRecord else { return false }

            var psn = ProcessSerialNumber()
            guard GetProcessForPID(pid, &psn) == 0 else { return false }

            let frontResult = withUnsafeMutablePointer(to: &psn) { pointer in
                setFrontProcess(
                    UnsafeMutableRawPointer(pointer),
                    windowID,
                    0x200 // SLPSMode.userGenerated
                )
            }
            guard frontResult == .success else { return false }

            var bytes = [UInt8](repeating: 0, count: 0x100)
            bytes[0x04] = 0xF8
            bytes[0x3A] = 0x10
            var wideWindowID = UInt32(windowID)
            memcpy(&bytes[0x3C], &wideWindowID, MemoryLayout<UInt32>.size)
            var point = CGPoint(x: -1, y: -1)
            memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)
            bytes[0x08] = 0x01
            _ = withUnsafeMutablePointer(to: &psn) {
                postEventRecord(UnsafeMutableRawPointer($0), &bytes)
            }
            bytes[0x08] = 0x02
            _ = withUnsafeMutablePointer(to: &psn) {
                postEventRecord(UnsafeMutableRawPointer($0), &bytes)
            }
            return true
        }
    }

    private static func windowElement(windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        for element in AX.elements(appElement, kAXWindowsAttribute as String) {
            var candidate: CGWindowID = 0
            if AXUIElementGetWindow(element, &candidate) == .success, candidate == windowID {
                return element
            }
        }
        return nil
    }

    /// Focus a window by ID (used by Bring Here after a window-space move).
    static func activate(windowID: CGWindowID, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return
        }
        let preciseFocus = SkyLight.focus(windowID: windowID, pid: pid)
        if !preciseFocus && app.isHidden {
            app.unhide()
        }
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.03) {
            var raised = false
            if let element = windowElement(windowID: windowID, pid: pid) {
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
            }
            if !preciseFocus && !raised {
                DispatchQueue.main.async {
                    if app.isHidden { app.unhide() }
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }
    }

    /// Clamp and center a window on a screen after moving it here.
    static func center(windowID: CGWindowID, pid: pid_t, on screen: NSScreen?) {
        guard let screen,
              let element = windowElement(windowID: windowID, pid: pid) else { return }

        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let sizeValue,
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return
        }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return }

        let visible = screen.visibleFrame
        var newSize = CGSize(
            width: max(200, min(size.width, visible.width - 40)),
            height: max(150, min(size.height, visible.height - 40))
        )
        if let newSizeValue = AXValueCreate(.cgSize, &newSize) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, newSizeValue)
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? visible.height
        var point = CGPoint(
            x: visible.midX - newSize.width * 0.5,
            y: primaryHeight - visible.midY - newSize.height * 0.5
        )
        if let positionValue = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }
    }

    static func activate(_ window: SwitchWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              !app.isTerminated else {
            return
        }

        let preciseFocus = SkyLight.focus(windowID: window.windowID, pid: window.pid)
        if !preciseFocus && app.isHidden {
            app.unhide()
        }

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.02) {
            let raised = raiseAXWindow(window)
            if !preciseFocus && !raised {
                DispatchQueue.main.async {
                    if app.isHidden { app.unhide() }
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }
    }

    @discardableResult
    private static func raiseAXWindow(_ window: SwitchWindow) -> Bool {
        let appElement = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let axWindows = AX.elements(appElement, kAXWindowsAttribute as String)

        var exactMatch: AXUIElement?
        var titleMatch: AXUIElement?
        for axWindow in axWindows {
            var candidateID: CGWindowID = 0
            if AXUIElementGetWindow(axWindow, &candidateID) == .success,
               candidateID == window.windowID {
                exactMatch = axWindow
                break
            }
            if titleMatch == nil,
               !window.windowTitle.isEmpty,
               AX.string(axWindow, kAXTitleAttribute as String) == window.windowTitle {
                titleMatch = axWindow
            }
        }

        guard let target = exactMatch ?? titleMatch else { return false }
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }
}

extension Notification.Name {
    static let fasterSpacesWindowCatalogDidChange = Notification.Name("FasterSpacesWindowCatalogDidChange")
}
