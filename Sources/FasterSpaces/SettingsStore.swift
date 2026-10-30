import Combine
import Foundation

/// User-facing preferences, persisted in UserDefaults. The event tap reads
/// these directly, so changes take effect on the next gesture or keystroke.
///
/// The app grew from a single Spaces gesture into three cooperating feature
/// sets (Faster Spaces, the New Window Plz window switcher, and the Superkey
/// keyboard utilities). Every feature is individually switchable; defaults
/// keep the original Spaces behaviour and add the window swipe on the finger
/// count macOS is not using for Spaces.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        // Spaces
        static let enabled = "enabled"
        static let multiSpaceEnabled = "multiSpaceEnabled"
        static let subtleTransitionEnabled = "subtleTransitionEnabled"
        static let progressPerSpace = "progressPerSpace"
        static let maximumSpacesPerSwipe = "maximumSpacesPerSwipe"
        static let invertDirection = "invertDirection"
        static let yankGuardEnabled = "yankGuardEnabled"
        static let showSpaceInMenuBar = "showSpaceInMenuBar"
        static let debugLogging = "debugLogging"
        static let hapticFeedback = "hapticFeedback"
        static let completedOnboarding = "completedOnboarding"

        // Fingers
        static let spacesFingersMode = "spacesFingersMode"
        static let windowSwipeFingers = "windowSwipeFingers"

        // Windows
        static let windowSwipeEnabled = "windowSwipeEnabled"
        static let windowSwipeDistance = "windowSwipeDistance"
        static let windowSwipeMaxWindows = "windowSwipeMaxWindows"
        static let windowSwipeInvertDirection = "windowSwipeInvertDirection"
        static let windowSwipeRaiseOnRelease = "windowSwipeRaiseOnRelease"
        static let windowSwitcherEnabled = "windowSwitcherEnabled"
        static let previousSpaceEnabled = "previousSpaceEnabled"
        static let windowHUDEnabled = "windowHUDEnabled"
        static let windowSwitcherVisibleCount = "windowSwitcherVisibleCount"
        static let windowSwipeUIStyle = "windowSwipeUIStyle"
        static let windowSnapshotsEnabled = "windowSnapshotsEnabled"
        static let autoRestartForScreenCapture = "autoRestartForScreenCapture"

        // Superkey keyboard features
        static let hyperKeyEnabled = "hyperKeyEnabled"
        static let hyperKeySource = "hyperKeySource"
        static let hyperIncludeControl = "hyperIncludeControl"
        static let hyperIncludeOption = "hyperIncludeOption"
        static let hyperIncludeCommand = "hyperIncludeCommand"
        static let hyperIncludeShift = "hyperIncludeShift"
        static let capsLockTapAction = "capsLockTapAction"
        static let capsQuickPressDuration = "capsQuickPressDuration"
        static let capsSpaceEnter = "capsSpaceEnter"
        static let capsWASDArrows = "capsWASDArrows"
        static let capsHJKLArrows = "capsHJKLArrows"
        static let capsIJKLArrows = "capsIJKLArrows"
        static let capsHomeRowMode = "capsHomeRowMode"
        static let doubleShiftCapsLock = "doubleShiftCapsLock"
        static let bothShiftCapsLock = "bothShiftCapsLock"
        static let shiftCapsCapsLock = "shiftCapsCapsLock"
        static let quickShiftParens = "quickShiftParens"
        static let hyperDeleteForward = "hyperDeleteForward"
        static let shiftDeleteForward = "shiftDeleteForward"
        static let pastePlainEnabled = "pastePlainEnabled"
        static let homeEndLines = "homeEndLines"
        static let layerDefaultAction = "layerDefaultAction"
        static let keyboardLayerMappings = "keyboardLayerMappings"
        static let seekEnabled = "seekEnabled"
        static let seekTrigger = "seekTrigger"

        // Dock clicks (New Window Plz)
        static let dockClicksEnabled = "dockClicksEnabled"
        static let dockDisableControlClick = "dockDisableControlClick"
    }

    private let defaults = UserDefaults.standard

    // MARK: Spaces

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    @Published var multiSpaceEnabled: Bool {
        didSet { defaults.set(multiSpaceEnabled, forKey: Key.multiSpaceEnabled) }
    }

    /// A short out-and-in slide around the instant switch. Off means a hard cut.
    @Published var subtleTransitionEnabled: Bool {
        didSet { defaults.set(subtleTransitionEnabled, forKey: Key.subtleTransitionEnabled) }
    }

    /// Normalized swipe progress required for each additional Space.
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

    // MARK: Finger assignment

    /// 0 = automatic (read macOS), 3 = force three, 4 = force four.
    @Published var spacesFingersMode: Int {
        didSet {
            defaults.set(spacesFingersMode, forKey: Key.spacesFingersMode)
            NotificationCenter.default.post(name: .fasterSpacesFingerSettingsDidChange, object: nil)
        }
    }

    /// 0 = the other finger count, 3 = force three, 4 = force four.
    @Published var windowSwipeFingers: Int {
        didSet {
            defaults.set(windowSwipeFingers, forKey: Key.windowSwipeFingers)
            NotificationCenter.default.post(name: .fasterSpacesFingerSettingsDidChange, object: nil)
        }
    }

    // MARK: Windows

    @Published var windowSwipeEnabled: Bool {
        didSet { defaults.set(windowSwipeEnabled, forKey: Key.windowSwipeEnabled) }
    }

    /// Normalized horizontal travel required for each additional window.
    @Published var windowSwipeDistance: Double {
        didSet { defaults.set(windowSwipeDistance, forKey: Key.windowSwipeDistance) }
    }

    @Published var windowSwipeMaxWindows: Int {
        didSet { defaults.set(windowSwipeMaxWindows, forKey: Key.windowSwipeMaxWindows) }
    }

    @Published var windowSwipeInvertDirection: Bool {
        didSet { defaults.set(windowSwipeInvertDirection, forKey: Key.windowSwipeInvertDirection) }
    }

    /// Preserve the current window order by moving the selection only and
    /// raising the selected window when the fingers lift. This avoids the
    /// z-order reversal caused by raising every intermediate window.
    @Published var windowSwipeRaiseOnRelease: Bool {
        didSet { defaults.set(windowSwipeRaiseOnRelease, forKey: Key.windowSwipeRaiseOnRelease) }
    }

    /// The Option-Tab current-Space window switcher (from New Window Plz).
    @Published var windowSwitcherEnabled: Bool {
        didSet { defaults.set(windowSwitcherEnabled, forKey: Key.windowSwitcherEnabled) }
    }

    /// Option-` jumps back to the previous Space (from New Window Plz).
    @Published var previousSpaceEnabled: Bool {
        didSet { defaults.set(previousSpaceEnabled, forKey: Key.previousSpaceEnabled) }
    }

    @Published var windowHUDEnabled: Bool {
        didSet { defaults.set(windowHUDEnabled, forKey: Key.windowHUDEnabled) }
    }

    @Published var windowSwitcherVisibleCount: Int {
        didSet { defaults.set(windowSwitcherVisibleCount, forKey: Key.windowSwitcherVisibleCount) }
    }

    /// 0 = compact Spaces-style strip, 1 = the full New Window Plz switcher.
    @Published var windowSwipeUIStyle: Int {
        didSet { defaults.set(windowSwipeUIStyle, forKey: Key.windowSwipeUIStyle) }
    }

    /// Optional live window thumbnails. Requires Screen Recording.
    @Published var windowSnapshotsEnabled: Bool {
        didSet { defaults.set(windowSnapshotsEnabled, forKey: Key.windowSnapshotsEnabled) }
    }

    /// Relaunch automatically when Screen Recording is granted so the new
    /// permission is active in a fresh process.
    @Published var autoRestartForScreenCapture: Bool {
        didSet { defaults.set(autoRestartForScreenCapture, forKey: Key.autoRestartForScreenCapture) }
    }

    // MARK: Superkey keyboard utilities

    @Published var hyperKeyEnabled: Bool {
        didSet { defaults.set(hyperKeyEnabled, forKey: Key.hyperKeyEnabled) }
    }

    /// 0 = Caps Lock, 1 = right Command, 2 = right Option, 3 = right Control.
    @Published var hyperKeySource: Int {
        didSet { defaults.set(hyperKeySource, forKey: Key.hyperKeySource) }
    }

    @Published var hyperIncludeControl: Bool {
        didSet { defaults.set(hyperIncludeControl, forKey: Key.hyperIncludeControl) }
    }

    @Published var hyperIncludeOption: Bool {
        didSet { defaults.set(hyperIncludeOption, forKey: Key.hyperIncludeOption) }
    }

    @Published var hyperIncludeCommand: Bool {
        didSet { defaults.set(hyperIncludeCommand, forKey: Key.hyperIncludeCommand) }
    }

    @Published var hyperIncludeShift: Bool {
        didSet { defaults.set(hyperIncludeShift, forKey: Key.hyperIncludeShift) }
    }

    /// 0 = do nothing, 1 = Escape, 2 = Caps Lock toggle.
    @Published var capsLockTapAction: Int {
        didSet { defaults.set(capsLockTapAction, forKey: Key.capsLockTapAction) }
    }

    @Published var capsQuickPressDuration: Double {
        didSet { defaults.set(capsQuickPressDuration, forKey: Key.capsQuickPressDuration) }
    }

    @Published var capsSpaceEnter: Bool {
        didSet { defaults.set(capsSpaceEnter, forKey: Key.capsSpaceEnter) }
    }

    @Published var capsWASDArrows: Bool {
        didSet { defaults.set(capsWASDArrows, forKey: Key.capsWASDArrows) }
    }

    @Published var capsHJKLArrows: Bool {
        didSet { defaults.set(capsHJKLArrows, forKey: Key.capsHJKLArrows) }
    }

    @Published var capsIJKLArrows: Bool {
        didSet { defaults.set(capsIJKLArrows, forKey: Key.capsIJKLArrows) }
    }

    /// 0 = off, 1 = symbol row, 2 = function row.
    @Published var capsHomeRowMode: Int {
        didSet { defaults.set(capsHomeRowMode, forKey: Key.capsHomeRowMode) }
    }

    @Published var doubleShiftCapsLock: Bool {
        didSet { defaults.set(doubleShiftCapsLock, forKey: Key.doubleShiftCapsLock) }
    }

    @Published var bothShiftCapsLock: Bool {
        didSet { defaults.set(bothShiftCapsLock, forKey: Key.bothShiftCapsLock) }
    }

    @Published var shiftCapsCapsLock: Bool {
        didSet { defaults.set(shiftCapsCapsLock, forKey: Key.shiftCapsCapsLock) }
    }

    @Published var quickShiftParens: Bool {
        didSet { defaults.set(quickShiftParens, forKey: Key.quickShiftParens) }
    }

    @Published var hyperDeleteForward: Bool {
        didSet { defaults.set(hyperDeleteForward, forKey: Key.hyperDeleteForward) }
    }

    @Published var shiftDeleteForward: Bool {
        didSet { defaults.set(shiftDeleteForward, forKey: Key.shiftDeleteForward) }
    }

    @Published var pastePlainEnabled: Bool {
        didSet { defaults.set(pastePlainEnabled, forKey: Key.pastePlainEnabled) }
    }

    @Published var homeEndLines: Bool {
        didSet { defaults.set(homeEndLines, forKey: Key.homeEndLines) }
    }

    /// 0 = passthrough, 1 = add Hyper modifiers, 2 = swallow.
    @Published var layerDefaultAction: Int {
        didSet { defaults.set(layerDefaultAction, forKey: Key.layerDefaultAction) }
    }

    /// Editable Caps Lock layer overrides. Unmapped keys follow
    /// `layerDefaultAction` (passthrough by default).
    @Published var layerMappings: [KeyboardLayerMapping] {
        didSet {
            if let data = try? JSONEncoder().encode(layerMappings) {
                defaults.set(data, forKey: Key.keyboardLayerMappings)
            }
        }
    }

    /// Accessibility-only text finder ("Seek"). No screen recording and no OCR.
    @Published var seekEnabled: Bool {
        didSet { defaults.set(seekEnabled, forKey: Key.seekEnabled) }
    }

    /// 0 = Hyper+S, 1 = Control+Option+Command+F.
    @Published var seekTrigger: Int {
        didSet { defaults.set(seekTrigger, forKey: Key.seekTrigger) }
    }

    // MARK: Dock clicks

    @Published var dockClicksEnabled: Bool {
        didSet { defaults.set(dockClicksEnabled, forKey: Key.dockClicksEnabled) }
    }

    @Published var dockDisableControlClick: Bool {
        didSet { defaults.set(dockDisableControlClick, forKey: Key.dockDisableControlClick) }
    }

    @Published private(set) var launchAtLogin: Bool

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        multiSpaceEnabled = defaults.object(forKey: Key.multiSpaceEnabled) as? Bool ?? true
        subtleTransitionEnabled = defaults.object(forKey: Key.subtleTransitionEnabled) as? Bool ?? true
        progressPerSpace = defaults.object(forKey: Key.progressPerSpace) as? Double ?? 0.20
        maximumSpacesPerSwipe = defaults.object(forKey: Key.maximumSpacesPerSwipe) as? Int ?? 4
        invertDirection = defaults.bool(forKey: Key.invertDirection)
        yankGuardEnabled = defaults.object(forKey: Key.yankGuardEnabled) as? Bool ?? true
        showSpaceInMenuBar = defaults.bool(forKey: Key.showSpaceInMenuBar)
        debugLogging = defaults.bool(forKey: Key.debugLogging)
        hapticFeedback = defaults.object(forKey: Key.hapticFeedback) as? Bool ?? true
        completedOnboarding = defaults.bool(forKey: Key.completedOnboarding)

        spacesFingersMode = defaults.object(forKey: Key.spacesFingersMode) as? Int ?? 0
        windowSwipeFingers = defaults.object(forKey: Key.windowSwipeFingers) as? Int ?? 0

        windowSwipeEnabled = defaults.object(forKey: Key.windowSwipeEnabled) as? Bool ?? true
        windowSwipeDistance = defaults.object(forKey: Key.windowSwipeDistance) as? Double ?? 0.14
        windowSwipeMaxWindows = defaults.object(forKey: Key.windowSwipeMaxWindows) as? Int ?? 6
        windowSwipeInvertDirection = defaults.bool(forKey: Key.windowSwipeInvertDirection)
        windowSwipeRaiseOnRelease = defaults.object(forKey: Key.windowSwipeRaiseOnRelease) as? Bool ?? true
        windowSwitcherEnabled = defaults.object(forKey: Key.windowSwitcherEnabled) as? Bool ?? true
        previousSpaceEnabled = defaults.object(forKey: Key.previousSpaceEnabled) as? Bool ?? true
        windowHUDEnabled = defaults.object(forKey: Key.windowHUDEnabled) as? Bool ?? true
        windowSwitcherVisibleCount = defaults.object(forKey: Key.windowSwitcherVisibleCount) as? Int ?? 7
        windowSwipeUIStyle = defaults.object(forKey: Key.windowSwipeUIStyle) as? Int ?? 0
        windowSnapshotsEnabled = defaults.bool(forKey: Key.windowSnapshotsEnabled)
        autoRestartForScreenCapture = defaults.object(forKey: Key.autoRestartForScreenCapture) as? Bool ?? true

        hyperKeyEnabled = defaults.object(forKey: Key.hyperKeyEnabled) as? Bool ?? true
        hyperKeySource = defaults.object(forKey: Key.hyperKeySource) as? Int ?? 0
        hyperIncludeControl = defaults.object(forKey: Key.hyperIncludeControl) as? Bool ?? true
        hyperIncludeOption = defaults.object(forKey: Key.hyperIncludeOption) as? Bool ?? true
        hyperIncludeCommand = defaults.object(forKey: Key.hyperIncludeCommand) as? Bool ?? true
        hyperIncludeShift = defaults.object(forKey: Key.hyperIncludeShift) as? Bool ?? true
        capsLockTapAction = defaults.object(forKey: Key.capsLockTapAction) as? Int ?? 2
        capsQuickPressDuration = defaults.object(forKey: Key.capsQuickPressDuration) as? Double ?? 0.4
        capsSpaceEnter = defaults.object(forKey: Key.capsSpaceEnter) as? Bool ?? true
        capsWASDArrows = defaults.object(forKey: Key.capsWASDArrows) as? Bool ?? true
        capsHJKLArrows = defaults.bool(forKey: Key.capsHJKLArrows)
        capsIJKLArrows = defaults.bool(forKey: Key.capsIJKLArrows)
        capsHomeRowMode = defaults.object(forKey: Key.capsHomeRowMode) as? Int ?? 0
        doubleShiftCapsLock = defaults.bool(forKey: Key.doubleShiftCapsLock)
        bothShiftCapsLock = defaults.object(forKey: Key.bothShiftCapsLock) as? Bool ?? true
        shiftCapsCapsLock = defaults.object(forKey: Key.shiftCapsCapsLock) as? Bool ?? true
        quickShiftParens = defaults.bool(forKey: Key.quickShiftParens)
        hyperDeleteForward = defaults.object(forKey: Key.hyperDeleteForward) as? Bool ?? true
        shiftDeleteForward = defaults.object(forKey: Key.shiftDeleteForward) as? Bool ?? true
        pastePlainEnabled = defaults.object(forKey: Key.pastePlainEnabled) as? Bool ?? true
        homeEndLines = defaults.bool(forKey: Key.homeEndLines)
        layerDefaultAction = defaults.object(forKey: Key.layerDefaultAction) as? Int ?? 0
        if let data = defaults.data(forKey: Key.keyboardLayerMappings),
           let decoded = try? JSONDecoder().decode([KeyboardLayerMapping].self, from: data) {
            layerMappings = decoded
        } else {
            layerMappings = []
        }
        seekEnabled = defaults.bool(forKey: Key.seekEnabled)
        seekTrigger = defaults.object(forKey: Key.seekTrigger) as? Int ?? 0

        dockClicksEnabled = defaults.object(forKey: Key.dockClicksEnabled) as? Bool ?? false
        dockDisableControlClick = defaults.object(forKey: Key.dockDisableControlClick) as? Bool ?? false
        launchAtLogin = LaunchAtLogin.isEnabled

        seedLayerMappingsIfNeeded()
        importLegacyPreferencesIfNeeded()
    }

    // MARK: Caps Lock layer

    private func seedLayerMappingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: Key.keyboardLayerMappings) == nil else { return }

        var presets: [KeyboardLayerPreset] = []
        if capsWASDArrows { presets.append(.wasdArrows) }
        if capsHJKLArrows { presets.append(.hjklArrows) }
        if capsIJKLArrows { presets.append(.ijklArrows) }
        if capsHomeRowMode == 1 { presets.append(.homeRowSymbols) }
        if capsHomeRowMode == 2 { presets.append(.homeRowFunctions) }
        if capsSpaceEnter { presets.append(.spaceReturn) }
        if hyperDeleteForward { presets.append(.deleteForward) }

        var bySource: [UInt16: KeyboardLayerMapping] = [:]
        for preset in presets {
            for mapping in preset.mappings { bySource[mapping.sourceKeyCode] = mapping }
        }
        layerMappings = bySource.values.sorted { $0.sourceKeyCode < $1.sourceKeyCode }
    }

    func upsertLayerMapping(_ mapping: KeyboardLayerMapping) {
        if let index = layerMappings.firstIndex(where: { $0.sourceKeyCode == mapping.sourceKeyCode }) {
            layerMappings[index] = mapping
        } else {
            layerMappings.append(mapping)
        }
    }

    func removeLayerMapping(id: UUID) {
        layerMappings.removeAll { $0.id == id }
    }

    func mergeLayerMappings(_ mappings: [KeyboardLayerMapping]) {
        for mapping in mappings { upsertLayerMapping(mapping) }
    }

    func applyLayerPreset(_ preset: KeyboardLayerPreset) {
        mergeLayerMappings(preset.mappings)
    }

    func clearLayerMappings() {
        layerMappings.removeAll()
    }

    var sortedLayerMappings: [KeyboardLayerMapping] {
        layerMappings.sorted {
            if $0.sourceKeyCode != $1.sourceKeyCode { return $0.sourceKeyCode < $1.sourceKeyCode }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func importLegacyPreferencesIfNeeded() {
        guard let legacy = UserDefaults(suiteName: "com.peter.newwindowplz") else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Key.windowSnapshotsEnabled) == nil,
           legacy.bool(forKey: "showWindowSnapshots") {
            windowSnapshotsEnabled = true
        }
        if defaults.object(forKey: Key.dockDisableControlClick) == nil,
           legacy.bool(forKey: "disableControlClick") {
            dockDisableControlClick = true
        }
        // New Window Plz had Dock monitoring enabled by default. If the old
        // install has per-app rules, keep those behaviors active here too.
        if defaults.object(forKey: Key.dockClicksEnabled) == nil,
           let ruleData = legacy.data(forKey: "dockClickRules.v1"),
           let rules = try? JSONDecoder().decode([DockAppRule].self, from: ruleData),
           !rules.isEmpty {
            dockClicksEnabled = true
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: Derived — Spaces

    /// Progress per extra Space. The gesture's normalized travel typically
    /// peaks around 0.2 for an ordinary swipe and 0.5+ for a long one, so 0.20
    /// is a deliberate extra Space and 0.08 is a short, sensitive hop.
    var effectiveProgressPerSpace: Double {
        min(max(progressPerSpace, 0.08), 0.30)
    }

    var maxSpaces: Int {
        min(max(maximumSpacesPerSwipe, 1), 8)
    }

    // MARK: Derived — fingers

    /// The finger count macOS uses for Spaces. A manual override wins; the
    /// automatic path reads the live trackpad preference.
    var spacesFingers: Int {
        if spacesFingersMode == 3 || spacesFingersMode == 4 {
            return spacesFingersMode
        }
        return FingerConfiguration.macOSFingerCount
    }

    /// The finger count used for the window swipe. "Other" follows the Spaces
    /// assignment, which is what "non-primary" means for this app.
    var windowFingers: Int {
        let spaces = spacesFingers
        if windowSwipeFingers == 3 || windowSwipeFingers == 4 {
            // Never steal the Spaces gesture. If the user picks the same count,
            // fall back to the other one and surface the correction in the UI.
            return windowSwipeFingers == spaces ? (spaces == 3 ? 4 : 3) : windowSwipeFingers
        }
        return spaces == 3 ? 4 : 3
    }

    var fingerSummary: String {
        "Spaces \(spacesFingers) · Windows \(windowFingers)"
    }

    /// A source description for the finger assignment, used by diagnostics.
    var fingerSourceDescription: String {
        if spacesFingersMode == 3 || spacesFingersMode == 4 {
            return "manual (\(spacesFingersMode))"
        }
        return FingerConfiguration.autoSourceDescription
    }

    // MARK: Derived — windows

    /// The Dock reports normalized gesture travel; the window switcher uses a
    /// slightly shorter default step than Spaces because a window row is
    /// usually shorter than a row of desktops.
    var effectiveWindowSwipeDistance: Double {
        min(max(windowSwipeDistance, 0.04), 0.30)
    }

    var maxWindowsPerSwipe: Int {
        min(max(windowSwipeMaxWindows, 1), 10)
    }

    var effectiveWindowVisibleCount: Int {
        min(max(windowSwitcherVisibleCount, 3), 9)
    }
}

extension Notification.Name {
    static let fasterSpacesFingerSettingsDidChange = Notification.Name("FasterSpacesFingerSettingsDidChange")
}
