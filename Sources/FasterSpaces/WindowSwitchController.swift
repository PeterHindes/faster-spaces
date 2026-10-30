import AppKit
import CoreGraphics
import Foundation
import QuartzCore

/// Owns the current-Space window selection for both triggers:
///
///   - the non-primary horizontal swipe (a physical gesture), and
///   - Option-Tab (the New Window Plz switcher).
///
/// A swipe activates each window immediately as its threshold is crossed, so
/// it feels like the instant Spaces gesture. Option-Tab keeps a modal selection
/// and commits on Option release or Return.
final class WindowSwitchController {
    static let shared = WindowSwitchController()

    private enum Kind {
        case swipe
        case optionTab
    }

    private struct Session {
        var kind: Kind
        var windows: [SwitchWindow]
        var index: Int
        var hasStepped: Bool
        var startedAt: Date
    }

    private var session: Session?
    private var pendingHide: DispatchWorkItem?
    private var optionSafety: DispatchWorkItem?
    private var lastActivatedWindow: SwitchWindow?
    private var lastActivatedAt: CFTimeInterval = 0

    private init() {}

    var isOptionTabActive: Bool {
        session?.kind == .optionTab
    }

    var isSwipeActive: Bool {
        session?.kind == .swipe
    }

    var currentWindowCount: Int {
        session?.windows.count ?? 0
    }

    // MARK: - Swipe

    @discardableResult
    func beginSwipe() -> Bool {
        guard SettingsStore.shared.windowSwipeEnabled else { return false }
        if session?.kind == .swipe { session = nil }
        guard session == nil else { return true }

        var windows = WindowCatalogService.shared.windowsForImmediateUse()
        if windows.isEmpty {
            windows = CurrentSpaceWindows.snapshot()
        }
        guard !windows.isEmpty else {
            Log.debug("Window swipe: no current-Space windows")
            return false
        }

        session = Session(
            kind: .swipe,
            windows: windows,
            index: 0,
            hasStepped: false,
            startedAt: Date()
        )
        pendingHide?.cancel()
        pendingHide = nil
        Log.debug("Window swipe began with \(windows.count) window(s)")
        return true
    }

    /// Move the selection by `steps` windows in `direction` (+1 = next window
    /// behind the current one). Returns the number of windows actually crossed.
    @discardableResult
    func swipeStep(direction: Int, steps: Int) -> Int {
        guard var session, session.kind == .swipe,
              direction != 0, !session.windows.isEmpty else {
            return 0
        }
        let count = session.windows.count
        guard count > 1 else { return 0 }

        let previousIndex = session.index
        let raiseOnRelease = SettingsStore.shared.windowSwipeRaiseOnRelease
        let requested = min(max(steps, 1), SettingsStore.shared.maxWindowsPerSwipe)
        var crossed = 0
        for _ in 0..<requested {
            let next = WindowSelection.advance(
                index: session.index,
                count: count,
                direction: direction
            )
            guard next != session.index else { break }
            session.index = next
            crossed += 1
            if !raiseOnRelease {
                activate(session.windows[next], reason: "window swipe")
            }
        }

        guard crossed > 0 else {
            self.session = session
            return 0
        }

        session.hasStepped = true
        self.session = session
        showHUD(for: session, previousIndex: previousIndex)
        if raiseOnRelease, crossed > 0, session.windows.indices.contains(session.index) {
            Log.debug("Window swipe selected \(session.windows[session.index].appName); raise on release")
        }
        if SettingsStore.shared.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        return crossed
    }

    func endSwipe() {
        guard let session, session.kind == .swipe else { return }
        guard session.hasStepped else {
            // A four-finger touch that never crossed a threshold should not
            // flash a HUD or activate anything.
            self.session = nil
            return
        }
        if SettingsStore.shared.windowSwipeRaiseOnRelease,
           session.index != 0,
           session.windows.indices.contains(session.index) {
            activate(session.windows[session.index], reason: "window swipe release")
        }
        hideHUD(after: 0.12)
        self.session = nil
        WindowCatalogService.shared.refresh()
    }

    // MARK: - Option-Tab

    @discardableResult
    func beginOptionTab(reverse: Bool) -> Bool {
        guard SettingsStore.shared.windowSwitcherEnabled else { return false }
        if session?.kind == .swipe {
            // A lost gesture-end event must not block the keyboard switcher.
            endSwipe()
        }
        guard session == nil else { return true }

        var windows = WindowCatalogService.shared.windowsForImmediateUse()
        guard !windows.isEmpty else {
            Log.debug("Option-Tab: no current-Space windows")
            return false
        }
        // New Window Plz promotes the window it just activated to index 0 so
        // the next Option-Tab starts on the window behind it, even before the
        // WindowServer reorders its list.
        if let recent = lastActivatedWindow,
           CACurrentMediaTime() - lastActivatedAt < 1.25,
           let recentIndex = windows.firstIndex(where: { $0.windowID == recent.windowID }),
           recentIndex != 0 {
            let window = windows.remove(at: recentIndex)
            windows.insert(window, at: 0)
        }
        guard windows.count > 1 else {
            // One window: the switcher has nothing to choose; leave the app alone.
            Log.debug("Option-Tab: only one window")
            return false
        }

        var index = WindowSelection.initial(count: windows.count, reverse: reverse)
        if let recent = lastActivatedWindow,
           CACurrentMediaTime() - lastActivatedAt < 1.25,
           let recentIndex = windows.firstIndex(where: { $0.windowID == recent.windowID }),
           recentIndex == index,
           windows.count > 1 {
            index = WindowSelection.advance(
                index: index,
                count: windows.count,
                direction: reverse ? -1 : 1
            )
        }

        session = Session(
            kind: .optionTab,
            windows: windows,
            index: index,
            hasStepped: true,
            startedAt: Date()
        )
        pendingHide?.cancel()
        pendingHide = nil
        showHUD(for: session!, previousIndex: nil)
        armOptionSafety()
        Log.debug("Option-Tab opened with \(windows.count) window(s)")
        return true
    }

    func advanceOptionTab(reverse: Bool) {
        guard var session, session.kind == .optionTab, session.windows.count > 1 else { return }
        let count = session.windows.count
        let previousIndex = session.index
        session.index = WindowSelection.advance(
            index: session.index,
            count: count,
            direction: reverse ? -1 : 1
        )
        session.hasStepped = true
        self.session = session
        showHUD(for: session, previousIndex: previousIndex)
        armOptionSafety()
    }

    func commitOptionTab() {
        guard let session, session.kind == .optionTab,
              session.windows.indices.contains(session.index) else {
            cancelOptionTab()
            return
        }
        let selected = session.windows[session.index]
        self.session = nil
        optionSafety?.cancel()
        optionSafety = nil
        hideHUDImmediately()
        activate(selected, reason: "Option-Tab")
    }

    func cancelOptionTab() {
        guard let session, session.kind == .optionTab else { return }
        self.session = nil
        optionSafety?.cancel()
        optionSafety = nil
        hideHUDImmediately()
    }

    private func hideHUDImmediately() {
        pendingHide?.cancel()
        pendingHide = nil
        WindowSwitcherOverlay.shared.hide()
        WindowSwitchHUD.shared.hide()
    }

    /// A modal switcher that somehow survives an Option-release event must not
    /// wedge the keyboard forever. Every advance re-arms this.
    private func armOptionSafety() {
        optionSafety?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.cancelOptionTab()
        }
        optionSafety = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: work)
    }

    // MARK: - Preview / menu / URL

    /// Show the window strip without activating anything. Used by the
    /// diagnostics window and `fasterspaces://hud`.
    func previewHUD() {
        let windows = WindowCatalogService.shared.windowsForImmediateUse()
        guard !windows.isEmpty, let screen = NSScreen.underCursor else {
            Log.info("Window HUD preview skipped: no windows")
            return
        }
        let settings = SettingsStore.shared
        if settings.windowSwipeUIStyle == 1 {
            let snapshots = settings.windowSnapshotsEnabled
                && ScreenCaptureStatusModel.shared.isGranted
            if WindowSwitcherOverlay.shared.show(
                windows: windows,
                selectedIndex: 0,
                showSnapshots: snapshots
            ) {
                return
            }
        }
        WindowSwitchHUD.shared.show(windows: windows, selectedIndex: 0, on: screen)
        WindowSwitchHUD.shared.scheduleSafetyHide(after: 3.0)
    }

    /// Exercise the full swipe path (selection + activation + HUD) without a
    /// trackpad. Bound to `fasterspaces://window-swipe?steps=N`.
    func previewSwipe(steps: Int) {
        guard beginSwipe() else {
            Log.info("Window swipe preview skipped: no windows or feature off")
            return
        }
        _ = swipeStep(direction: 1, steps: max(steps, 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.endSwipe()
        }
    }

    @discardableResult
    func activateNextWindow(reverse: Bool) -> Bool {
        let windows = WindowCatalogService.shared.windowsForImmediateUse()
        guard windows.count > 1 else { return false }
        let currentIndex = windows.firstIndex(where: {
            $0.windowID == lastActivatedWindow?.windowID
        }) ?? 0
        let index = WindowSelection.advance(
            index: currentIndex,
            count: windows.count,
            direction: reverse ? -1 : 1
        )
        activate(windows[index], reason: "menu")
        return true
    }

    // MARK: - Previous Space

    func switchToPreviousSpace() {
        guard SettingsStore.shared.previousSpaceEnabled else { return }
        SpaceHistory.shared.switchToPreviousSpace()
    }

    // MARK: - Activation

    private func activate(_ window: SwitchWindow, reason: String) {
        SpaceHistory.shared.noteSpaceBeforeActivation()
        lastActivatedWindow = window
        lastActivatedAt = CACurrentMediaTime()
        WindowActivator.activate(window)
        Log.info("Activated window \(window.appName) — \(window.displayTitle) (\(reason))")
        NotificationCenter.default.post(name: .fasterSpacesDidActivateWindow, object: window)
    }

    // MARK: - HUD

    private func showHUD(for session: Session, previousIndex: Int?) {
        let settings = SettingsStore.shared
        guard settings.windowHUDEnabled else { return }

        // Option-Tab always uses the exact New Window Plz Metal switcher. The
        // swipe can use it too (Settings → Windows → Swipe display); the
        // default compact strip still feels like a Space gesture.
        let wantsFullSwitcher = session.kind == .optionTab
            || (session.kind == .swipe && settings.windowSwipeUIStyle == 1)
        if wantsFullSwitcher {
            if WindowSwitcherOverlay.shared.isShown {
                WindowSwitcherOverlay.shared.updateSelection(
                    selectedIndex: session.index,
                    previousIndex: previousIndex
                )
                return
            }
            let snapshots = settings.windowSnapshotsEnabled
                && ScreenCaptureStatusModel.shared.isGranted
            if WindowSwitcherOverlay.shared.show(
                windows: session.windows,
                selectedIndex: session.index,
                showSnapshots: snapshots
            ) {
                return
            }
        }

        guard let screen = NSScreen.underCursor else { return }
        if WindowSwitchHUD.shared.isVisible {
            WindowSwitchHUD.shared.update(windows: session.windows, selectedIndex: session.index)
        } else {
            WindowSwitchHUD.shared.show(
                windows: session.windows,
                selectedIndex: session.index,
                on: screen
            )
        }
        WindowSwitchHUD.shared.scheduleSafetyHide(after: 2.0)
    }

    private func hideHUD(after delay: TimeInterval) {
        pendingHide?.cancel()
        let work = DispatchWorkItem {
            WindowSwitcherOverlay.shared.hide()
            WindowSwitchHUD.shared.hide()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension Notification.Name {
    static let fasterSpacesDidActivateWindow = Notification.Name("FasterSpacesDidActivateWindow")
}
