import AppKit
import CoreGraphics
import Foundation

/// Reimplements the useful part of DisableCtrlClick: strip the Control flag
/// from left-mouse events at the HID layer before macOS turns them into a
/// right-click. The marker lets the Dock tap recognize the stripped click as
/// a Control-click even though the flag is gone.
final class ControlClickFilter {
    static let controlStrippedMarker: Int64 = 0x4E57_5043_5452 // "NWPCTR"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private(set) var isRunning = false

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = CGEventMask(1) << CGEventType.leftMouseDown.rawValue |
            CGEventMask(1) << CGEventType.leftMouseDragged.rawValue |
            CGEventMask(1) << CGEventType.leftMouseUp.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("Control-click filter tap could not be created.")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.source = source

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
        thread.name = "NewWindowPlz Control-click Filter"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 256 * 1024
        self.thread = thread
        thread.start()

        if ready.wait(timeout: .now() + 1.0) == .timedOut {
            stop()
            return false
        }
        isRunning = true
        Log.info("Control-click filter started.")
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
        thread = nil
        isRunning = false
        Log.info("Control-click filter stopped.")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if event.flags.contains(.maskControl) {
                event.flags.remove(.maskControl)
                event.setIntegerValueField(
                    .eventSourceUserData,
                    value: Self.controlStrippedMarker
                )
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let filter = Unmanaged<ControlClickFilter>.fromOpaque(refcon).takeUnretainedValue()
        return filter.handle(type: type, event: event)
    }
}
