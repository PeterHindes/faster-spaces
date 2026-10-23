import AppKit

typealias CGSSymbolicHotKey = Int32
typealias CGSModifierFlags = UInt32

@_silgen_name("CGSGetSymbolicHotKeyValue")
private func CGSGetSymbolicHotKeyValue(
    _ hotKey: CGSSymbolicHotKey,
    _ outCharCode: UnsafeMutablePointer<UniChar>?,
    _ keyCode: UnsafeMutablePointer<CGKeyCode>?,
    _ flags: UnsafeMutablePointer<CGSModifierFlags>?
) -> CGError

@_silgen_name("CGSIsSymbolicHotKeyEnabled")
private func CGSIsSymbolicHotKeyEnabled(_ hotKey: CGSSymbolicHotKey) -> Bool

/// Ctrl+Left / Ctrl+Right are the default macOS "Move left/right a space"
/// shortcuts. Only intercept them while macOS still has those symbolic hotkeys
/// enabled and assigned to those exact keys; otherwise the keys belong to the
/// user's remapping and must pass through untouched.
enum KeyboardSpaceShortcut {
    private enum HotKey {
        static let moveLeft: CGSSymbolicHotKey = 79
        static let moveRight: CGSSymbolicHotKey = 81
    }

    static func direction(for event: CGEvent) -> Int? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == 123 || keyCode == 124 else { return nil }

        // Require Control and no other command modifier. This leaves
        // Ctrl+Shift+arrow, Ctrl+Option+arrow, etc. alone.
        let modifiers = event.flags.intersection(
            [.maskControl, .maskCommand, .maskAlternate, .maskShift]
        )
        guard modifiers == .maskControl else { return nil }

        let hotKey = keyCode == 123 ? HotKey.moveLeft : HotKey.moveRight
        guard CGSIsSymbolicHotKeyEnabled(hotKey) else { return nil }

        var registeredKeyCode: CGKeyCode = 0
        var registeredFlags: CGSModifierFlags = 0
        guard CGSGetSymbolicHotKeyValue(hotKey, nil, &registeredKeyCode, &registeredFlags) == .success
        else {
            return nil
        }
        guard registeredKeyCode == keyCode else { return nil }

        // NSEvent's control modifier bit is 0x40000. The Carbon symbolic
        // hotkey flags include that bit for the default Ctrl+arrow binding.
        let controlBit = UInt32(CGEventFlags.maskControl.rawValue)
        guard registeredFlags & controlBit != 0 else { return nil }

        return keyCode == 124 ? 1 : -1
    }
}
