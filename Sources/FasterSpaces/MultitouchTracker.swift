import AppKit
import Foundation

// MARK: - Finger configuration

/// Reads the macOS Spaces finger-count setting. The Dock's private gesture
/// event does not reliably expose the number of fingers, so raw touch tracking
/// is the only accurate way to tell a three-finger swipe from a four-finger one.
///
/// macOS stores the choice in two places depending on the OS version and the
/// trackpad (built-in vs. Bluetooth):
///
///   - `com.apple.trackpad.*` keys in the per-host global domain
///   - `Trackpad*Gesture` keys in `com.apple.AppleMultitouchTrackpad`
///
/// Values are: 0 = gesture disabled, 1 = swipe between pages, 2 = swipe
/// between full-screen applications (Spaces).
enum FingerConfiguration {
    /// The number of fingers macOS currently uses for Spaces (3 or 4).
    static var macOSFingerCount: Int {
        let three = horizontalValue(forThreeFingers: true)
        let four = horizontalValue(forThreeFingers: false)

        // Three fingers assigned to "pages" means Spaces must be four fingers.
        if three == 1 { return 4 }
        if three == 2, four == 2 { return 3 }
        if four == 2, three != 2 { return 4 }
        if three == 2, four == 0 { return 3 }
        if three == 0, four == 2 { return 4 }
        // Unknown or disabled: keep the historical default so a missing
        // preference never silently drops the Spaces gesture.
        return 3
    }

    static var autoSourceDescription: String {
        let three = horizontalValue(forThreeFingers: true)
        let four = horizontalValue(forThreeFingers: false)
        return "macOS: \(macOSFingerCount) fingers (3-finger=\(describe(three)), 4-finger=\(describe(four)))"
    }

    private static func describe(_ value: Int?) -> String {
        switch value {
        case 0: return "off"
        case 1: return "pages"
        case 2: return "spaces"
        case nil: return "unset"
        default: return String(value ?? 0)
        }
    }

    private static func horizontalValue(forThreeFingers: Bool) -> Int? {
        let globalKey = forThreeFingers
            ? "com.apple.trackpad.threeFingerHorizSwipeGesture"
            : "com.apple.trackpad.fourFingerHorizSwipeGesture"
        if let value = read(globalKey, application: kCFPreferencesAnyApplication as String) {
            return value
        }

        let trackpadKey = forThreeFingers
            ? "TrackpadThreeFingerHorizSwipeGesture"
            : "TrackpadFourFingerHorizSwipeGesture"
        let domains = [
            "com.apple.AppleMultitouchTrackpad",
            "com.apple.driver.AppleBluetoothMultitouch.trackpad",
        ]
        for domain in domains {
            if let value = read(trackpadKey, application: domain) {
                return value
            }
        }
        return nil
    }

    private static func read(_ key: String, application: String) -> Int? {
        if let number = CFPreferencesCopyValue(
            key as CFString,
            application as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? NSNumber {
            return number.intValue
        }
        // Trackpad domains are usually not host-scoped.
        if let number = CFPreferencesCopyValue(
            key as CFString,
            application as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? NSNumber {
            return number.intValue
        }
        return nil
    }
}

// MARK: - Raw touch frame

/// A compact snapshot of the contacts on one trackpad frame. The window
/// switcher uses it for diagnostics and as a fallback when the Dock does not
/// deliver a DockControl event for the non-primary finger count.
struct TrackpadTouchFrame {
    var count: Int = 0
    /// Normalized centroid (0...1) across the physical trackpad.
    var x: Float = 0
    var y: Float = 0
    /// Normalized horizontal spread between the outermost contacts.
    var spread: Float = 0
    var maxContactSize: Float = 0
    var timestamp: Double = 0
}

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private let mtContactCallback: MTContactCallback = { _, touches, count, timestamp, _ in
    guard let touches, count > 0 else {
        MultitouchTracker.setFrame(TrackpadTouchFrame(timestamp: timestamp))
        return 0
    }
    let typed = touches.assumingMemoryBound(to: MTTouch.self)
    var touching = 0
    var sumX: Float = 0
    var sumY: Float = 0
    var minX: Float = .greatestFiniteMagnitude
    var maxX: Float = -.greatestFiniteMagnitude
    var maxSize: Float = 0

    for index in 0..<Int(count) {
        let touch = typed[index]
        // touching = 3, active = 4
        guard touch.state == 3 || touch.state == 4 else { continue }
        touching += 1
        let position = touch.normalizedVector.position
        sumX += position.x
        sumY += position.y
        minX = min(minX, position.x)
        maxX = max(maxX, position.x)
        maxSize = max(maxSize, max(touch.majorAxis, touch.minorAxis))
    }

    guard touching > 0 else {
        MultitouchTracker.setFrame(TrackpadTouchFrame(timestamp: timestamp))
        return 0
    }

    let frame = TrackpadTouchFrame(
        count: touching,
        x: sumX / Float(touching),
        y: sumY / Float(touching),
        spread: maxX - minX,
        maxContactSize: maxSize,
        timestamp: timestamp
    )
    MultitouchTracker.setFrame(frame)
    return 0
}

/// Reads the macOS finger-count setting and observes raw trackpad contacts.
/// `MultitouchSupport` is private; a failure degrades to "count unavailable"
/// (0), which makes the gesture router accept both finger counts.
///
/// Trackpad devices are not static. A boot in clamshell mode enumerates only a
/// Bluetooth trackpad; opening the lid brings the built-in trackpad online and
/// can take the Bluetooth one away. A tracker that registers whatever exists at
/// launch goes deaf on the next swap and then reports 0 forever, which the
/// gesture router treats as "allow Spaces" -- so every four-finger swipe starts
/// switching desktops. The tracker therefore re-enumerates on a timer and after
/// wake, and treats an old frame as unavailable.
final class MultitouchTracker {
    static let shared = MultitouchTracker()

    private static let lock = NSLock()
    private static var storedFrame = TrackpadTouchFrame()
    private static var storedFrameAt: Date?

    /// How long a contact frame stays valid. The framework delivers frames at
    /// 40-125 Hz while fingers are down, so anything older than this means the
    /// device we are listening to has gone away.
    private static let frameLifetime: TimeInterval = 0.6

    private typealias CreateList = @convention(c) () -> CFArray?
    private typealias Register = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias Unregister = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias Start = @convention(c) (MTDeviceRef, Int32) -> Void
    private typealias DeviceID = @convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>) -> Void

    private var handle: UnsafeMutableRawPointer?
    private var createList: CreateList?
    private var register: Register?
    private var startDevice: Start?
    private var unregister: Unregister?
    private var deviceIDFunction: DeviceID?

    private var deviceCount = 0
    private var liveDeviceKeys = Set<UInt>()
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    static func setFrame(_ frame: TrackpadTouchFrame) {
        lock.lock()
        storedFrame = frame
        storedFrameAt = Date()
        lock.unlock()
    }

    static func setFingerCount(_ count: Int) {
        lock.lock()
        storedFrame.count = count
        storedFrameAt = Date()
        lock.unlock()
    }

    /// The current contact count, or 0 when no frame has arrived recently.
    var fingerCount: Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let receivedAt = Self.storedFrameAt,
              Date().timeIntervalSince(receivedAt) <= Self.frameLifetime
        else { return 0 }
        return Self.storedFrame.count
    }

    /// The last frame as reported, without the freshness check. Diagnostics
    /// only; gesture routing uses `fingerCount`.
    var latestFrame: TrackpadTouchFrame {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.storedFrame
    }

    func start() {
        guard handle == nil else {
            refreshDevices(force: false)
            return
        }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            Log.error("MultitouchSupport unavailable: \(String(cString: dlerror()))")
            return
        }
        self.handle = handle

        guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let createList = unsafeBitCast(createListSym, to: CreateList.self) as CreateList?,
              let register = unsafeBitCast(registerSym, to: Register.self) as Register?,
              let startDevice = unsafeBitCast(startSym, to: Start.self) as Start?
        else {
            Log.error("MultitouchSupport symbols unavailable")
            return
        }
        self.createList = createList
        self.register = register
        self.startDevice = startDevice
        if let unregisterSym = dlsym(handle, "MTUnregisterContactFrameCallback") {
            unregister = unsafeBitCast(unregisterSym, to: Unregister.self)
        }
        if let idSym = dlsym(handle, "MTDeviceGetDeviceID") {
            deviceIDFunction = unsafeBitCast(idSym, to: DeviceID.self)
        }

        refreshDevices(force: true)
        Log.info("Multitouch tracker started for \(deviceCount) device(s); \(FingerConfiguration.autoSourceDescription)")

        // Devices come and go with clamshell mode, Bluetooth trackpads and
        // sleep. Re-enumerate cheaply; registering a device twice would double
        // its callback rate, so only new device objects are registered.
        if refreshTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.refreshDevices(force: false)
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        }

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // A device that survived sleep may still have dropped its
                // callback; re-register everything once and clear the stale
                // count so the next gesture is classified from live data.
                MultitouchTracker.setFrame(TrackpadTouchFrame())
                self?.refreshDevices(force: true)
            }
        }
    }

    /// Register every trackpad that is not already being observed. `force`
    /// re-registers devices that are already known, which is the reliable way
    /// to recover callbacks after a wake.
    func refreshDevices(force: Bool) {
        guard let createList, let register, let startDevice else { return }
        guard let list = createList() else { return }

        var present = Set<UInt>()
        var registered = 0
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            let key = deviceKey(device)
            present.insert(key)

            if !force, liveDeviceKeys.contains(key) { continue }
            if let unregister {
                unregister(device, mtContactCallback)
            }
            register(device, mtContactCallback)
            startDevice(device, 0)
            liveDeviceKeys.insert(key)
            registered += 1
        }

        // Forget devices that vanished so one re-created with the same ID
        // after sleep or a reconnect is registered again.
        liveDeviceKeys.formIntersection(present)
        deviceCount = present.count
        if registered > 0 {
            Log.info("Multitouch tracker: \(present.count) device(s) present, \(registered) registered")
        }
    }

    private func deviceKey(_ device: MTDeviceRef) -> UInt {
        if let deviceIDFunction {
            var identifier: Int32 = 0
            deviceIDFunction(device, &identifier)
            if identifier != 0 { return UInt(UInt32(bitPattern: identifier)) }
        }
        return UInt(bitPattern: device)
    }
}
