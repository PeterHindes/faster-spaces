import AppKit
import Foundation

/// Adapter between the current-Space `SwitchWindow` model and the ported New
/// Window Plz Metal overlay. The overlay owns the exact old switcher layout:
/// a centered card, app icons, window titles, selection outline and page slide.
final class WindowSwitcherOverlay {
    static let shared = WindowSwitcherOverlay()

    private let host = OverlayHost()
    private let snapshotService = WindowSnapshotService()
    private var safetyHide: DispatchWorkItem?
    private var didFail = false
    private var currentWindows: [SwitchWindow] = []
    private var showSnapshots = false
    private(set) var isShown = false

    private init() {
        snapshotService.onImage = { [weak self] windowID, image in
            self?.host.updateWindowSnapshot(windowID: windowID, image: image)
        }
    }

    /// Create the resident surface at launch so the first reveal is an alpha
    /// flip, not a window/Metal setup.
    func prepare() {
        host.prepare()
    }

    /// Warm the icon/title textures off the reveal path, as New Window Plz did
    /// when its catalog changed.
    func prepareWindowSwitcherCache(windows: [SwitchWindow]) {
        guard !windows.isEmpty else { return }
        host.prepareWindowSwitcherCache(windows: windows.map(AltTabWindow.init))
    }

    @discardableResult
    func show(
        windows: [SwitchWindow],
        selectedIndex: Int,
        showSnapshots: Bool = false
    ) -> Bool {
        guard !windows.isEmpty else { return false }
        if !host.isReady, !didFail {
            host.prepare()
        }
        if !host.isReady {
            didFail = true
            return false
        }
        currentWindows = windows
        self.showSnapshots = showSnapshots
        let alt = windows.map(AltTabWindow.init)
        let shown = host.showWindowSwitcher(
            windows: alt,
            selectedIndex: min(max(selectedIndex, 0), alt.count - 1),
            showSnapshots: showSnapshots
        )
        isShown = shown
        if shown {
            requestSnapshots()
            armSafety()
        }
        return shown
    }

    func updateSelection(selectedIndex: Int, previousIndex: Int?) {
        guard isShown else { return }
        host.updateWindowSwitcherSelection(selectedIndex, previousIndex: previousIndex)
        requestSnapshots()
        armSafety()
    }

    func update(windows: [SwitchWindow], selectedIndex: Int) {
        guard isShown, !windows.isEmpty else { return }
        currentWindows = windows
        host.updateWindowSwitcher(
            windows: windows.map(AltTabWindow.init),
            selectedIndex: min(max(selectedIndex, 0), windows.count - 1),
            showSnapshots: showSnapshots
        )
        requestSnapshots()
        armSafety()
    }

    func writePreview(
        to url: URL,
        windows: [SwitchWindow],
        selectedIndex: Int,
        showSnapshots: Bool = false
    ) {
        host.writeSwitcherPreview(
            to: url,
            windows: windows.map(AltTabWindow.init),
            selectedIndex: selectedIndex,
            showSnapshots: showSnapshots
        )
    }

    func hide() {
        safetyHide?.cancel()
        safetyHide = nil
        isShown = false
        host.hide()
    }

    private func requestSnapshots() {
        guard showSnapshots, ScreenCapturePermission.isGranted, !currentWindows.isEmpty else {
            return
        }
        for window in currentWindows {
            snapshotService.request(windowID: window.windowID)
        }
    }

    private func armSafety() {
        safetyHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        safetyHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }
}

extension AltTabWindow {
    init(_ window: SwitchWindow) {
        self.init(
            windowID: window.windowID,
            pid: window.pid,
            bundleIdentifier: window.bundleIdentifier,
            appName: window.appName,
            windowTitle: window.windowTitle,
            isHidden: window.isHidden
        )
    }
}
