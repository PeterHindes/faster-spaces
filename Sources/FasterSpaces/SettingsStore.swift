import Combine
import Foundation

/// User-facing preferences, persisted in UserDefaults. The event tap reads
/// these directly, so changes take effect on the next gesture.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let enabled = "enabled"
        static let multiSpaceEnabled = "multiSpaceEnabled"
        static let progressPerSpace = "progressPerSpace"
        static let maximumSpacesPerSwipe = "maximumSpacesPerSwipe"
        static let invertDirection = "invertDirection"
        static let yankGuardEnabled = "yankGuardEnabled"
        static let showSpaceInMenuBar = "showSpaceInMenuBar"
        static let debugLogging = "debugLogging"
        static let hapticFeedback = "hapticFeedback"
        static let completedOnboarding = "completedOnboarding"
    }

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    @Published var multiSpaceEnabled: Bool {
        didSet { defaults.set(multiSpaceEnabled, forKey: Key.multiSpaceEnabled) }
    }

    /// Normalized swipe progress required for each additional Space. Tuned
    /// against real trackpad gesture logs; lower means more Spaces per swipe.
    @Published var progressPerSpace: Double {
        didSet { defaults.set(progressPerSpace, forKey: Key.progressPerSpace) }
    }

    @Published var maximumSpacesPerSwipe: Int {
        didSet { defaults.set(maximumSpacesPerSwipe, forKey: Key.maximumSpacesPerSwipe) }
    }

    @Published var invertDirection: Bool {
        didSet { defaults.set(invertDirection, forKey: Key.invertDirection) }
    }

    @Published var yankGuardEnabled: Bool {
        didSet { defaults.set(yankGuardEnabled, forKey: Key.yankGuardEnabled) }
    }

    @Published var showSpaceInMenuBar: Bool {
        didSet { defaults.set(showSpaceInMenuBar, forKey: Key.showSpaceInMenuBar) }
    }

    @Published var debugLogging: Bool {
        didSet { defaults.set(debugLogging, forKey: Key.debugLogging) }
    }

    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: Key.hapticFeedback) }
    }

    @Published var completedOnboarding: Bool {
        didSet { defaults.set(completedOnboarding, forKey: Key.completedOnboarding) }
    }

    @Published private(set) var launchAtLogin: Bool

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        multiSpaceEnabled = defaults.object(forKey: Key.multiSpaceEnabled) as? Bool ?? true
        progressPerSpace = defaults.object(forKey: Key.progressPerSpace) as? Double ?? 0.20
        maximumSpacesPerSwipe = defaults.object(forKey: Key.maximumSpacesPerSwipe) as? Int ?? 4
        invertDirection = defaults.bool(forKey: Key.invertDirection)
        yankGuardEnabled = defaults.object(forKey: Key.yankGuardEnabled) as? Bool ?? true
        showSpaceInMenuBar = defaults.bool(forKey: Key.showSpaceInMenuBar)
        debugLogging = defaults.bool(forKey: Key.debugLogging)
        hapticFeedback = defaults.object(forKey: Key.hapticFeedback) as? Bool ?? true
        completedOnboarding = defaults.bool(forKey: Key.completedOnboarding)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: Derived

    /// Progress per extra Space. The gesture's normalized travel typically
    /// peaks around 0.2 for an ordinary swipe and 0.5+ for a long one, so 0.20
    /// is a deliberate extra Space and 0.08 is a short, sensitive hop.
    var effectiveProgressPerSpace: Double {
        min(max(progressPerSpace, 0.08), 0.30)
    }

    var maxSpaces: Int {
        min(max(maximumSpacesPerSwipe, 1), 8)
    }
}
