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
            return "Faster Spaces is listening for your macOS Spaces gesture."
        }
        if isTrusted {
            return "Permission is granted. The event tap is starting."
        }
        return "macOS requires Accessibility access before an app can replace trackpad gestures."
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
/// animated swipe, and posts an instant replacement.
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
    /// Net Spaces requested during this physical gesture. Positive means the
    /// user's effective direction is right. Reversing direction walks this
    /// number back down instead of being ignored.
    private var netSteps = 0
    /// The progress value that corresponds to netSteps == 0 on the synthetic
    /// switch scale. It can be negative because the first switch fires as soon
    /// as direction is known, before a full threshold has been travelled.
    private var anchorProgress = 0.0
    private var startedAt = Date.distantPast
    private var lastEventAt = Date.distantPast

    private init() {}

    // MARK: Install / remove

    @discardableResult
    func install() -> Bool {
        guard !isInstalled else { return true }

        let mask = (CGEventMask(1) << EventType.gesture)
            | (CGEventMask(1) << EventType.dockControl)
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
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return pass
        }

        let eventType = event.getIntegerValueField(Field.cgsEventType)
        let tag = event.getIntegerValueField(.eventSourceUserData)

        // Our own synthetic events (paired companion included).
        if tag == SpaceSwitcher.eventTag,
           (eventType == EventType.dockControl || eventType == EventType.gesture) {
            return pass
        }

        let settings = SettingsStore.shared
        guard settings.enabled else {
            if tracking { resetGesture() }
            return pass
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
                format: "gesture phase=%lld progress=%.4f vel=(%.2f,%.2f) pos=(%.3f,%.3f) mask=%lld gap=%.3f",
                phase, progress, velocityX, velocityY, positionX, positionY, mask, gap
            ))
        }

        switch phase {
        case GesturePhase.began.rawValue:
            tracking = true
            fired = false
            netSteps = 0
            anchorProgress = 0
            startedAt = now
            return nil

        case GesturePhase.changed.rawValue:
            guard tracking else { return Unmanaged.passUnretained(event) }
            guard progress != 0 else { return nil }

            if !fired {
                beginSwitching(progress: progress)
            } else {
                updateMultiSpace(progress: progress)
            }
            return nil

        case GesturePhase.ended.rawValue:
            let wasTracking = tracking
            if tracking, !fired {
                let signal = velocityX != 0 ? velocityX : progress
                if signal != 0 {
                    beginSwitching(progress: signal)
                }
            }
            logGestureEnd(progress: progress)
            resetGesture()

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
            resetGesture()
            return nil

        default:
            return tracking ? nil : Unmanaged.passUnretained(event)
        }
    }

    // MARK: Switching

    private func beginSwitching(progress: Double) {
        let settings = SettingsStore.shared
        let value = settings.invertDirection ? -progress : progress
        let direction = value >= 0 ? 1 : -1
        let threshold = settings.effectiveProgressPerSpace
        let rawSteps = max(1, Int(abs(value) / threshold))
        let steps = settings.multiSpaceEnabled ? min(rawSteps, settings.maxSpaces) : 1

        fired = true
        netSteps = direction * steps
        // Anchor to the threshold grid, not to the raw first sample, so that
        // moving back down the same distance walks the count back to zero.
        anchorProgress = value - Double(direction * rawSteps) * threshold

        let switched = SpaceSwitcher.shared.switchBy(
            steps: steps,
            direction: direction,
            reason: "gesture"
        )
        if switched > 0, settings.hapticFeedback { performHaptic() }
    }

    /// Track a continuous, bidirectional distance across the trackpad. Crossing
    /// a threshold to the right switches right; crossing back to the left walks
    /// the same count down and switches left. This lets the user change
    /// direction inside one physical swipe instead of being locked to the first
    /// direction.
    private func updateMultiSpace(progress: Double) {
        let settings = SettingsStore.shared
        guard settings.multiSpaceEnabled, fired else { return }

        let value = settings.invertDirection ? -progress : progress
        let threshold = settings.effectiveProgressPerSpace
        let rawDesired = Int((((value - anchorProgress) / threshold)).rounded(.towardZero))
        let desired = min(max(rawDesired, -settings.maxSpaces), settings.maxSpaces)
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

    private func logGestureEnd(progress: Double) {
        guard Log.isDebugEnabled, tracking else { return }
        let duration = Date().timeIntervalSince(startedAt)
        Log.debug(String(
            format: "gesture end duration=%.3fs progress=%.3f net=%d",
            duration, progress, netSteps
        ))
    }

    private func resetGesture() {
        tracking = false
        fired = false
        netSteps = 0
        anchorProgress = 0
    }

    private func performHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

private let swipeTapCallback: CGEventTapCallBack = { _, type, event, _ in
    SwipeInterceptor.shared.handle(type: type, event: event)
}
