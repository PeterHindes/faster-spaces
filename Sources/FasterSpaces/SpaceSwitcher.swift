import AppKit
import CoreGraphics
import Foundation

// MARK: - Private SkyLight API

typealias CGSConnectionID = UInt32

@_silgen_name("SLSMainConnectionID")
private func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
private func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

@_silgen_name("SLSGetActiveSpace")
private func SLSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

@_silgen_name("SLSCopySpacesForWindows")
private func SLSCopySpacesForWindows(
    _ cid: CGSConnectionID,
    _ mask: Int32,
    _ windows: CFArray
) -> Unmanaged<CFArray>

// MARK: - Model

struct ManagedSpace {
    let id: UInt64
    let isFullscreen: Bool
}

struct ManagedDisplay {
    let identifier: String
    let spaces: [ManagedSpace]
    let currentIndex: Int

    var currentSpace: ManagedSpace? {
        spaces.indices.contains(currentIndex) ? spaces[currentIndex] : nil
    }
}

struct SpaceSnapshot {
    let display: ManagedDisplay
    let allDisplays: [ManagedDisplay]

    var spaceCount: Int { display.spaces.count }
    var currentNumber: Int { display.currentIndex + 1 }
    var currentSpaceID: UInt64? { display.currentSpace?.id }
}

// MARK: - SpaceSwitcher

/// Switches Spaces by posting a synthetic Dock-swipe gesture.
///
/// The gesture runs through the Dock's own Spaces pipeline, so Mission Control,
/// focus, wallpapers and the Dock all stay consistent. Progress is near zero and
/// the terminal velocity is a fling, which leaves the animation nothing to
/// animate: the switch is effectively instant.
///
/// This is the technique documented by jurplel/InstantSpaceSwitcher,
/// gechr/WhichSpace, and mmathys/noswoosh. macOS 27 additionally validates a
/// serialized IOHID payload and a companion gesture event; that path is adapted
/// from noswoosh (MIT) and joshuarli/iss (ISC). See THIRD_PARTY_NOTICES.md.
final class SpaceSwitcher {
    static let shared = SpaceSwitcher()

    /// Tag placed on our synthetic events so the event tap recognises and
    /// passes them through instead of intercepting its own output.
    static let eventTag: Int64 = 0x4653_5053 // "FSPS"

    private let cid = SLSMainConnectionID()

    /// macOS 27 validates synthetic swipes against a serialized raw IOHID
    /// payload. The layout is stable on 27.0 and is gated by runtime version.
    let needsAugmentation: Bool

    /// On the 27 path the posted direction follows Natural Scrolling. The
    /// reading side does not: a real rightward swipe always reports positive
    /// progress. Only the writer flips.
    private let postedSwipeSign: Double

    /// Predicted index while the CGS snapshot catches up after a switch.
    private var predictedIndex: Int?
    private var predictedDisplay: String?
    private var predictionTime = Date.distantPast
    private let predictionWindow: TimeInterval

    /// Number of synthetic gestures posted since launch (diagnostics).
    private(set) var postedGestureCount = 0

    private init() {
        let major = Self.macOSMajorVersion()
        needsAugmentation = major >= 27
        predictionWindow = needsAugmentation ? 0.45 : 0.30
        let natural = CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication
        ) as? Bool ?? true
        postedSwipeSign = needsAugmentation && !natural ? -1 : 1
    }

    static func macOSMajorVersion() -> Int {
        var buffer = [CChar](repeating: 0, count: 32)
        var size = buffer.count
        guard sysctlbyname("kern.osproductversion", &buffer, &size, nil, 0) == 0,
              let major = Int(String(cString: buffer).split(separator: ".").first ?? "")
        else {
            return 0
        }
        return major
    }

    // MARK: Snapshot

    func snapshot() -> SpaceSnapshot? {
        let displays = managedDisplays()
        guard !displays.isEmpty else { return nil }

        // The Dock routes a Space swipe to the display under the pointer, not
        // the display holding keyboard focus. Match that so clamping is right
        // on multi-display setups.
        if displays.count > 1,
           let cursorUUID = Self.cursorDisplayUUID(),
           let display = displays.first(where: { $0.identifier == cursorUUID }) {
            return SpaceSnapshot(display: display, allDisplays: displays)
        }

        let activeID = SLSGetActiveSpace(cid)
        if let display = displays.first(where: { $0.currentSpace?.id == activeID }) {
            return SpaceSnapshot(display: display, allDisplays: displays)
        }
        return displays.first.map { SpaceSnapshot(display: $0, allDisplays: displays) }
    }

    func allDisplays() -> [ManagedDisplay] {
        managedDisplays()
    }

    private func managedDisplays() -> [ManagedDisplay] {
        guard let raw = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { dict -> ManagedDisplay? in
            guard let identifier = dict["Display Identifier"] as? String,
                  let rawSpaces = dict["Spaces"] as? [[String: Any]] else {
                return nil
            }
            let spaces = rawSpaces.compactMap { space -> ManagedSpace? in
                guard let number = Self.spaceID(from: space) else { return nil }
                let fullscreen = (space["TileLayoutManager"] as? [String: Any]) != nil
                    || (space["TileLayoutManager"] as? NSDictionary) != nil
                return ManagedSpace(id: number, isFullscreen: fullscreen)
            }
            guard !spaces.isEmpty else { return nil }

            let currentDict = dict["Current Space"] as? [String: Any]
            let currentID = currentDict.flatMap(Self.spaceID(from:))
            let index = currentID.flatMap { id in spaces.firstIndex(where: { $0.id == id }) }
                ?? 0
            return ManagedDisplay(identifier: identifier, spaces: spaces, currentIndex: index)
        }
    }

    private static func spaceID(from dict: [String: Any]) -> UInt64? {
        if let number = dict["id64"] as? NSNumber { return number.uint64Value }
        if let number = dict["ManagedSpaceID"] as? NSNumber { return number.uint64Value }
        if let number = dict["id64"] as? UInt64 { return number }
        if let number = dict["ManagedSpaceID"] as? UInt64 { return number }
        return nil
    }

    private static func cursorDisplayUUID() -> String? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        var displayID = CGDirectDisplayID()
        var matched: UInt32 = 0
        guard CGGetDisplaysWithPoint(location, 1, &displayID, &matched) == .success,
              matched > 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: Public switching

    /// The current 0-based index after honouring a very recent prediction.
    func logicalCurrentIndex(for snapshot: SpaceSnapshot) -> Int {
        if let predictedIndex,
           predictedDisplay == snapshot.display.identifier,
           Date().timeIntervalSince(predictionTime) < predictionWindow {
            return predictedIndex
        }
        return snapshot.display.currentIndex
    }

    /// Switch `steps` Spaces in `direction` (+1 right, -1 left). Returns the
    /// number of Spaces actually requested (0 at the edge).
    @discardableResult
    func switchBy(steps: Int, direction: Int, reason: String = "") -> Int {
        guard steps > 0, direction != 0 else { return 0 }
        guard let snapshot = snapshot() else {
            Log.error("Cannot read Spaces; switch ignored")
            return 0
        }

        let current = logicalCurrentIndex(for: snapshot)
        let count = snapshot.spaceCount
        let requestedTarget = current + direction * steps
        let target = min(max(requestedTarget, 0), count - 1)
        guard target != current else {
            Log.debug("At edge (space \(current + 1)/\(count)); no switch")
            return 0
        }

        let distance = abs(target - current)
        for _ in 0..<distance {
            postSwitchGesture(right: direction > 0)
        }
        postedGestureCount += distance
        predictedIndex = target
        predictedDisplay = snapshot.display.identifier
        predictionTime = Date()

        let from = current + 1
        let to = target + 1
        Log.info("Switched \(from) -> \(to) of \(count)\(reason.isEmpty ? "" : " (\(reason))")")
        NotificationCenter.default.post(name: .fasterSpacesDidSwitch, object: nil)
        return distance
    }

    /// Switch one Space in the given direction. Returns true if a gesture was posted.
    @discardableResult
    func switchOne(direction: Int, reason: String = "") -> Bool {
        switchBy(steps: 1, direction: direction, reason: reason) > 0
    }

    /// Forget any prediction. Called when the real state catches up or a
    /// display reconfiguration invalidates the cached indexes.
    func resetPrediction() {
        predictedIndex = nil
        predictedDisplay = nil
        predictionTime = .distantPast
    }

    /// A debug-friendly summary used by the diagnostics window.
    func currentSummary() -> String {
        guard let snapshot = snapshot() else { return "No Spaces data" }
        return "Space \(snapshot.currentNumber) of \(snapshot.spaceCount) on \(snapshot.display.identifier)"
    }

    // MARK: Synthetic gesture

    private func postSwitchGesture(right: Bool) {
        if needsAugmentation {
            postAugmentedSequence(right: right)
        } else {
            postLegacySequence(right: right)
        }
    }

    // MARK: Pre-macOS 27

    private func postLegacySequence(right: Bool) {
        for phase in [GesturePhase.began, .changed, .ended] {
            guard let event = makeLegacyEvent(phase: phase, right: right) else { return }
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func makeLegacyEvent(phase: GesturePhase, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let progress = 1e-4 * (right ? 1 : -1)
        let velocity = 2000.0 * (right ? 1 : -1)
        event.setIntegerValueField(Field.cgsEventType, value: EventType.dockControl)
        event.setIntegerValueField(Field.gestureHIDType, value: HIDType.dockSwipe)
        event.setIntegerValueField(Field.gesturePhase, value: phase.rawValue)
        event.setDoubleValueField(Field.swipeProgress, value: progress)
        event.setIntegerValueField(Field.swipeMotion, value: GestureMotion.horizontal)
        event.setDoubleValueField(Field.swipeVelocityX, value: velocity)
        event.setDoubleValueField(Field.swipeVelocityY, value: velocity)
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        return event
    }

    // MARK: macOS 27+

    private func postAugmentedSequence(right: Bool) {
        var events: [CGEvent] = []
        for phase in [GesturePhase.began, .changed, .ended] {
            guard let base = makeAugmentedEvent(phase: phase, right: right),
                  let augmented = Self.augment(base) else {
                Log.error("Could not build macOS 27 gesture payload")
                return
            }
            // augment() round-trips through serialized data, which drops the
            // source user data; set the tag again so our tap passes it through.
            augmented.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            events.append(augmented)
        }
        for event in events {
            event.post(tap: .cgSessionEventTap)
            Self.postCompanion()
        }
    }

    private func makeAugmentedEvent(phase: GesturePhase, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let progress = (right ? -1e-4 : 1e-4) * postedSwipeSign
        event.setIntegerValueField(Field.cgsEventType, value: EventType.dockControl)
        event.setIntegerValueField(Field.gestureHIDType, value: HIDType.dockSwipe)
        event.setIntegerValueField(Field.gesturePhase, value: phase.rawValue)
        event.setDoubleValueField(Field.swipeProgress, value: progress)
        event.setIntegerValueField(Field.swipeMotion, value: GestureMotion.horizontal)
        event.setDoubleValueField(Field.swipePositionX, value: 0.1)
        if phase == .ended {
            event.setDoubleValueField(
                Field.swipeVelocityX,
                value: (right ? -9999.0 : 9999.0) * postedSwipeSign
            )
            event.setDoubleValueField(Field.swipeVelocityY, value: 0)
        }
        return event
    }

    private static func postCompanion() {
        guard let companion = CGEvent(source: nil) else { return }
        companion.setIntegerValueField(.eventSourceUserData, value: eventTag)
        companion.setIntegerValueField(Field.cgsEventType, value: EventType.gesture)
        companion.post(tap: .cgSessionEventTap)
    }

    // MARK: Serialized IOHID payload

    private static func augment(_ event: CGEvent) -> CGEvent? {
        guard let serialized = event.data else { return nil }
        var bytes = [UInt8](serialized as Data)
        // Serialized CGEvent format v2 starts 00 00 00 02.
        guard bytes.count >= 4,
              bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2
        else {
            return nil
        }
        let payload = iohidPayload(event: event)
        let length = payload.count
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(UInt8((Field.iohidPayload >> 8) & 0xFF))
        bytes.append(UInt8(Field.iohidPayload & 0xFF))
        bytes.append(contentsOf: payload)
        return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
    }

    /// Byte-exact packed records validated by the macOS 27 Dock:
    /// queue header (28 bytes) + fluid-touch gesture (40 bytes) + velocity
    /// (28 bytes). Values are little-endian. Don't replace with Swift structs;
    /// packing is not guaranteed and one wrong offset silently drops the swipe.
    private static func iohidPayload(event: CGEvent) -> [UInt8] {
        let phase = event.getIntegerValueField(Field.gesturePhase)
        let motion = event.getIntegerValueField(Field.swipeMotion)
        let progress = event.getDoubleValueField(Field.swipeProgress)
        let positionX = event.getDoubleValueField(Field.swipePositionX)
        let positionY = event.getDoubleValueField(Field.swipePositionY)
        let velocityX = event.getDoubleValueField(Field.swipeVelocityX)
        let velocityY = event.getDoubleValueField(Field.swipeVelocityY)
        let mask = event.getIntegerValueField(Field.swipeMask)
        let includeVelocity = velocityX != 0 || velocityY != 0 || phase == GesturePhase.ended.rawValue

        var payload = [UInt8]()
        let timestamp = event.timestamp != 0 ? event.timestamp : mach_absolute_time()
        payload.appendLE(timestamp)
        payload.appendLE(UInt64(0)) // sender id
        payload.appendLE(UInt32(0)) // options
        payload.appendLE(UInt32(0)) // attribute length
        payload.appendLE(UInt32(includeVelocity ? 2 : 1))

        payload.appendLE(UInt32(40))
        payload.appendLE(UInt32(23))
        payload.appendLE(UInt32((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24))
        payload.append(0) // depth
        payload.append(contentsOf: [0, 0, 0])
        payload.appendLE(fixed1616(positionX))
        payload.appendLE(fixed1616(positionY))
        payload.appendLE(Int32(0))
        payload.appendLE(UInt32(truncatingIfNeeded: mask))
        payload.appendLE(UInt16(truncatingIfNeeded: motion))
        payload.appendLE(UInt16(3)) // dock primary flavor
        payload.appendLE(fixed1616(progress))

        if includeVelocity {
            payload.appendLE(UInt32(28))
            payload.appendLE(UInt32(9)) // velocity event
            payload.appendLE(UInt32(0))
            payload.append(1) // depth
            payload.append(contentsOf: [0, 0, 0])
            payload.appendLE(fixed1616(velocityX))
            payload.appendLE(fixed1616(velocityY))
            payload.appendLE(Int32(0))
        }
        return payload
    }

    private static func fixed1616(_ value: Double) -> Int32 {
        let fixed = Int32(truncatingIfNeeded: Int64(value * 65_536.0))
        if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }

    // MARK: Empty-desktop yank guard

    /// Landing on a Space with no windows makes macOS activate an app whose
    /// window lives elsewhere, and the Dock follows that window back out. The
    /// fix (from noswoosh) is to be the activation ourselves on landing: this
    /// app has no windows while idle, so nothing can order an off-Space window in.
    func spaceHasWindows(_ spaceID: UInt64) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windowIDs = windows.compactMap { window -> UInt32? in
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return window[kCGWindowNumber as String] as? UInt32
        }
        guard !windowIDs.isEmpty else { return false }
        let spaces = SLSCopySpacesForWindows(cid, 0x7, windowIDs as CFArray)
            .takeRetainedValue() as? [NSNumber] ?? []
        return spaces.contains { $0.uint64Value == spaceID }
    }

    func activeSpaceHasWindows() -> Bool {
        spaceHasWindows(SLSGetActiveSpace(cid))
    }
}

// MARK: - Event field constants

enum GesturePhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
}

enum Field {
    static let cgsEventType = CGEventField(rawValue: 55)!
    static let gestureHIDType = CGEventField(rawValue: 110)!
    static let swipeMask = CGEventField(rawValue: 115)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let swipeProgress = CGEventField(rawValue: 124)!
    static let swipePositionX = CGEventField(rawValue: 125)!
    static let swipePositionY = CGEventField(rawValue: 126)!
    static let swipeVelocityX = CGEventField(rawValue: 129)!
    static let swipeVelocityY = CGEventField(rawValue: 130)!
    static let gesturePhase = CGEventField(rawValue: 132)!
    static let iohidPayload: UInt16 = 4205
}

enum EventType {
    static let gesture: Int64 = 29
    static let dockControl: Int64 = 30
}

enum HIDType {
    static let dockSwipe: Int64 = 23
}

enum GestureMotion {
    static let horizontal: Int64 = 1
}

private extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Int32) {
        appendLE(UInt32(bitPattern: value))
    }
}

extension Notification.Name {
    static let fasterSpacesDidSwitch = Notification.Name("FasterSpacesDidSwitch")
    static let fasterSpacesStatusDidChange = Notification.Name("FasterSpacesStatusDidChange")
    static let fasterSpacesLogDidChange = Notification.Name("FasterSpacesLogDidChange")
    static let fasterSpacesShowDiagnostics = Notification.Name("FasterSpacesShowDiagnostics")
}
