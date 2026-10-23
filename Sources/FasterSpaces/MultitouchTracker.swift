import Foundation

/// Reads the macOS Spaces finger-count setting and observes the raw trackpad
/// touch count. The Dock's private gesture event does not reliably expose the
/// number of fingers, so this is the only accurate way to ignore a 4-finger
/// swipe when macOS is configured for 3 (and vice versa).
enum FingerConfiguration {
    /// `com.apple.trackpad.threeFingerHorizSwipeGesture` is 2 when the macOS
    /// Spaces gesture is set to three fingers (four is left enabled), and 0
    /// when four fingers is selected.
    static var macOSFingerCount: Int {
        let value = CFPreferencesCopyValue(
            "com.apple.trackpad.threeFingerHorizSwipeGesture" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? Int ?? 2
        return value == 2 ? 3 : 4
    }
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

private let mtContactCallback: MTContactCallback = { _, touches, count, _, _ in
    guard let touches, count > 0 else {
        MultitouchTracker.setFingerCount(0)
        return 0
    }
    let typed = touches.assumingMemoryBound(to: MTTouch.self)
    var touching = 0
    for index in 0..<Int(count) {
        let state = typed[index].state
        // touching = 3, active = 4
        if state == 3 || state == 4 {
            touching += 1
        }
    }
    MultitouchTracker.setFingerCount(touching)
    return 0
}

final class MultitouchTracker {
    static let shared = MultitouchTracker()

    private static let lock = NSLock()
    private static var storedFingerCount = 0

    private var devices: [MTDeviceRef] = []
    private var handle: UnsafeMutableRawPointer?

    private init() {}

    static func setFingerCount(_ count: Int) {
        lock.lock()
        storedFingerCount = count
        lock.unlock()
    }

    var fingerCount: Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return Self.storedFingerCount
    }

    func start() {
        guard devices.isEmpty else { return }
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            Log.error("MultitouchSupport unavailable: \(String(cString: dlerror()))")
            return
        }
        self.handle = handle

        typealias CreateList = @convention(c) () -> CFArray?
        typealias Register = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
        typealias Start = @convention(c) (MTDeviceRef, Int32) -> Void

        guard let createListSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart"),
              let createList = unsafeBitCast(createListSym, to: CreateList.self) as CreateList?,
              let register = unsafeBitCast(registerSym, to: Register.self) as Register?,
              let startDevice = unsafeBitCast(startSym, to: Start.self) as Start?,
              let list = createList()
        else {
            Log.error("MultitouchSupport symbols unavailable")
            return
        }

        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            register(device, mtContactCallback)
            startDevice(device, 0)
            devices.append(device)
        }
        Log.info("Multitouch tracker started for \(devices.count) device(s); macOS is set to \(FingerConfiguration.macOSFingerCount) fingers")
    }
}
