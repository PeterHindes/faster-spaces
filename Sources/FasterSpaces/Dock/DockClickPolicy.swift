import CoreGraphics

enum DockClickDecision: Equatable {
    case passThrough(DockPassReason)
    case action(DockClickAction)
}

enum DockPassReason: String, Equatable {
    case disabled
    case noTile
    case applicationNotRunning
    case notConfigured
    case noChanges
    case modifierKey
}

/// The modifier that selected a Dock click action. Control wins when both
/// action modifiers are held. Command and Option are never represented here
/// because they keep their native Dock behavior.
enum DockClickModifier: Equatable {
    case none
    case shift
    case control

    var action: DockClickAction? {
        switch self {
        case .none: return nil
        case .shift: return .newWindow
        case .control: return .moveHere
        }
    }

    var statusPrefix: String {
        switch self {
        case .none: return ""
        case .shift: return "Shift-click: "
        case .control: return "Control-click: "
        }
    }
}

struct DockClickPolicy {
    /// Command and Option clicks retain their native Dock behavior. Shift and
    /// Control are action modifiers: Shift asks for a new window and Control
    /// asks to bring the existing window here.
    static let passThroughModifiers: CGEventFlags = [
        .maskAlternate, .maskCommand
    ]

    static func modifier(for flags: CGEventFlags) -> DockClickModifier {
        if flags.contains(.maskControl) { return .control }
        if flags.contains(.maskShift) { return .shift }
        return .none
    }

    func decide(isEnabled: Bool,
                tile: DockTile?,
                modifiers: CGEventFlags,
                configuredAction: DockClickAction?) -> DockClickDecision {
        guard isEnabled else { return .passThrough(.disabled) }
        guard let tile else { return .passThrough(.noTile) }
        guard tile.isRunning else { return .passThrough(.applicationNotRunning) }
        guard modifiers.intersection(Self.passThroughModifiers).isEmpty else {
            return .passThrough(.modifierKey)
        }

        // A modifier action overrides the app's default. If it matches the
        // configured action (for example Shift on an app already set to New
        // Window), the result is unchanged: the same action still runs.
        if let modifierAction = Self.modifier(for: modifiers).action {
            return .action(modifierAction)
        }

        guard let configuredAction, configuredAction != .unchanged else {
            return .passThrough(configuredAction == .unchanged ? .noChanges : .notConfigured)
        }
        return .action(configuredAction)
    }
}
