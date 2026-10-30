import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class DockEventTap {
    private static let magicUserData: Int64 = 0x4E57_504C_5A // "NWPLZ"

    private let policy: DockClickPolicy
    private let inspector: DockInspector
    private let geometryCache: DockGeometryCache
    private let rules: AppRulesStore

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var tapThread: Thread?
    private var pending: PendingClick?
    private var pendingPick: PendingPick?
    private let pickerLock = NSLock()
    private var pickerActive = false
    private(set) var isRunning = false

    var onDockAction: ((DockTile, pid_t, DockClickAction, DockClickModifier) -> Void)?
    var onPickApp: ((DockTile) -> Void)?
    var onTapRecovered: (() -> Void)?

    private struct PendingClick {
        let tile: DockTile
        let pid: pid_t
        let point: CGPoint
        let startedAt: CFTimeInterval
        let action: DockClickAction
        let modifier: DockClickModifier
        var cancelled = false
    }

    private struct PendingPick {
        let tile: DockTile
        let point: CGPoint
        let startedAt: CFTimeInterval
        var cancelled = false
    }

    func setPickerActive(_ active: Bool) {
        pickerLock.lock()
        pickerActive = active
        pickerLock.unlock()
    }

    private var isPickerActive: Bool {
        pickerLock.lock()
        defer { pickerLock.unlock() }
        return pickerActive
    }

    init(inspector: DockInspector,
         geometryCache: DockGeometryCache,
         rules: AppRulesStore,
         policy: DockClickPolicy = DockClickPolicy()) {
        self.inspector = inspector
        self.geometryCache = geometryCache
        self.rules = rules
        self.policy = policy
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue |
            CGEventMask(1) << CGEventType.leftMouseDragged.rawValue |
            CGEventMask(1) << CGEventType.leftMouseUp.rawValue |
            CGEventMask(1) << CGEventType.rightMouseDown.rawValue |
            CGEventMask(1) << CGEventType.rightMouseDragged.rawValue |
            CGEventMask(1) << CGEventType.rightMouseUp.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("CGEvent.tapCreate returned nil. Accessibility may not be effective yet.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source
        self.pending = nil
        self.pendingPick = nil

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let source = self.source else { return }
            let currentRunLoop = CFRunLoopGetCurrent()
            self.runLoop = currentRunLoop
            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "NewWindowPlz Dock Event Tap"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        tapThread = thread
        thread.start()

        if ready.wait(timeout: .now() + 1.0) == .timedOut {
            Log.error("Event tap thread did not become ready.")
            stop()
            return false
        }

        isRunning = true
        Log.info("Dock event tap started.")
        return true
    }

    func stop() {
        guard isRunning || tap != nil else { return }

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }

        tap = nil
        source = nil
        runLoop = nil
        tapThread = nil
        pending = nil
        pendingPick = nil
        isRunning = false
        Log.info("Dock event tap stopped.")
    }

    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.magicUserData {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            pending = nil
            pendingPick = nil
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Log.error("Event tap disabled by the system; re-enabled.")
            DispatchQueue.main.async { [weak self] in
                self?.onTapRecovered?()
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown:
            return handleMouseDown(event: event, isRight: false)

        case .rightMouseDown:
            return handleMouseDown(event: event, isRight: true)

        case .leftMouseDragged, .rightMouseDragged:
            if var pendingPick {
                let dx = event.location.x - pendingPick.point.x
                let dy = event.location.y - pendingPick.point.y
                if (dx * dx + dy * dy) > 64 {
                    pendingPick.cancelled = true
                    self.pendingPick = pendingPick
                }
                return nil
            }
            guard var pending else {
                return Unmanaged.passUnretained(event)
            }
            let dx = event.location.x - pending.point.x
            let dy = event.location.y - pending.point.y
            if (dx * dx + dy * dy) > 64 {
                pending.cancelled = true
                self.pending = pending
            }
            return nil

        case .leftMouseUp, .rightMouseUp:
            return handleMouseUp(event: event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleMouseDown(event: CGEvent, isRight: Bool) -> Unmanaged<CGEvent>? {
        guard pending == nil else {
            pending = nil
            return Unmanaged.passUnretained(event)
        }

        // With macOS's default Control-click conversion, the event arrives as
        // a right mouse down and the Control flag may be gone. Check the live
        // HID/session modifier state so default systems still recognize the
        // Control modification.
        let controlDown = controlIsDown(event: event)

        if isRight, !controlDown {
            return Unmanaged.passUnretained(event)
        }

        var effectiveFlags = event.flags
        if controlDown {
            effectiveFlags.insert(.maskControl)
        }
        if !effectiveFlags.intersection(DockClickPolicy.passThroughModifiers).isEmpty {
            return Unmanaged.passUnretained(event)
        }

        let point = event.location
        let snapshot = geometryCache.snapshot()
        let slop = dockMagnificationEnabled ? 96.0 : 24.0
        // Cached geometry is only a fast-path hint. An auto-hidden or
        // magnified Dock can have moved since the last scan, so the screen
        // edge prefilter deliberately errs on the side of consulting AX.
        let cachedHit = snapshot.mightContainTile(at: point, slop: slop)
        let nearScreenEdge = ScreenEdgeProximity.isNearAnyScreenEdge(point)
        guard cachedHit || nearScreenEdge else {
            return Unmanaged.passUnretained(event)
        }

        let hitTile: DockTile?
        switch inspector.inspectApplicationTile(at: point) {
        case .application(let tile):
            hitTile = tile
        case .notApplication:
            return Unmanaged.passUnretained(event)
        case .unavailable:
            // The live AX round-trip can occasionally fail while Dock is
            // rebuilding. Fall back to the last known geometry rather than
            // silently losing the click.
            hitTile = snapshot.tile(at: point, slop: 2)
        }

        if isPickerActive, !isRight, let hitTile {
            pendingPick = PendingPick(
                tile: hitTile,
                point: point,
                startedAt: CACurrentMediaTime()
            )
            Log.debug("Picker intercepted Dock tile \(hitTile.title).")
            return nil
        }

        let configuredAction = hitTile.flatMap {
            rules.dockTapAction(
                bundleIdentifier: $0.bundleIdentifier,
                title: $0.title
            )
        }
        let decision = policy.decide(
            isEnabled: true,
            tile: hitTile,
            modifiers: effectiveFlags,
            configuredAction: configuredAction
        )
        guard case .action(let action) = decision else {
            if case .passThrough(let reason) = decision {
                Log.debug("Passing Dock click through (\(reason.rawValue)).")
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tile = hitTile,
              !DockSystemApps.isExcluded(tile),
              let application = RunningApplicationResolver.application(for: tile),
              application.activationPolicy == .regular else {
            return Unmanaged.passUnretained(event)
        }

        pending = PendingClick(
            tile: tile,
            pid: application.processIdentifier,
            point: point,
            startedAt: CACurrentMediaTime(),
            action: action,
            modifier: DockClickPolicy.modifier(for: effectiveFlags)
        )
        Log.debug("Intercepted Dock click for \(tile.title).")
        return nil
    }

    private func controlIsDown(event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == ControlClickFilter.controlStrippedMarker {
            return true
        }
        if event.flags.contains(.maskControl) {
            return true
        }
        if CGEventSource.flagsState(.hidSystemState).contains(.maskControl) {
            return true
        }
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskControl) {
            return true
        }
        return NSEvent.modifierFlags.contains(.control)
    }

    private func handleMouseUp(event: CGEvent) -> Unmanaged<CGEvent>? {
        if let pendingPick {
            self.pendingPick = nil
            guard isPickerActive else {
                return nil
            }
            let dx = event.location.x - pendingPick.point.x
            let dy = event.location.y - pendingPick.point.y
            let movedTooFar = (dx * dx + dy * dy) > 100
            let tookTooLong = CACurrentMediaTime() - pendingPick.startedAt > 2.0
            if !pendingPick.cancelled && !movedTooFar && !tookTooLong {
                onPickApp?(pendingPick.tile)
            } else {
                Log.debug("Dock app pick cancelled after movement/timeout.")
            }
            return nil
        }

        guard let pending else {
            return Unmanaged.passUnretained(event)
        }
        self.pending = nil

        let dx = event.location.x - pending.point.x
        let dy = event.location.y - pending.point.y
        let movedTooFar = (dx * dx + dy * dy) > 100
        let tookTooLong = CACurrentMediaTime() - pending.startedAt > 2.0

        if !pending.cancelled && !movedTooFar && !tookTooLong {
            onDockAction?(pending.tile, pending.pid, pending.action, pending.modifier)
        } else {
            Log.debug("Dock click cancelled after movement/timeout.")
        }

        return nil
    }

    private var dockMagnificationEnabled: Bool {
        let value = CFPreferencesCopyAppValue(
            "magnification" as CFString,
            "com.apple.dock" as CFString
        ) as? NSNumber
        return (value?.doubleValue ?? 0) > 0
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let eventTap = Unmanaged<DockEventTap>.fromOpaque(refcon).takeUnretainedValue()
        return eventTap.handle(type: type, event: event)
    }
}
