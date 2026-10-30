import CoreGraphics
import Foundation

struct AltTabWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let isHidden: Bool

    var displayTitle: String {
        windowTitle.isEmpty ? appName : windowTitle
    }

    var shortTitle: String {
        if displayTitle.count <= 26 {
            return displayTitle
        }
        return String(displayTitle.prefix(25)) + "…"
    }

    var cacheKey: String {
        String(windowID)
    }

    var appCacheKey: String {
        bundleIdentifier.isEmpty ? "pid:\(pid)" : bundleIdentifier
    }
}

struct AltTabScene: Equatable {
    var windows: [AltTabWindow]
    var selectedIndex: Int
    var showSnapshots: Bool
    var previousSelectedIndex: Int? = nil
    var selectionTransitionStart: TimeInterval? = nil
}

enum AltTabLayout {
    static let iconVisibleLimit = 7
    static let snapshotVisibleLimit = 5
}

enum AltTabSelection {
    static func initialIndex(count: Int, reverse: Bool) -> Int {
        guard count > 1 else { return 0 }
        return reverse ? count - 1 : 1
    }

    static func advance(index: Int, count: Int, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        let delta = reverse ? -1 : 1
        return (index + delta + count) % count
    }

    static func visibleRange(count: Int, selectedIndex: Int, maxVisible: Int = 7) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let visibleCount = min(count, maxVisible)
        guard count > visibleCount else { return 0..<count }
        let preferredStart = selectedIndex - visibleCount / 2
        let start = min(max(preferredStart, 0), count - visibleCount)
        return start..<(start + visibleCount)
    }
}
