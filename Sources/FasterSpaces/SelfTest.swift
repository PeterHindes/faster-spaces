import AppKit
import Foundation

/// Lightweight self-test for the pure, testable parts of the app. It runs
/// before NSApplication starts, so it works in restricted environments and in
/// CI without a window server session.
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func run() -> Never {
        print("\(AppInfo.name) \(AppInfo.version) self-test")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")

        testFingerAssignment()
        testSwipeInitial()
        testSwipeRetrace()
        testWindowSelection()
        testWindowCatalog()
        testDockClickPolicy()
        testVersionComparison()
        testMenuBarSpaceStrip()
        testSettingsLimits()

        print("")
        print("RESULT: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    private static func check(_ condition: Bool, _ name: String, _ detail: String = "") {
        if condition {
            passed += 1
            print("PASS \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failed += 1
            print("FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    private static func testFingerAssignment() {
        let settings = SettingsStore.shared
        let spaces = settings.spacesFingers
        let windows = settings.windowFingers
        check(spaces == 3 || spaces == 4, "Spaces finger count is 3 or 4", "\(spaces)")
        check(windows == 3 || windows == 4, "Window finger count is 3 or 4", "\(windows)")
        check(spaces != windows, "Window swipe uses the non-primary count", "\(spaces) / \(windows)")
        print("     \(FingerConfiguration.autoSourceDescription)")
    }

    private static func testSwipeInitial() {
        let first = SwipeMath.initial(progress: 0.10, threshold: 0.20, maxSteps: 4, invert: false)
        check(first.direction == 1, "Rightward progress starts rightward")
        check(first.steps == 1, "One threshold crosses one step")
        check(abs(first.anchor + 0.10) < 0.0001, "Anchor sits on the threshold grid")

        let long = SwipeMath.initial(progress: 0.45, threshold: 0.20, maxSteps: 4, invert: false)
        check(long.direction == 1 && long.steps == 2, "A long swipe crosses two steps", "\(long.steps)")

        let capped = SwipeMath.initial(progress: 2.0, threshold: 0.20, maxSteps: 4, invert: false)
        check(capped.steps == 4, "Step count is capped", "\(capped.steps)")

        let inverted = SwipeMath.initial(progress: 0.10, threshold: 0.20, maxSteps: 4, invert: true)
        check(inverted.direction == -1, "Invert reverses the direction")
    }

    private static func testSwipeRetrace() {
        let initial = SwipeMath.initial(progress: 0.45, threshold: 0.20, maxSteps: 4, invert: false)
        let net = initial.direction * initial.steps // 2
        // The first switch anchors on the threshold grid: with a 0.45 start
        // and a 0.20 step, the grid is 0.05 / 0.25 / 0.45. Moving back past
        // 0.25 retraces exactly one step; moving below 0.05 reaches zero.
        let backward = SwipeMath.desired(
            progress: 0.26,
            anchor: initial.anchor,
            threshold: 0.20,
            maxSteps: 4,
            invert: false
        )
        check(backward == 1, "Moving back retraces one step", "\(backward)")
        check(abs(net - backward) == 1, "Retrace delta is one step")

        let beyond = SwipeMath.desired(
            progress: 0.05,
            anchor: initial.anchor,
            threshold: 0.20,
            maxSteps: 4,
            invert: false
        )
        check(beyond == 0, "Moving further back reaches the origin", "\(beyond)")
    }

    private static func testWindowSelection() {
        check(WindowSelection.initial(count: 5, reverse: false) == 1, "Option-Tab starts on the next window")
        check(WindowSelection.initial(count: 5, reverse: true) == 4, "Reverse Option-Tab starts at the back")
        check(WindowSelection.advance(index: 0, count: 5, direction: 1) == 1, "Forward advances one window")
        check(WindowSelection.advance(index: 4, count: 5, direction: 1) == 0, "Forward wraps at the back")
        check(WindowSelection.advance(index: 0, count: 5, direction: -1) == 4, "Backward wraps to the back")
        check(WindowSelection.advance(index: 0, count: 5, direction: 1, steps: 7) == 2, "Multi-step advance wraps")
        check(WindowSelection.advance(index: 3, count: 1, direction: 1) == 0, "Single-window list is stable")
    }

    private static func testWindowCatalog() {
        let windows = CurrentSpaceWindows.snapshot()
        check(!windows.contains(where: { $0.pid == ProcessInfo.processInfo.processIdentifier }),
              "Window catalog excludes this app")
        check(windows.allSatisfy { $0.windowID != 0 }, "Window IDs are valid")
        print("     \(windows.count) current-Space window(s)")
        for window in windows.prefix(5) {
            print("     · \(window.appName): \(window.shortTitle)")
        }
    }

    private static func testDockClickPolicy() {
        let policy = DockClickPolicy()
        let running = DockTile(title: "Test", frame: .zero, isRunning: true)
        let stopped = DockTile(title: "Test", frame: .zero, isRunning: false)

        func decide(_ modifiers: CGEventFlags,
                    _ configured: DockClickAction?,
                    tile: DockTile? = running) -> DockClickDecision {
            policy.decide(
                isEnabled: true,
                tile: tile,
                modifiers: modifiers,
                configuredAction: configured
            )
        }

        check(decide([], .newWindow) == .action(.newWindow), "Plain click runs New Window")
        check(decide([], .moveHere) == .action(.moveHere), "Plain click runs Bring Here")
        check(decide([], nil) == .passThrough(.notConfigured), "Plain click on an unlisted app passes through")
        check(decide([], .unchanged) == .passThrough(.noChanges), "Plain click on None passes through")

        check(decide([.maskShift], .moveHere) == .action(.newWindow), "Shift overrides Bring Here with New Window")
        check(decide([.maskShift], .newWindow) == .passThroughAsRegularClick, "Shift toggles off configured New Window and passes a regular click")
        check(decide([.maskControl], .newWindow) == .action(.moveHere), "Control overrides New Window with Bring Here")
        check(decide([.maskControl], .moveHere) == .passThroughAsRegularClick, "Control toggles off configured Bring Here and passes a regular click")

        check(decide([.maskShift], nil) == .action(.newWindow), "Shift works on an unlisted app")
        check(decide([.maskControl], nil) == .action(.moveHere), "Control works on an unlisted app")
        check(decide([.maskShift], .unchanged) == .action(.newWindow), "Shift works on an app set to None")
        check(decide([.maskControl], .unchanged) == .action(.moveHere), "Control works on an app set to None")
        check(decide([.maskShift, .maskControl], .newWindow) == .action(.moveHere), "Control wins when both are held")
        check(decide([.maskShift, .maskControl], .moveHere) == .passThroughAsRegularClick, "Control toggles off Bring Here when both are held")

        check(decide([.maskCommand], .newWindow) == .passThrough(.modifierKey), "Command-click stays native")
        check(decide([.maskAlternate], .moveHere) == .passThrough(.modifierKey), "Option-click stays native")
        check(decide([.maskShift], .newWindow, tile: stopped) == .passThrough(.applicationNotRunning), "Non-running apps stay native")
        check(decide([.maskShift], .newWindow, tile: nil) == .passThrough(.noTile), "Non-Dock clicks stay native")
        check(policy.decide(isEnabled: false, tile: running, modifiers: [], configuredAction: .newWindow) == .passThrough(.disabled), "Disabled policy passes through")
    }

    private static func testVersionComparison() {
        check(UpdateVersion.isNewer("2.1.3", than: "2.1.2"), "Newer patch version is detected")
        check(UpdateVersion.isNewer("v2.2.0", than: "2.1.9"), "Newer minor version is detected")
        check(!UpdateVersion.isNewer("2.1.2", than: "2.1.2"), "Same version is not newer")
        check(!UpdateVersion.isNewer("2.1.1", than: "2.1.2"), "Older version is not newer")
        check(!UpdateVersion.isNewer("2.1.3", than: "dev"), "Dev builds are never prompted")
        check(UpdateVersion.isNewer("3.0", than: "2.9.9"), "Missing components are treated as zero")
    }

    private static func testMenuBarSpaceStrip() {
        check(MenuBarSpaceStrip.index(atX: 0, width: 60, count: 3) == 0, "Menu strip maps the left edge to the first Space")
        check(MenuBarSpaceStrip.index(atX: 30, width: 60, count: 3) == 1, "Menu strip maps the middle to the second Space")
        check(MenuBarSpaceStrip.index(atX: 59, width: 60, count: 3) == 2, "Menu strip maps the right edge to the last Space")
        check(MenuBarSpaceStrip.index(atX: 10, width: 0, count: 3) == 0, "Menu strip handles a zero-width button")
        check(MenuBarSpaceStrip.index(atX: 10, width: 60, count: 1) == 0, "Menu strip handles a single Space")
    }

    private static func testSettingsLimits() {
        let settings = SettingsStore.shared
        check((1...8).contains(settings.maxSpaces), "Spaces step cap is clamped")
        check((1...10).contains(settings.maxWindowsPerSwipe), "Window step cap is clamped")
        check(settings.effectiveWindowSwipeDistance >= 0.04, "Window distance has a floor")
        check(settings.effectiveWindowVisibleCount >= 3, "Window strip has a minimum width")
    }
}
