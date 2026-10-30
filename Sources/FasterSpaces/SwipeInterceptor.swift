import AppKit
import Combine
import CoreGraphics
import Foundation

/// Owns the Accessibility permission lifecycle and keeps the event tap alive.
@MainActor
final class AccessibilityManager: ObservableObject {
    static let shared = AccessibilityManager()

    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var tapInstalled = false
    @Published private(set) var lastError: String?
    @Published private(set) var revoked = false

    private var pollTimer: Timer?

    private init() {}

    var statusText: String {
        if isTrusted && tapInstalled {
            return "Active"
        }
        if isTrusted {
            return "Finishing setup…"
        }
        return "Accessibility permission needed"
    }

    var statusDetail: String {
        if isTrusted && tapInstalled {
            return "Faster Spaces is listening for your Spaces and window gestures."
        }
        if isTrusted {
            return "Permission is granted. The event tap is starting."
        }
        return "macOS requires Accessibility access before an app can replace trackpad gestures and key mappings."
    }

    func start() {
        // The onboarding window owns the first prompt, so launch never steals
        // focus with a system dialog. Poll so a grant made later is picked up.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
        refresh()
    }

    func refresh() {
        let trustedNow = AXIsProcessTrusted()
        if isTrusted != trustedNow {
            isTrusted = trustedNow
            NotificationCenter.default.post(name: .fasterSpacesStatusDidChange, object: nil)
        }

        if trustedNow {
            if !SwipeInterceptor.shared.isInstalled {
                _ = SwipeInterceptor.shared.install()
            }
            tapInstalled = SwipeInterceptor.shared.isInstalled
            revoked = !tapInstalled
            if tapInstalled {
                lastError = nil
                revoked = false
            }
        } else {
            if SwipeInterceptor.shared.isInstalled {
                SwipeInterceptor.shared.uninstall()
            }
            tapInstalled = false
            revoked = false
        }
    }

    func requestPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        isTrusted = granted
        if !granted {
            openSystemSettings()
        }
    }

    func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func retryTap() {
        guard isTrusted else {
            requestPermissionPrompt()
            return
        }
        if SwipeInterceptor.shared.isInstalled {
            SwipeInterceptor.shared.uninstall()
        }
        _ = SwipeInterceptor.shared.install()
        refresh()
    }

    /// Reset the app's Accessibility TCC entry so a stale grant keyed to an old
    /// ad-hoc signature can be replaced. The app must be restarted afterward.
    func resetPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            Log.info("Reset Accessibility permission for \(bundleID); restart required")
            lastError = "Permission reset. Quit and reopen Faster Spaces, then grant access again."
        } catch {
            lastError = "Could not reset permission: \(error.localizedDescription)"
        }
    }
}

/// Intercepts the private DockControl gesture stream, suppresses the native
/// animated swipe, posts an instant replacement for Spaces, and routes the
/// non-primary finger count to the current-Space window switcher.
///
/// The same tap also owns the keyboard features (Option-Tab, previous Space,
/// Ctrl+arrow and the Superkey presets). Keeping one tap means the modifiers,
/// synthetic tags and gesture state have a single owner.
final class SwipeInterceptor {
    static let shared = SwipeInterceptor()

    private(set) var isInstalled = false
    private(set) var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var healthTimer: Timer?

    // Gesture state. The callback runs on the main run loop; these are only
    // touched there, so no locking is needed.
    private var tracking = false
    private var fired = false
    private var ignoreForFingerCount = false
    private var observedFingerCount = 0
    private var countRechecked = false
    private var netSteps = 0
    private var anchorProgress = 0.0
    private var startedAt = Date.distantPast
    private var lastEventAt = Date.distantPast

    // Window-swipe state. It is separate from the Spaces state so a reversal
    // retraces windows without touching the Space anchor.
    private var windowGesture = false
    private var windowFired = false
    private var windowNetSteps = 0
    private var windowAnchorProgress = 0.0

    // Option-Tab state.
    private var swallowedKeys = Set<CGKeyCode>()
    private var optionTabCancelled = false

    private init() {}

    // MARK: Install / remove

    @discardableResult
    func install() -> Bool {
        guard !isInstalled else { return true }

        let mask = (CGEventMask(1) << EventType.gesture)
            | (CGEventMask(1) << EventType.dockControl)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: swipeTapCallback,
            userInfo: nil
        ) else {
            Log.error("Could not create gesture event tap (Accessibility not granted?)")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isInstalled = true
        Log.info("Gesture event tap installed (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")

        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        if let healthTimer {
            RunLoop.main.add(healthTimer, forMode: .common)
        }
        NotificationCenter.default.post(name: .fasterSpacesStatusDidChange, object: nil)
        return true
    }

    func uninstall() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        isInstalled = false
        resetGesture()
        WindowSwitchController.shared.endSwipe()
        WindowSwitchController.shared.cancelOptionTab()
        KeyboardEnhancer.shared.reset()
        Log.info("Gesture event tap removed")
        NotificationCenter.default.post(name: .fasterSpacesStatusDidChange, object: nil)
    }

    private func checkHealth() {
        guard let tap else { return }
        if AXIsProcessTrusted(), !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            Log.info("Re-enabled gesture event tap")
        }
    }

    // MARK: Callback entry

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            Log.info("Event tap disabled by system; re-enabling")
            resetGesture()
            WindowSwitchController.shared.endSwipe()
            WindowSwitchController.shared.cancelOptionTab()
            KeyboardEnhancer.shared.reset()
            SpaceSwitcher.shared.noteGestureEnded()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return pass
        }

        let eventType = event.getIntegerValueField(Field.cgsEventType)
        let tag = event.getIntegerValueField(.eventSourceUserData)

        // Our own synthetic events (gesture and keyboard) must pass through.
        if tag == SpaceSwitcher.eventTag || tag == KeyboardEnhancer.eventTag {
            if Log.isDebugEnabled, tag == SpaceSwitcher.eventTag {
                Log.debug("Passing own synthetic event type=\(eventType) phase=\(event.getIntegerValueField(Field.gesturePhase))")
            }
            return pass
        }

        let settings = SettingsStore.shared
        guard settings.enabled else {
            if tracking { resetGesture() }
            return pass
        }

        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            return handleKeyboard(type: type, event: event)
        }

        if eventType == EventType.dockControl {
            let hidType = event.getIntegerValueField(Field.gestureHIDType)
            let motion = event.getIntegerValueField(Field.swipeMotion)
            guard hidType == HIDType.dockSwipe, motion == GestureMotion.horizontal else {
                return pass
            }
            return handleDockControl(event)
        }

        // Companion gesture events belonging to a Dock swipe we own.
        if eventType == EventType.gesture, tracking {
            return nil
        }
        return pass
    }

    // MARK: Keyboard

    private func handleKeyboard(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let settings = SettingsStore.shared

        // While Seek owns the keyboard, pass keys to its search field. Keep
        // processing modifier changes so a held Hyper key cannot get stuck.
        if SeekController.shared.isOpen {
            if type == .flagsChanged {
                _ = KeyboardEnhancer.shared.handleFlagsChanged(event)
            } else if type == .keyUp {
                // Balance a key that was forwarded with hyper flags before Seek
                // opened; ordinary typing in the panel is untouched.
                _ = KeyboardEnhancer.shared.handleKeyUp(event)
            }
            return pass
        }

        switch type {
        case .flagsChanged:
            if !event.flags.contains(.maskAlternate) {
                if WindowSwitchController.shared.isOptionTabActive {
                    WindowSwitchController.shared.commitOptionTab()
                }
                // A new gesture may start as soon as Option is released again.
                optionTabCancelled = false
            }
            if KeyboardEnhancer.shared.handleFlagsChanged(event) {
                return nil
            }
            return pass

        case .keyDown:
            let optionHeld = event.flags.contains(.maskAlternate)

            if WindowSwitchController.shared.isOptionTabActive {
                return handleOptionTabKeyDown(keyCode: keyCode, event: event)
            }

            if optionHeld, !optionTabCancelled, keyCode == KeyCodes.tab {
                if settings.windowSwitcherEnabled {
                    let reverse = event.flags.contains(.maskShift)
                    WindowSwitchController.shared.beginOptionTab(reverse: reverse)
                }
                swallowedKeys.insert(keyCode)
                return nil
            }

            if optionHeld, !optionTabCancelled, keyCode == KeyCodes.backtick || keyCode == KeyCodes.backtickISO {
                if settings.previousSpaceEnabled {
                    WindowSwitchController.shared.switchToPreviousSpace()
                }
                swallowedKeys.insert(keyCode)
                return nil
            }

            // A cancelled or committed Option-Tab session stays closed until
            // Option is released, so follow-up keys do not leak into the app.
            if optionTabCancelled, optionHeld {
                swallowedKeys.insert(keyCode)
                return nil
            }

            if let direction = KeyboardSpaceShortcut.direction(for: event) {
                SpaceSwitcher.shared.switchBy(steps: 1, direction: direction, reason: "ctrl-arrow")
                return nil
            }

            if SeekController.shared.handleKeyDown(
                event: event,
                hyperActive: KeyboardEnhancer.shared.isHyperActive
            ) {
                return nil
            }

            if KeyboardEnhancer.shared.handleKeyDown(event) {
                // KeyboardEnhancer tracks its own swallowed/forwarded keyUps;
                // adding the key here would steal the matching keyUp and could
                // leave a forwarded Hyper/layer key stuck down.
                return nil
            }
            return pass

        case .keyUp:
            if KeyboardEnhancer.shared.handleKeyUp(event) {
                return nil
            }
            if swallowedKeys.remove(keyCode) != nil {
                return nil
            }
            if WindowSwitchController.shared.isOptionTabActive {
                return nil
            }
            return pass

        default:
            return pass
        }
    }

    /// Development/test hook: clear the "session closed until Option is
    /// released" latch without physically releasing Option.
    func resetOptionTabCancellation() {
        optionTabCancelled = false
    }

    /// Development/test hook: drive the real classification and math without a
    /// physical trackpad. Used by `fasterspaces://test-gesture`.
    func testGesture(fingers: Int, progress: Double) {
        resetGesture()
        observedFingerCount = fingers
        classifyGesture()
        if windowGesture {
            _ = WindowSwitchController.shared.beginSwipe()
            beginWindowSwitching(progress: progress)
            WindowSwitchController.shared.endSwipe()
        } else if !ignoreForFingerCount {
            SpaceSwitcher.shared.noteGestureBegan()
            beginSwitching(progress: progress)
            SpaceSwitcher.shared.noteGestureEnded()
        }
        resetGesture()
    }

    private func handleOptionTabKeyDown(keyCode: CGKeyCode, event: CGEvent) -> Unmanaged<CGEvent>? {
        let reverse = event.flags.contains(.maskShift)
        switch keyCode {
        case KeyCodes.escape:
            WindowSwitchController.shared.cancelOptionTab()
            optionTabCancelled = true
            swallowedKeys.insert(keyCode)
            return nil
        case KeyCodes.returnKey, KeyCodes.keypadEnter:
            WindowSwitchController.shared.commitOptionTab()
            optionTabCancelled = true
            swallowedKeys.insert(keyCode)
            return nil
        case KeyCodes.tab:
            WindowSwitchController.shared.advanceOptionTab(reverse: reverse)
            swallowedKeys.insert(keyCode)
            return nil
        case KeyCodes.leftArrow, KeyCodes.upArrow:
            WindowSwitchController.shared.advanceOptionTab(reverse: true)
            swallowedKeys.insert(keyCode)
            return nil
        case KeyCodes.rightArrow, KeyCodes.downArrow:
            WindowSwitchController.shared.advanceOptionTab(reverse: false)
            swallowedKeys.insert(keyCode)
            return nil
        default:
            // Modal: keep unrelated keys out of the app underneath.
            swallowedKeys.insert(keyCode)
            return nil
        }
    }

    // MARK: Dock gestures

    private func handleDockControl(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let phase = event.getIntegerValueField(Field.gesturePhase)
        let progress = event.getDoubleValueField(Field.swipeProgress)
        let velocityX = event.getDoubleValueField(Field.swipeVelocityX)
        let velocityY = event.getDoubleValueField(Field.swipeVelocityY)
        let positionX = event.getDoubleValueField(Field.swipePositionX)
        let positionY = event.getDoubleValueField(Field.swipePositionY)
        let mask = event.getIntegerValueField(Field.swipeMask)
        let now = Date()
        let gap = now.timeIntervalSince(lastEventAt)
        lastEventAt = now

        if Log.isDebugEnabled, tracking || phase == GesturePhase.began.rawValue {
            Log.debug(String(
                format: "gesture phase=%lld progress=%.4f vel=(%.2f,%.2f) pos=(%.3f,%.3f) mask=%lld gap=%.3f fingers=%lld",
                phase, progress, velocityX, velocityY, positionX, positionY, mask, gap,
                observedFingerCount
            ))
        }

        switch phase {
        case GesturePhase.began.rawValue:
            beginGesture(event: event, now: now)
            return nil

        case GesturePhase.changed.rawValue:
            guard tracking else { return Unmanaged.passUnretained(event) }
            guard progress != 0 else { return nil }

            if windowGesture {
                if !windowFired {
                    beginWindowSwitching(progress: progress)
                } else {
                    updateWindowSwitching(progress: progress)
                }
                return nil
            }

            // The raw touch count can lag the gesture by a frame or two, and a
            // tracker that has only just picked up a re-connected trackpad has
            // no frame yet. Keep re-checking until a count is available (or the
            // gesture is far enough along that a late reclassification would be
            // jarring), so a fourth finger is never mistaken for Spaces.
            if !countRechecked, !fired, !windowFired {
                refreshFingerCount()
                if windowGesture {
                    countRechecked = true
                    beginWindowSwitching(progress: progress)
                    return nil
                }
                if observedFingerCount > 0 || Date().timeIntervalSince(startedAt) > 0.25 {
                    countRechecked = true
                }
            }
            if ignoreForFingerCount { return nil }

            if !fired {
                beginSwitching(progress: progress)
            } else {
                updateMultiSpace(progress: progress)
            }
            return nil

        case GesturePhase.ended.rawValue:
            let wasTracking = tracking
            if wasTracking, windowGesture {
                if !windowFired {
                    let signal = velocityX != 0 ? velocityX : progress
                    if signal != 0 {
                        beginWindowSwitching(progress: signal)
                    }
                }
                logGestureEnd(progress: progress)
                WindowSwitchController.shared.endSwipe()
            } else if wasTracking, !fired, !ignoreForFingerCount {
                let signal = velocityX != 0 ? velocityX : progress
                if signal != 0 {
                    beginSwitching(progress: signal)
                }
                logGestureEnd(progress: progress)
            }
            resetGesture()
            SpaceSwitcher.shared.noteGestureEnded()

            // On macOS 27 the Dock needs to see a terminal event to close the
            // native gesture state after our synthetic sequence. Clear the
            // fields so it cannot also act on the swipe.
            if SpaceSwitcher.shared.needsAugmentation, wasTracking {
                event.setDoubleValueField(Field.swipeVelocityX, value: 0)
                event.setDoubleValueField(Field.swipeVelocityY, value: 0)
                event.setDoubleValueField(Field.swipeProgress, value: 0)
                return Unmanaged.passUnretained(event)
            }
            return wasTracking ? nil : Unmanaged.passUnretained(event)

        case GesturePhase.cancelled.rawValue:
            if windowGesture {
                WindowSwitchController.shared.endSwipe()
            }
            resetGesture()
            SpaceSwitcher.shared.noteGestureEnded()
            return nil

        default:
            return tracking ? nil : Unmanaged.passUnretained(event)
        }
    }

    private func beginGesture(event: CGEvent, now: Date) {
        let settings = SettingsStore.shared
        resetGesture()
        WindowSwitchController.shared.endSwipe()
        SpaceSwitcher.shared.noteGestureBegan()
        tracking = true
        startedAt = now

        observedFingerCount = MultitouchTracker.shared.fingerCount
        classifyGesture()

        if windowGesture {
            SpaceSwitcher.shared.noteGestureEnded()
            _ = WindowSwitchController.shared.beginSwipe()
        } else if ignoreForFingerCount {
            Log.debug("Ignoring \(observedFingerCount)-finger swipe; macOS Spaces uses \(settings.spacesFingers), windows use \(settings.windowFingers)")
        }
    }

    /// Decide whether this physical gesture is the Spaces gesture or the
    /// window gesture. A zero touch count (MultitouchSupport unavailable, or
    /// the contacts have not been reported yet) is allowed to fall through to
    /// Spaces so a missing private framework never drops the primary gesture.
    private func classifyGesture() {
        let settings = SettingsStore.shared
        guard observedFingerCount > 0 else {
            ignoreForFingerCount = false
            return
        }

        if settings.windowSwipeEnabled, observedFingerCount == settings.windowFingers {
            windowGesture = true
            ignoreForFingerCount = false
            return
        }

        windowGesture = false
        ignoreForFingerCount = observedFingerCount != settings.spacesFingers
    }

    private func refreshFingerCount() {
        let previous = observedFingerCount
        observedFingerCount = MultitouchTracker.shared.fingerCount
        // A zero here means "no sample" (fingers already up, or a device that
        // has not reported yet), not a new classification. Keep the decision
        // made at gesture begin instead of falling back to Spaces.
        guard observedFingerCount > 0 else { return }
        guard observedFingerCount != previous else { return }
        classifyGesture()
        if windowGesture {
            SpaceSwitcher.shared.noteGestureEnded()
            _ = WindowSwitchController.shared.beginSwipe()
            Log.debug("Reclassified a \(observedFingerCount)-finger gesture as a window swipe")
        }
    }

    // MARK: Spaces switching

    private func beginSwitching(progress: Double) {
        let settings = SettingsStore.shared
        let initial = SwipeMath.initial(
            progress: progress,
            threshold: settings.effectiveProgressPerSpace,
            maxSteps: settings.maxSpaces,
            invert: settings.invertDirection
        )
        let steps = settings.multiSpaceEnabled ? initial.steps : 1

        fired = true
        netSteps = initial.direction * steps
        // Anchor to the threshold grid, not to the raw first sample, so that
        // moving back down the same distance walks the count back to zero.
        anchorProgress = initial.anchor

        let switched = SpaceSwitcher.shared.switchBy(
            steps: steps,
            direction: initial.direction,
            reason: "gesture"
        )
        if switched > 0, settings.hapticFeedback { performHaptic() }
    }

    /// Track a continuous, bidirectional distance across the trackpad. Crossing
    /// a threshold to the right switches right; crossing back to the left walks
    /// the same count down and switches left.
    private func updateMultiSpace(progress: Double) {
        let settings = SettingsStore.shared
        guard settings.multiSpaceEnabled, fired else { return }

        let desired = SwipeMath.desired(
            progress: progress,
            anchor: anchorProgress,
            threshold: settings.effectiveProgressPerSpace,
            maxSteps: settings.maxSpaces,
            invert: settings.invertDirection
        )
        guard desired != netSteps else { return }

        let direction = desired > netSteps ? 1 : -1
        let steps = abs(desired - netSteps)
        let switched = SpaceSwitcher.shared.switchBy(
            steps: steps,
            direction: direction,
            reason: "multi-space gesture"
        )
        if switched > 0, settings.hapticFeedback { performHaptic() }
        // Advance even if the edge clamped the switch, so pushing into the
        // edge doesn't queue up a pile of reversals for the way back.
        netSteps = desired
    }

    // MARK: Window switching

    private func beginWindowSwitching(progress: Double) {
        let settings = SettingsStore.shared
        guard settings.windowSwipeEnabled else { return }
        let initial = SwipeMath.initial(
            progress: progress,
            threshold: settings.effectiveWindowSwipeDistance,
            maxSteps: settings.maxWindowsPerSwipe,
            invert: settings.windowSwipeInvertDirection
        )

        windowFired = true
        windowNetSteps = initial.direction * initial.steps
        windowAnchorProgress = initial.anchor

        let crossed = WindowSwitchController.shared.swipeStep(
            direction: initial.direction,
            steps: initial.steps
        )
        if crossed > 0, Log.isDebugEnabled {
            Log.debug("Window swipe: \(crossed) window(s) \(initial.direction > 0 ? "next" : "previous")")
        }
    }

    private func updateWindowSwitching(progress: Double) {
        let settings = SettingsStore.shared
        guard settings.windowSwipeEnabled, windowFired else { return }
        let desired = SwipeMath.desired(
            progress: progress,
            anchor: windowAnchorProgress,
            threshold: settings.effectiveWindowSwipeDistance,
            maxSteps: settings.maxWindowsPerSwipe,
            invert: settings.windowSwipeInvertDirection
        )
        guard desired != windowNetSteps else { return }

        let direction = desired > windowNetSteps ? 1 : -1
        let steps = abs(desired - windowNetSteps)
        WindowSwitchController.shared.swipeStep(direction: direction, steps: steps)
        windowNetSteps = desired
    }

    // MARK: Utility

    private func logGestureEnd(progress: Double) {
        guard Log.isDebugEnabled, tracking else { return }
        let duration = Date().timeIntervalSince(startedAt)
        Log.debug(String(
            format: "gesture end duration=%.3fs progress=%.3f net=%d window=%@",
            duration, progress, windowGesture ? windowNetSteps : netSteps,
            windowGesture ? "yes" : "no"
        ))
    }

    private func resetGesture() {
        tracking = false
        fired = false
        ignoreForFingerCount = false
        observedFingerCount = 0
        countRechecked = false
        netSteps = 0
        anchorProgress = 0
        windowGesture = false
        windowFired = false
        windowNetSteps = 0
        windowAnchorProgress = 0
    }

    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

// MARK: - Key codes

private enum KeyCodes {
    static let tab: CGKeyCode = 0x30
    static let escape: CGKeyCode = 0x35
    static let returnKey: CGKeyCode = 0x24
    static let keypadEnter: CGKeyCode = 0x4C
    static let leftArrow: CGKeyCode = 0x7B
    static let rightArrow: CGKeyCode = 0x7C
    static let downArrow: CGKeyCode = 0x7D
    static let upArrow: CGKeyCode = 0x7E
    static let backtick: CGKeyCode = 0x32
    static let backtickISO: CGKeyCode = 0x0A
}

private let swipeTapCallback: CGEventTapCallBack = { _, type, event, _ in
    SwipeInterceptor.shared.handle(type: type, event: event)
}
