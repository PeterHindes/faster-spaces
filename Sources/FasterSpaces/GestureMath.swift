import Foundation

/// Pure gesture math, shared by the Spaces and window swipe paths and covered
/// by `--self-test`. Keeping the sign conventions in one place makes a
/// direction regression visible without a trackpad.
enum SwipeMath {
    struct Initial {
        let direction: Int
        let steps: Int
        let anchor: Double
    }

    static func initial(
        progress: Double,
        threshold: Double,
        maxSteps: Int,
        invert: Bool
    ) -> Initial {
        let value = invert ? -progress : progress
        let direction = value >= 0 ? 1 : -1
        let safeThreshold = max(threshold, 0.001)
        let rawSteps = max(1, Int(abs(value) / safeThreshold))
        let steps = min(rawSteps, max(maxSteps, 1))
        let anchor = value - Double(direction * rawSteps) * safeThreshold
        return Initial(direction: direction, steps: steps, anchor: anchor)
    }

    static func desired(
        progress: Double,
        anchor: Double,
        threshold: Double,
        maxSteps: Int,
        invert: Bool
    ) -> Int {
        let value = invert ? -progress : progress
        let safeThreshold = max(threshold, 0.001)
        let raw = Int(((value - anchor) / safeThreshold).rounded(.towardZero))
        return min(max(raw, -maxSteps), maxSteps)
    }
}

/// Cyclic window selection. Windows are ordered front-to-back; moving forward
/// walks behind the current window and wraps at the back.
enum WindowSelection {
    static func initial(count: Int, reverse: Bool) -> Int {
        guard count > 1 else { return 0 }
        return reverse ? count - 1 : 1
    }

    static func advance(index: Int, count: Int, direction: Int, steps: Int = 1) -> Int {
        guard count > 0 else { return 0 }
        var result = min(max(index, 0), count - 1)
        for _ in 0..<max(steps, 1) {
            result = (result + direction + count) % count
        }
        return result
    }
}
