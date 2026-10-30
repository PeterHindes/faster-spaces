import CoreGraphics

enum DockClickDecision: Equatable {
    case passThrough(DockPassReason)
    /// The modifier asks for the action the app is already configured to run,
    /// so the configured action is toggled off. The click must reach the Dock
    /// as a plain click, with Shift/Control stripped from the event.
    case passThroughAsRegularClick
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

        // A modifier toggles its action against the app's configured action.
        // If the app is already set to that action, the toggle turns the
        // configured behavior off and the Dock receives a plain click.
        if let modifierAction = Self.modifier(for: modifiers).action {
            if configuredAction == modifierAction {
                return .passThroughAsRegularClick
            }
            return .action(modifierAction)
        }

        guard let configuredAction, configuredAction != .unchanged else {
            return .passThrough(configuredAction == .unchanged ? .noChanges : .notConfigured)
        }
        return .action(configuredAction)
    }
}
