import AppKit
import CoreGraphics
import Foundation

/// Superkey-style keyboard utilities, implemented inside the same event tap as
/// the Spaces gesture:
///
///   - an editable Caps Lock layer (or another layer key) whose unmapped keys
///     pass through unchanged by default,
///   - per-key layer overrides and quick presets (WASD/HJKL/IJKL arrows,
///     home-row symbols/functions, Space=Return, Delete=Forward Delete),
///   - an optional "add Hyper modifiers to unmapped keys" mode,
///   - paste without formatting, Home/End on lines,
///   - double-Shift / both-Shift Caps Lock, quick-Shift parentheses.
///
/// Every remap is opt-in. The class is called from the event-tap callback on
/// the main run loop and never blocks; synthetic events are tagged so the tap
/// passes them through instead of remapping its own output.
final class KeyboardEnhancer {
    static let shared = KeyboardEnhancer()

    /// Tag for our synthetic keyboard events. The gesture code uses a different
    /// tag ("FSPS") so the two streams cannot collide.
    static let eventTag: Int64 = 0x4B45_5942 // "KEYB"

    private enum KeyCode {
        static let capsLock: CGKeyCode = 57
        static let leftShift: CGKeyCode = 56
        static let rightShift: CGKeyCode = 60
        static let leftCommand: CGKeyCode = 55
        static let rightCommand: CGKeyCode = 54
        static let leftOption: CGKeyCode = 58
        static let rightOption: CGKeyCode = 61
        static let leftControl: CGKeyCode = 59
        static let rightControl: CGKeyCode = 62
        static let delete: CGKeyCode = 51
        static let forwardDelete: CGKeyCode = 117
        static let home: CGKeyCode = 115
        static let end: CGKeyCode = 119
        static let leftArrow: CGKeyCode = 123
        static let rightArrow: CGKeyCode = 124
        static let upArrow: CGKeyCode = 126
        static let downArrow: CGKeyCode = 125
        static let returnKey: CGKeyCode = 36
        static let v: CGKeyCode = 9
        static let space: CGKeyCode = 49
        static let escape: CGKeyCode = 53
    }

    private var hyperActive = false
    private var hyperSourceDown = false
    private var capsDown = false
    private var capsPressedAt: CFTimeInterval = 0
    private var capsSessionUsed = false
    private var ignoreCapsUntil: CFTimeInterval = 0

    private var leftShiftDown = false
    private var rightShiftDown = false
    private var shiftPressedAt: CFTimeInterval = 0
    private var shiftSessionUsed = false
    private var lastShiftRelease: CFTimeInterval = 0
    private var bothShiftTriggered = false

    private var rightCommandDown = false
    private var rightOptionDown = false

    /// Keys whose physical keyDown we replaced with a one-shot synthetic press.
    private var swallowedKeyUps = Set<CGKeyCode>()
    /// Keys whose physical keyDown we forwarded with hyper flags; the matching
    /// keyUp must also be forwarded so apps do not see a stuck key.
    private var forwardedKeys = Set<CGKeyCode>()

    private init() {}

    var isHyperActive: Bool { hyperActive }

    // MARK: - Entry points

    /// Returns true when the flagsChanged event must be swallowed.
    func handleFlagsChanged(_ event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let now = CACurrentMediaTime()

        switch keyCode {
        case KeyCode.capsLock:
            return handleCapsLock(now: now)
        case KeyCode.leftShift, KeyCode.rightShift:
            return handleShift(keyCode: keyCode, now: now)
        case KeyCode.rightCommand:
            rightCommandDown.toggle()
            if hyperSourceIs(.rightCommand) {
                setHyper(rightCommandDown)
                return true
            }
            return false
        case KeyCode.rightOption:
            rightOptionDown.toggle()
            if hyperSourceIs(.rightOption) {
                setHyper(rightOptionDown)
                return true
            }
            return false
        case KeyCode.rightControl:
            if hyperSourceIs(.rightControl) {
                hyperSourceDown.toggle()
                setHyper(hyperSourceDown)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Handles a keyDown. Returns true when the original event must be
    /// swallowed. Synthetic presses are posted inside.
    func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let settings = SettingsStore.shared

        if capsDown || leftShiftDown || rightShiftDown {
            capsSessionUsed = capsSessionUsed || capsDown
            shiftSessionUsed = shiftSessionUsed || leftShiftDown || rightShiftDown
        }

        // 1. Right-Command + V: paste without formatting.
        if settings.pastePlainEnabled,
           rightCommandDown,
           !hyperSourceIs(.rightCommand),
           keyCode == KeyCode.v,
           !flags.contains(.maskShift),
           !flags.contains(.maskAlternate) {
            postOneShot(KeyCode.v, flags: [.maskAlternate, .maskShift, .maskCommand])
            swallowedKeyUps.insert(keyCode)
            return true
        }

        // 2. Home / End operate on lines.
        if settings.homeEndLines, keyCode == KeyCode.home || keyCode == KeyCode.end {
            var outputFlags = flags
            outputFlags.remove(.maskAlphaShift)
            outputFlags.insert(.maskCommand)
            postOneShot(keyCode == KeyCode.home ? KeyCode.leftArrow : KeyCode.rightArrow,
                        flags: outputFlags)
            swallowedKeyUps.insert(keyCode)
            return true
        }

        // 3. Shift+Delete remains a layer-independent convenience. A
        // Hyper+Delete mapping (if any) is handled by the editable layer below.
        if keyCode == KeyCode.delete, settings.shiftDeleteForward, flags.contains(.maskShift) {
            var outputFlags = flags
            outputFlags.remove(.maskAlphaShift)
            outputFlags.remove(.maskShift)
            postOneShot(KeyCode.forwardDelete, flags: outputFlags)
            swallowedKeyUps.insert(keyCode)
            return true
        }

        // 4. Caps Lock layer. Unmapped keys are passthrough by default.
        if hyperActive {
            switch resolveLayer(keyCode: keyCode, settings: settings, originalFlags: flags) {
            case .passthrough:
                Log.debug("Layer passthrough for key \(keyCode)")
                return false
            case .swallow:
                Log.debug("Layer swallows key \(keyCode)")
                swallowedKeyUps.insert(keyCode)
                return true
            case .send(let code, let outputFlags):
                Log.debug("Layer maps key \(keyCode) -> \(code)")
                postOneShot(code, flags: outputFlags)
                swallowedKeyUps.insert(keyCode)
                return true
            case .forward(let outputFlags):
                Log.debug("Layer forwards key \(keyCode) with added modifiers")
                postKeyDown(keyCode, flags: outputFlags)
                forwardedKeys.insert(keyCode)
                return true
            }
        }

        return false
    }

    /// Handles a keyUp. Returns true when the original event must be swallowed.
    func handleKeyUp(_ event: CGEvent) -> Bool {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if swallowedKeyUps.remove(keyCode) != nil {
            return true
        }

        if forwardedKeys.remove(keyCode) != nil {
            var flags = event.flags
            flags.remove(.maskAlphaShift)
            flags.formUnion(hyperFlags(for: SettingsStore.shared))
            postKeyUp(keyCode, flags: flags)
            return true
        }

        return false
    }

    // MARK: - Caps Lock

    private func handleCapsLock(now: CFTimeInterval) -> Bool {
        let settings = SettingsStore.shared
        let sourceIsCaps = settings.hyperKeyEnabled && settings.hyperKeySource == 0
        // Quick-press behaviour is part of the Hyper key: without Hyper, Caps
        // Lock must keep its native toggle semantics.
        guard sourceIsCaps else { return false }
        let quickAction = settings.capsLockTapAction
        // A synthetic Caps Lock toggle can echo back as another flagsChanged.
        if now < ignoreCapsUntil {
            return true
        }

        capsDown.toggle()

        if capsDown {
            capsPressedAt = now
            capsSessionUsed = false

            // Shift + Caps Lock toggles Caps Lock instead of engaging Hyper.
            if settings.shiftCapsCapsLock, liveFlags().contains(.maskShift) {
                toggleCapsLock()
                capsSessionUsed = true
                return true
            }

            if sourceIsCaps {
                setHyper(true)
            }
            return true
        }

        // Released.
        let duration = now - capsPressedAt
        if sourceIsCaps {
            setHyper(false)
        }
        let quick = duration < max(settings.capsQuickPressDuration, 0.15) && !capsSessionUsed
        if quick {
            switch quickAction {
            case 1:
                postOneShot(KeyCode.escape, flags: [])
            case 2:
                toggleCapsLock()
            default:
                break
            }
        }
        return true
    }

    // MARK: - Shift

    private func handleShift(keyCode: CGKeyCode, now: CFTimeInterval) -> Bool {
        let settings = SettingsStore.shared
        let wasDown = keyCode == KeyCode.leftShift ? leftShiftDown : rightShiftDown
        if keyCode == KeyCode.leftShift {
            leftShiftDown.toggle()
        } else {
            rightShiftDown.toggle()
        }
        let isDown = !wasDown

        if isDown {
            shiftPressedAt = now
            shiftSessionUsed = false
            bothShiftTriggered = false

            if settings.bothShiftCapsLock, leftShiftDown, rightShiftDown {
                bothShiftTriggered = true
                toggleCapsLock()
            }
            // A double-tap is measured from releases; remember the press time
            // only for quick-Shift parentheses.
            return false
        }

        let duration = now - shiftPressedAt
        let otherModifiersHeld = !liveFlags().intersection([.maskCommand, .maskAlternate]).isEmpty

        if settings.doubleShiftCapsLock, !bothShiftTriggered,
           now - lastShiftRelease < 0.35 {
            toggleCapsLock()
            lastShiftRelease = 0
            return false
        }
        lastShiftRelease = now

        if settings.quickShiftParens, !shiftSessionUsed, duration < 0.30, !otherModifiersHeld {
            let key: CGKeyCode = keyCode == KeyCode.leftShift ? 25 : 29
            postOneShot(key, flags: [.maskShift])
        }
        return false
    }

    // MARK: - Hyper

    private func hyperSourceIs(_ source: HyperSource) -> Bool {
        let settings = SettingsStore.shared
        guard settings.hyperKeyEnabled, settings.hyperKeySource == source.rawValue else {
            return false
        }
        return true
    }

    private enum HyperSource: Int {
        case capsLock = 0
        case rightCommand = 1
        case rightOption = 2
        case rightControl = 3
    }

    private func setHyper(_ active: Bool) {
        guard hyperActive != active else { return }
        hyperActive = active
        if !active {
            // Nothing to release explicitly; every forwarded key emits a
            // matching keyUp when the user releases it.
        }
    }

    private func hyperFlags(for settings: SettingsStore) -> CGEventFlags {
        var flags: CGEventFlags = []
        if settings.hyperIncludeControl { flags.insert(.maskControl) }
        if settings.hyperIncludeOption { flags.insert(.maskAlternate) }
        if settings.hyperIncludeCommand { flags.insert(.maskCommand) }
        if settings.hyperIncludeShift { flags.insert(.maskShift) }
        return flags
    }

    // MARK: - Layer resolution

    private enum LayerResolution {
        case passthrough
        case swallow
        case send(CGKeyCode, CGEventFlags)
        case forward(CGEventFlags)
    }

    private func resolveLayer(
        keyCode: CGKeyCode,
        settings: SettingsStore,
        originalFlags: CGEventFlags
    ) -> LayerResolution {
        if let mapping = settings.layerMappings.last(where: { $0.sourceKeyCode == UInt16(keyCode) }) {
            switch mapping.action {
            case .passthrough:
                return .passthrough
            case .swallow:
                return .swallow
            case .send:
                return .send(CGKeyCode(mapping.targetKeyCode), mapping.flags)
            }
        }

        switch settings.layerDefaultAction {
        case 1: // Add Hyper modifiers (legacy behavior)
            var outputFlags = originalFlags
            outputFlags.remove(.maskAlphaShift)
            outputFlags.formUnion(hyperFlags(for: settings))
            return .forward(outputFlags)
        case 2:
            return .swallow
        default:
            return .passthrough
        }
    }

    // MARK: - Key synthesis

    private func liveFlags() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState)
    }

    private func postOneShot(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        postKeyDown(keyCode, flags: flags)
        postKeyUp(keyCode, flags: flags)
    }

    private func postKeyDown(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cgSessionEventTap)
    }

    private func postKeyUp(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cgSessionEventTap)
    }

    private func toggleCapsLock() {
        ignoreCapsUntil = CACurrentMediaTime() + 0.20
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: KeyCode.capsLock, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: KeyCode.capsLock, keyDown: false)
        else {
            return
        }
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    /// Clears any held state when the tap is disabled or the app is quitting.
    func reset() {
        hyperActive = false
        hyperSourceDown = false
        capsDown = false
        leftShiftDown = false
        rightShiftDown = false
        rightCommandDown = false
        rightOptionDown = false
        swallowedKeyUps.removeAll()
        forwardedKeys.removeAll()
    }
}
