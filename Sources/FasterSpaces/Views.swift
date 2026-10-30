import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - View state

/// Small observable state shared by the settings, onboarding, and diagnostics
/// windows. Explicit ObservableObjects avoid SwiftUI's State macro, whose
/// plugin cannot run inside the restricted build sandbox used for this app.
final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var showResetConfirmation = false
    @Published var settingsTab = 0
    @Published var onboardingStep = 0
}

final class DiagnosticsModel: ObservableObject {
    static let shared = DiagnosticsModel()
    @Published var text = ""
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        text = Log.recent()
    }
}

// MARK: - Shared chrome

private struct SettingsHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Faster Spaces")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Spaces, windows, and keyboard — without the animation.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.70))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct SettingToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 1)
    }
}

private struct SettingPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    let detail: String?
    @Binding var selection: SelectionValue
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Picker(title, selection: $selection) { content }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }
}

private struct FingerSummaryRow: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(settings.spacesFingers) fingers for Spaces · \(settings.windowFingers) fingers for windows")
                    .font(.system(size: 11, weight: .medium))
                Text(settings.fingerSourceDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Swap") {
                let spaces = settings.spacesFingers
                let windows = settings.windowFingers
                settings.spacesFingersMode = windows
                settings.windowSwipeFingers = spaces
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }
}

private struct LayerModifierToggles: View {
    @Binding var mapping: KeyboardLayerMapping

    var body: some View {
        HStack(spacing: 3) {
            Toggle("⌃", isOn: $mapping.control)
            Toggle("⌥", isOn: $mapping.option)
            Toggle("⌘", isOn: $mapping.command)
            Toggle("⇧", isOn: $mapping.shift)
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .font(.caption2)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accessibility = AccessibilityManager.shared
    @ObservedObject private var screenCapture = ScreenCaptureStatusModel.shared
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var dockRules = AppRulesStore.shared
    @ObservedObject private var dockStatus = DockStatusModel.shared
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                SettingsHeader()
                compactStatus
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Picker("Section", selection: $ui.settingsTab) {
                Text("Spaces").tag(0)
                Text("Windows").tag(1)
                Text("Keyboard").tag(2)
                Text("Dock").tag(3)
                Text("General").tag(4)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            Group {
                switch ui.settingsTab {
                case 0: spacesTab
                case 1: windowsTab
                case 2: keyboardTab
                case 3: dockTab
                default: generalTab
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 720, height: 720)
        .onAppear {
            accessibility.refresh()
            screenCapture.refresh()
        }
        .alert("Reset Accessibility permission?", isPresented: $ui.showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { accessibility.resetPermission() }
        } message: {
            Text("macOS will forget the current Accessibility grant. Quit and reopen Faster Spaces, then grant permission again.")
        }
    }

    // MARK: Tabs

    private var spacesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(title: "The Spaces gesture", systemImage: "hand.draw") {
                    SettingToggle(
                        title: "Enable Faster Spaces",
                        detail: "Replace the animated macOS Space swipe with an instant switch.",
                        isOn: $settings.enabled
                    )
                    Divider()
                    SettingToggle(
                        title: "Direction HUD",
                        detail: "Two small desktop tiles slide in the direction of the switch. No screen recording.",
                        isOn: $settings.subtleTransitionEnabled
                    )
                    Divider()
                    FingerSummaryRow()
                    Divider()
                    SettingToggle(
                        title: "Reverse swipe direction",
                        detail: "Only needed if your setup reports the Spaces gesture backwards.",
                        isOn: $settings.invertDirection
                    )
                }

                SettingsCard(title: "Multiple Spaces", systemImage: "rectangle.stack") {
                    SettingToggle(
                        title: "Cross multiple Spaces in one swipe",
                        detail: "Keep swiping after the first Space to jump further.",
                        isOn: $settings.multiSpaceEnabled
                    )
                    if settings.multiSpaceEnabled {
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("Distance per Space")
                                    .font(.system(size: 11))
                                Spacer()
                                Text(distanceLabel)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.progressPerSpace, in: 0.08...0.30, step: 0.01)
                        }
                        Stepper(value: $settings.maximumSpacesPerSwipe, in: 1...8) {
                            Text("Maximum \(settings.maxSpaces) \(settings.maxSpaces == 1 ? "Space" : "Spaces") per swipe")
                                .font(.system(size: 11))
                        }
                    }
                }

                SettingsCard(title: "Keyboard Spaces", systemImage: "arrow.left.arrow.right") {
                    Text("Control+← / Control+→ still switch Spaces instantly while macOS has those shortcuts enabled. If you remap or disable them in System Settings, the keys pass through untouched.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private var windowsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(title: "Window swipe", systemImage: "macwindow.on.rectangle") {
                    SettingToggle(
                        title: "Switch windows with the non-primary swipe",
                        detail: "Use the finger count macOS is not using for Spaces to move through the current Space's windows, exactly like the Space swipe.",
                        isOn: $settings.windowSwipeEnabled
                    )
                    Divider()
                    FingerSummaryRow()
                    Divider()
                    SettingPicker(
                        title: "Spaces gesture",
                        detail: "Automatic reads the live macOS preference.",
                        selection: $settings.spacesFingersMode
                    ) {
                        Text("Automatic").tag(0)
                        Text("3 fingers").tag(3)
                        Text("4 fingers").tag(4)
                    }
                    SettingPicker(
                        title: "Window swipe",
                        detail: "“Other” means the finger count macOS is not using for Spaces.",
                        selection: $settings.windowSwipeFingers
                    ) {
                        Text("Other").tag(0)
                        Text("3 fingers").tag(3)
                        Text("4 fingers").tag(4)
                    }
                    SettingPicker(
                        title: "Swipe display",
                        detail: "Keep both switchers; choose what the physical swipe shows.",
                        selection: $settings.windowSwipeUIStyle
                    ) {
                        Text("Compact HUD").tag(0)
                        Text("Full-screen switcher").tag(1)
                    }
                    SettingToggle(
                        title: "Reverse window direction",
                        detail: "Independent of the Spaces direction setting. Swap only the window swipe.",
                        isOn: $settings.windowSwipeInvertDirection
                    )
                    SettingToggle(
                        title: "Raise window on release",
                        detail: "Move only the selection while your fingers are down, then raise the target once on release. Prevents the z-order between the current and target windows from reversing.",
                        isOn: $settings.windowSwipeRaiseOnRelease
                    )
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Distance per window")
                                .font(.system(size: 11))
                            Spacer()
                            Text("\(Int((settings.effectiveWindowSwipeDistance * 100).rounded()))%")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.windowSwipeDistance, in: 0.04...0.30, step: 0.01)
                    }
                    Stepper(value: $settings.windowSwipeMaxWindows, in: 1...10) {
                        Text("Maximum \(settings.maxWindowsPerSwipe) windows per swipe")
                            .font(.system(size: 11))
                    }
                    SettingToggle(
                        title: "Show the direction HUD",
                        detail: "Turn off both the compact HUD and the switcher for a silent swipe.",
                        isOn: $settings.windowHUDEnabled
                    )
                }

                SettingsCard(title: "Window thumbnails", systemImage: "photo.on.rectangle.angled") {
                    SettingToggle(
                        title: "Show live window previews",
                        detail: "Shown in the full-screen switcher, captured asynchronously after it opens. Requires Screen Recording; until granted, the switcher falls back to app icons.",
                        isOn: Binding(
                            get: { settings.windowSnapshotsEnabled },
                            set: { enabled in
                                settings.windowSnapshotsEnabled = enabled
                                if enabled, !screenCapture.isGranted {
                                    _ = screenCapture.request()
                                }
                            }
                        )
                    )
                    HStack(spacing: 8) {
                        Circle()
                            .fill(screenCapture.isGranted ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(screenCapture.isGranted
                             ? "Screen Recording granted"
                             : "Screen Recording required for previews")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !screenCapture.isGranted {
                            Button("Grant…") { _ = screenCapture.request() }
                                .controlSize(.mini)
                            Button("Open Settings") { screenCapture.openSystemSettings() }
                                .buttonStyle(.link)
                                .controlSize(.mini)
                        } else {
                            Button("Check Again") { screenCapture.refresh() }
                                .buttonStyle(.link)
                                .controlSize(.mini)
                        }
                    }
                    SettingToggle(
                        title: "Restart automatically after granting",
                        detail: "Screen Recording often only takes effect in a fresh process. The app saves and restores this window.",
                        isOn: $settings.autoRestartForScreenCapture
                    )
                    if screenCapture.needsRestart, settings.windowSnapshotsEnabled {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle")
                                .foregroundStyle(.orange)
                            Text("Restart required to activate window previews.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Restart Now") {
                                NotificationCenter.default.post(
                                    name: .fasterSpacesRestartForScreenCapture,
                                    object: nil
                                )
                            }
                            .controlSize(.mini)
                        }
                    }
                    Text("Previews are only captured while the switcher is open.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard(title: "Window switcher", systemImage: "command") {
                    SettingToggle(
                        title: "Option-Tab window switcher",
                        detail: "Hold Option, tap Tab to cycle current-Space windows, release Option to raise the selected window. Shift-Option-Tab goes backwards; Escape cancels; Return commits.",
                        isOn: $settings.windowSwitcherEnabled
                    )
                    Divider()
                    SettingToggle(
                        title: "Option-` returns to the previous Space",
                        detail: "Jumps straight back to the Space you were on before the current one.",
                        isOn: $settings.previousSpaceEnabled
                    )
                }
            }
            .padding(14)
        }
    }

    private var keyboardTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(title: "Caps Lock layer", systemImage: "keyboard") {
                    SettingToggle(
                        title: "Enable the held-key layer",
                        detail: "Hold the layer key and press another key. Unmapped keys pass through unchanged by default.",
                        isOn: $settings.hyperKeyEnabled
                    )
                    if settings.hyperKeyEnabled {
                        Divider()
                        SettingPicker(
                            title: "Layer key",
                            detail: nil,
                            selection: $settings.hyperKeySource
                        ) {
                            Text("Caps Lock").tag(0)
                            Text("Right Command").tag(1)
                            Text("Right Option").tag(2)
                            Text("Right Control").tag(3)
                        }
                        SettingPicker(
                            title: "Unmapped keys",
                            detail: "Passthrough is the default; mappings below still apply.",
                            selection: $settings.layerDefaultAction
                        ) {
                            Text("Passthrough (unchanged)").tag(0)
                            Text("Add Hyper modifiers").tag(1)
                            Text("Do nothing").tag(2)
                        }
                        if settings.layerDefaultAction == 1 {
                            HStack(spacing: 12) {
                                Toggle("⌃ Control", isOn: $settings.hyperIncludeControl)
                                Toggle("⌥ Option", isOn: $settings.hyperIncludeOption)
                                Toggle("⌘ Command", isOn: $settings.hyperIncludeCommand)
                                Toggle("⇧ Shift", isOn: $settings.hyperIncludeShift)
                            }
                            .toggleStyle(.checkbox)
                            .font(.caption2)
                        }
                        Divider()
                        SettingPicker(
                            title: "Quick press the layer key",
                            detail: "A short tap, separate from holding the layer.",
                            selection: $settings.capsLockTapAction
                        ) {
                            Text("Do nothing").tag(0)
                            Text("Send Escape").tag(1)
                            Text("Toggle Caps Lock").tag(2)
                        }
                        if settings.capsLockTapAction != 0 {
                            HStack {
                                Text("Quick press duration")
                                    .font(.system(size: 11))
                                Spacer()
                                Text("\(Int((settings.capsQuickPressDuration * 1000).rounded())) ms")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.capsQuickPressDuration, in: 0.15...0.80, step: 0.05)
                        }
                    }
                }

                SettingsCard(title: "Quick presets", systemImage: "square.grid.2x2") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(KeyboardLayerPreset.allCases) { preset in
                            Button {
                                settings.applyLayerPreset(preset)
                            } label: {
                                Label(preset.title, systemImage: preset.systemImage)
                                    .font(.caption2)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        Text("\(settings.layerMappings.count) mapping\(settings.layerMappings.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear All") { settings.clearLayerMappings() }
                            .controlSize(.mini)
                            .disabled(settings.layerMappings.isEmpty)
                    }
                }

                SettingsCard(title: "Layer mappings", systemImage: "list.bullet.rectangle") {
                    if settings.layerMappings.isEmpty {
                        Text("No mappings yet. Add one or use a quick preset; unmapped keys pass through.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach($settings.layerMappings) { $mapping in
                                HStack(spacing: 6) {
                                    Picker("", selection: $mapping.sourceKeyCode) {
                                        ForEach(KeyboardKeyCatalog.all) { key in
                                            Text(key.name).tag(key.code)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 104)

                                    Text("→")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    Picker("", selection: $mapping.action) {
                                        ForEach(KeyboardLayerAction.allCases) { action in
                                            Text(action.title).tag(action)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 100)

                                    if mapping.action == .send {
                                        Picker("", selection: $mapping.targetKeyCode) {
                                            ForEach(KeyboardKeyCatalog.all) { key in
                                                Text(key.name).tag(key.code)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: 104)

                                        LayerModifierToggles(mapping: $mapping)
                                    }

                                    Spacer(minLength: 2)
                                    Button {
                                        settings.removeLayerMapping(id: mapping.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove mapping")
                                }
                            }
                        }
                    }
                    Button {
                        settings.upsertLayerMapping(
                            KeyboardLayerMapping(
                                sourceKeyCode: 0,
                                action: .send,
                                targetKeyCode: 123
                            )
                        )
                    } label: {
                        Label("Add Mapping", systemImage: "plus")
                            .font(.caption2)
                    }
                    .controlSize(.small)
                }

                SettingsCard(title: "Editing conveniences", systemImage: "text.cursor") {
                    SettingToggle(
                        title: "Right Command + V = Paste without formatting",
                        detail: "Sends ⌥⇧⌘V instead of ⌘V.",
                        isOn: $settings.pastePlainEnabled
                    )
                    SettingToggle(
                        title: "Shift + Delete = Forward Delete",
                        detail: "Works even when the layer is off.",
                        isOn: $settings.shiftDeleteForward
                    )
                    SettingToggle(
                        title: "Home and End operate on lines",
                        detail: "Home sends ⌘← and End sends ⌘→.",
                        isOn: $settings.homeEndLines
                    )
                }

                SettingsCard(title: "Shift behaviour", systemImage: "shift") {
                    SettingToggle(
                        title: "Double-tap Shift = Caps Lock",
                        detail: "Tap either Shift twice quickly.",
                        isOn: $settings.doubleShiftCapsLock
                    )
                    SettingToggle(
                        title: "Left Shift + Right Shift = Caps Lock",
                        detail: "Press both Shift keys at the same time.",
                        isOn: $settings.bothShiftCapsLock
                    )
                    SettingToggle(
                        title: "Shift + Caps Lock = Caps Lock",
                        detail: "When Caps Lock is the layer key, adding Shift toggles Caps Lock instead.",
                        isOn: $settings.shiftCapsCapsLock
                    )
                    SettingToggle(
                        title: "Quick Shift = ( or )",
                        detail: "A quick tap of Left Shift types “(”; Right Shift types “)”.",
                        isOn: $settings.quickShiftParens
                    )
                }

                SettingsCard(title: "Seek", systemImage: "text.magnifyingglass") {
                    SettingToggle(
                        title: "Find and click text with the keyboard",
                        detail: "Type a phrase, pick one of the focused app's accessibility text elements, and click it. No screenshots and no OCR.",
                        isOn: $settings.seekEnabled
                    )
                    if settings.seekEnabled {
                        Divider()
                        SettingPicker(
                            title: "Open Seek with",
                            detail: "Hyper+S needs the layer above to be enabled.",
                            selection: $settings.seekTrigger
                        ) {
                            Text("Hyper + S").tag(0)
                            Text("⌃⌥⌘F").tag(1)
                        }
                        HStack {
                            Text("↑↓ choose · Return click · Esc cancel")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Try Seek") { SeekController.shared.begin() }
                                .controlSize(.mini)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var dockTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(title: "Dock click actions", systemImage: "dock.rectangle") {
                    SettingToggle(
                        title: "Enable Dock click actions",
                        detail: "Normal Dock clicks use each app's action. Shift-click opens a new window and Control-click brings the window here; if that action is already configured, the modifiers are stripped and the Dock receives a regular click. Command and Option stay native.",
                        isOn: $settings.dockClicksEnabled
                    )
                    if settings.dockClicksEnabled {
                        Divider()
                        SettingToggle(
                            title: "Control-click stays a left click",
                            detail: "Strip Control from left-mouse events so macOS does not turn Control-click into a right-click. Intercepted Control-clicks still bring the existing window here.",
                            isOn: $settings.dockDisableControlClick
                        )
                        Divider()
                        HStack(spacing: 8) {
                            Circle()
                                .fill(dockStatus.monitoringActive ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(dockStatus.monitoringActive
                                 ? "Monitoring \(dockStatus.cachedDockTileCount) Dock tiles"
                                 : dockStatus.eventTapDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(dockStatus.isPickingApp ? "Cancel Picker" : "Pick from Dock…") {
                                NotificationCenter.default.post(name: .fasterSpacesPickDockApp, object: nil)
                            }
                            .controlSize(.mini)
                        }
                        if let lastAction = dockStatus.lastAction {
                            Text(lastAction)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let failure = dockStatus.lastFailure {
                            Text(failure)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SettingsCard(title: "Apps", systemImage: "app.badge") {
                    if dockRules.rules.isEmpty {
                        Text("No apps are listed yet. Add an app, then choose Bring Here, New Window, or None. New apps start at New Window.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(dockRules.rules) { rule in
                                HStack(spacing: 8) {
                                    Image(nsImage: dockRules.appIcon(for: rule.bundleIdentifier))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(rule.displayName)
                                            .font(.system(size: 11, weight: .medium))
                                        Text(rule.bundleIdentifier)
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Picker("", selection: Binding(
                                        get: { dockRules.rules.first(where: { $0.id == rule.id })?.action ?? rule.action },
                                        set: { dockRules.setAction($0, for: rule.id) }
                                    )) {
                                        ForEach(DockClickAction.allCases) { action in
                                            Text(action.title).tag(action)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 120)
                                    Button {
                                        dockRules.remove(rule.id)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove")
                                }
                            }
                        }
                    }
                    Divider()
                    HStack(spacing: 8) {
                        Button("Add App…") { addDockApp() }
                            .controlSize(.small)
                        Button("Import New Window Plz…") {
                            let count = dockRules.importLegacyRules(force: true)
                            dockStatus.lastAction = count > 0
                                ? "Imported \(count) app behavior(s) from New Window Plz"
                                : "No New Window Plz rules found"
                        }
                        .controlSize(.small)
                        Spacer()
                        Text("Unlisted apps keep normal clicks; Shift and Control still override.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(14)
        }
    }

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard(title: "Conveniences", systemImage: "sparkles") {
                    SettingToggle(
                        title: "Launch at login",
                        detail: "Start Faster Spaces automatically when you sign in.",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    Divider()
                    SettingToggle(
                        title: "Show Space number in the menu bar",
                        detail: "Display the current Space as a small counter next to the icon.",
                        isOn: $settings.showSpaceInMenuBar
                    )
                    SettingToggle(
                        title: "Trackpad feedback",
                        detail: "A subtle haptic tick each time a Space or window is crossed.",
                        isOn: $settings.hapticFeedback
                    )
                    SettingToggle(
                        title: "Prevent empty-desktop bounce",
                        detail: "Stop macOS from pulling you away from an empty Space a moment after you land.",
                        isOn: $settings.yankGuardEnabled
                    )
                }

                SettingsCard(title: "Updates", systemImage: "arrow.triangle.2.circlepath") {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Faster Spaces \(AppInfo.version)")
                                .font(.system(size: 11, weight: .medium))
                            Text(updateDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if case .available = updates.state {
                            Button("Download…") { updates.openReleasePage() }
                                .controlSize(.small)
                        }
                        Button(updates.state == .checking ? "Checking…" : "Check for Updates") {
                            updates.check()
                        }
                        .controlSize(.small)
                        .disabled(updates.state == .checking)
                    }
                    Text("Fetches a small version file from the project website only when you ask. No account, identifier, or telemetry is sent.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsCard(title: "Permissions", systemImage: "lock.shield") {
                    permissionRow(
                        title: "Accessibility",
                        granted: accessibility.isTrusted && accessibility.tapInstalled,
                        detail: "Required for gestures, keyboard layers, and Dock actions."
                    )
                    Divider()
                    permissionRow(
                        title: "Screen Recording",
                        granted: screenCapture.isGranted,
                        detail: "Only used for the optional window thumbnails."
                    )
                    HStack {
                        Button("Grant Accessibility…") {
                            if accessibility.isTrusted && !accessibility.tapInstalled {
                                accessibility.retryTap()
                            } else {
                                accessibility.requestPermissionPrompt()
                            }
                        }
                        .controlSize(.small)
                        .disabled(accessibility.isTrusted && accessibility.tapInstalled)
                        Button("Grant Screen Recording…") { _ = screenCapture.request() }
                            .controlSize(.small)
                            .disabled(screenCapture.isGranted)
                        Spacer()
                        Button("Re-run Setup…") {
                            ui.onboardingStep = 0
                            NotificationCenter.default.post(name: .fasterSpacesShowOnboarding, object: nil)
                        }
                        .controlSize(.small)
                    }
                }

                SettingsCard(title: "Troubleshooting", systemImage: "stethoscope") {
                    HStack(spacing: 8) {
                        Button("Diagnostics…") {
                            NotificationCenter.default.post(name: .fasterSpacesShowDiagnostics, object: nil)
                        }
                        Button("Open log") { Log.revealInFinder() }
                        Spacer()
                        Button("Reset Accessibility…") { ui.showResetConfirmation = true }
                            .disabled(!accessibility.isTrusted)
                    }
                    .controlSize(.small)
                    Text("If a rebuild changed the app's signature, resetting the Accessibility entry lets macOS ask for permission again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Faster Spaces \(AppInfo.version)")
                    Spacer()
                    Text("Spaces · Windows · Keyboard · Dock")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(14)
        }
    }

    private var updateDetail: String {
        switch updates.state {
        case .checking:
            return "Contacting the project website…"
        case .available(let version):
            return "Version \(version) is available."
        case .failed(let message):
            return message
        case .upToDate:
            return AppInfo.version == "dev"
                ? "Development build — update checks compare tagged releases."
                : "You're up to date."
        case .idle:
            return AppInfo.version == "dev"
                ? "Development build. Check the project website for a tagged release."
                : "Check the project website for a newer release."
        }
    }

    private func permissionRow(title: String, granted: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(granted ? "Granted" : detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "OK" : "Needed")
                .font(.caption2.weight(.medium))
                .foregroundStyle(granted ? .green : .orange)
        }
    }

    // MARK: Status

    private var compactStatus: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.45), radius: 3)
            Text(accessibility.statusText)
                .font(.system(size: 11, weight: .semibold))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !accessibility.isTrusted {
                Button("Grant Access…") { accessibility.requestPermissionPrompt() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            } else if !accessibility.tapInstalled {
                Button("Finish Setup") { accessibility.retryTap() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            } else {
                Button("Check Again") { accessibility.refresh() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(statusColor.opacity(0.20), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if accessibility.isTrusted, accessibility.tapInstalled { return .green }
        if accessibility.isTrusted { return .orange }
        return .red
    }

    private var statusDetail: String {
        if accessibility.isTrusted, accessibility.tapInstalled {
            return "Accessibility granted · \(settings.fingerSummary)"
        }
        if accessibility.isTrusted {
            return "Permission granted; installing the event tap."
        }
        return "Accessibility is required for gestures, key layers, and Dock actions."
    }

    private var distanceLabel: String {
        "\(Int((settings.effectiveProgressPerSpace * 100).rounded()))% of gesture travel"
    }

    private func addDockApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add App"
        if panel.runModal() == .OK, let url = panel.url {
            dockRules.addApplication(at: url)
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject private var accessibility = AccessibilityManager.shared
    @ObservedObject private var screenCapture = ScreenCaptureStatusModel.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var dockRules = AppRulesStore.shared
    @ObservedObject private var ui = AppUIState.shared
    let onDone: () -> Void
    let onOpenSettings: () -> Void

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            hero
            stepDots
            Group {
                switch ui.onboardingStep {
                case 0: welcomeStep
                case 1: accessibilityStep
                case 2: screenRecordingStep
                default: featuresStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(width: 640, height: 720)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.19),
                    Color(red: 0.06, green: 0.07, blue: 0.11),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .preferredColorScheme(.dark)
        .onAppear {
            accessibility.refresh()
            screenCapture.refresh()
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.blue.opacity(0.25), radius: 14, y: 6)
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Faster Spaces")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Spaces, windows, and keyboard — without the slide.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Capsule()
                    .fill(index == ui.onboardingStep ? Color.accentColor : Color.primary.opacity(0.12))
                    .frame(width: index == ui.onboardingStep ? 22 : 7, height: 7)
                    .animation(.easeOut(duration: 0.18), value: ui.onboardingStep)
            }
        }
        .padding(.bottom, 14)
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One gesture, three upgrades")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Faster Spaces keeps the trackpad gestures you already use and adds the window switcher and keyboard layer you configured in New Window Plz and Superkey.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            onboardingRow(icon: "rectangle.stack", title: "Instant Spaces", detail: "The Space swipe still works; it just lands in one frame.")
            onboardingRow(icon: "macwindow.on.rectangle", title: "Windows on the other swipe", detail: "The finger count macOS is not using for Spaces moves through current-Space windows.")
            onboardingRow(icon: "command", title: "Option-Tab switcher", detail: "The full New Window Plz switcher, including live thumbnails if you enable Screen Recording.")
            onboardingRow(icon: "keyboard", title: "Editable Caps Lock layer", detail: "Hold Caps Lock for arrows and presets. Unmapped keys pass through by default.")

            if !dockRules.rules.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("\(dockRules.rules.count) Dock app behavior\(dockRules.rules.count == 1 ? "" : "s") imported from New Window Plz. Review them in Settings → Dock.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.green.opacity(0.08))
                )
            }
        }
        .padding(.horizontal, 26)
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow Accessibility")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Accessibility lets Faster Spaces replace the Space swipe, drive the window switcher, and listen for the Caps Lock layer. The app never records your screen or sends data anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            onboardingCard {
                HStack(spacing: 10) {
                    statusIcon(granted: accessibility.isTrusted && accessibility.tapInstalled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accessibility.isTrusted && accessibility.tapInstalled
                             ? "Accessibility granted"
                             : "Accessibility permission needed")
                            .font(.system(size: 13, weight: .semibold))
                        Text(accessibility.statusDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !(accessibility.isTrusted && accessibility.tapInstalled) {
                    HStack(spacing: 8) {
                        if accessibility.isTrusted {
                            Button("Finish Setup") { accessibility.retryTap() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        } else {
                            Button("Grant Access…") { accessibility.requestPermissionPrompt() }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        Button("Open System Settings") { accessibility.openSystemSettings() }
                            .controlSize(.small)
                        Button("Check Again") { accessibility.refresh() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }
            }

            onboardingNote(
                icon: "lock.shield",
                title: "Why Accessibility?",
                detail: "macOS only lets trusted apps replace synthetic input. Accessibility covers the Space gesture, the window switcher, the key layer, and Dock actions. It does not grant screen access."
            )
        }
        .padding(.horizontal, 26)
    }

    private var screenRecordingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional: window previews")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("New Window Plz could show live thumbnails in the switcher. They are captured only after the switcher opens and only for the visible current-Space windows. This requires Screen Recording; you can skip it and use app icons.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            onboardingCard {
                Toggle(isOn: Binding(
                    get: { settings.windowSnapshotsEnabled },
                    set: { enabled in
                        settings.windowSnapshotsEnabled = enabled
                        if enabled, !screenCapture.isGranted {
                            _ = screenCapture.request()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show live window thumbnails")
                            .font(.system(size: 13, weight: .semibold))
                        Text("App icons remain the fallback until permission is active.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider()

                HStack(spacing: 8) {
                    statusIcon(granted: screenCapture.isGranted)
                    Text(screenCapture.isGranted
                         ? "Screen Recording granted"
                         : "Screen Recording not granted")
                        .font(.caption)
                    Spacer()
                    if !screenCapture.isGranted {
                        Button("Grant…") { _ = screenCapture.request() }
                            .controlSize(.small)
                        Button("Open Settings") { screenCapture.openSystemSettings() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    } else {
                        Button("Check Again") { screenCapture.refresh() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                    }
                }

                Divider()

                Toggle(isOn: $settings.autoRestartForScreenCapture) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart automatically after granting")
                            .font(.system(size: 12, weight: .medium))
                        Text("The app relaunches and returns to this setup step.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if screenCapture.needsRestart, settings.windowSnapshotsEnabled {
                    HStack(spacing: 8) {
                        statusIcon(granted: true)
                        Text("Restart to activate window previews.")
                            .font(.caption2)
                        Spacer()
                        Button("Restart Now") {
                            NotificationCenter.default.post(
                                name: .fasterSpacesRestartForScreenCapture,
                                object: nil
                            )
                        }
                        .controlSize(.small)
                    }
                }
            }

            onboardingNote(
                icon: "eye.slash",
                title: "Only while the switcher is open",
                detail: "Thumbnails are requested for current-Space windows after the switcher appears. Nothing is recorded continuously, saved to disk, or sent anywhere. App icons are always the fallback."
            )
        }
        .padding(.horizontal, 26)
    }

    private var featuresStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your shortcuts")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("All of these can be changed later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            onboardingCard {
                FingerSummaryRow()
                Divider()
                Toggle("Switch windows with the non-primary swipe", isOn: $settings.windowSwipeEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Picker("Swipe display", selection: $settings.windowSwipeUIStyle) {
                    Text("Compact HUD").tag(0)
                    Text("Full-screen switcher").tag(1)
                }
                .pickerStyle(.menu)
                Toggle("Reverse window direction", isOn: $settings.windowSwipeInvertDirection)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Raise window on release", isOn: $settings.windowSwipeRaiseOnRelease)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Option-Tab window switcher", isOn: $settings.windowSwitcherEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Caps Lock layer", isOn: $settings.hyperKeyEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Dock click actions", isOn: $settings.dockClicksEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("Seek text finder", isOn: $settings.seekEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if settings.windowSnapshotsEnabled {
                    Text("Window thumbnails will appear whenever Screen Recording is granted.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Launch at login is enabled when you finish. You can turn it off in General.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 26)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if ui.onboardingStep > 0 {
                Button("Back") {
                    ui.onboardingStep = max(0, ui.onboardingStep - 1)
                }
                .controlSize(.small)
            }
            Button("Settings…", action: onOpenSettings)
                .controlSize(.small)
            Spacer()
            if ui.onboardingStep == 2, !settings.windowSnapshotsEnabled {
                Button("Skip") { ui.onboardingStep = 3 }
                    .controlSize(.small)
            }
            Button(primaryTitle) {
                if ui.onboardingStep < stepCount - 1 {
                    ui.onboardingStep += 1
                } else {
                    finish()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
    }

    private var primaryTitle: String {
        switch ui.onboardingStep {
        case 0: return "Get Started"
        case 3: return "Start Using Faster Spaces"
        default: return "Continue"
        }
    }

    private func finish() {
        settings.completedOnboarding = true
        settings.setLaunchAtLogin(true)
        onDone()
    }

    private func onboardingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func onboardingNote(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func onboardingRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }

    private func statusIcon(granted: Bool) -> some View {
        Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 17))
            .foregroundStyle(granted ? .green : .orange)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @ObservedObject private var accessibility = AccessibilityManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var screenCapture = ScreenCaptureStatusModel.shared
    @ObservedObject private var model = DiagnosticsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.title2.bold())
                    Text("Live gesture, window, keyboard, and Dock log. Debug logging is \(settings.debugLogging ? "on" : "off").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Debug logging", isOn: $settings.debugLogging)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                infoPill("Tap", accessibility.tapInstalled ? "Active" : "Off", color: accessibility.tapInstalled ? .green : .red)
                infoPill("Screen", screenCapture.isGranted ? "Granted" : "Missing", color: screenCapture.isGranted ? .green : .orange)
                infoPill("Spaces", SpaceSwitcher.shared.snapshot().map { "\($0.currentNumber)/\($0.spaceCount)" } ?? "—", color: .secondary)
                infoPill("Fingers", settings.fingerSummary, color: .secondary)
                infoPill("Swipe UI", settings.windowSwipeUIStyle == 1 ? "Full" : "Compact", color: .secondary)
                infoPill("Windows", "\(WindowCatalogService.shared.windows.count)", color: .secondary)
                infoPill("Layer", "\(settings.layerMappings.count)", color: .secondary)
            }

            ScrollView {
                Text(model.text.isEmpty ? "No log entries yet." : model.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            HStack(spacing: 6) {
                Button("Switch Left") { SpaceSwitcher.shared.switchOne(direction: -1, reason: "diagnostics") }
                Button("Switch Right") { SpaceSwitcher.shared.switchOne(direction: 1, reason: "diagnostics") }
                Button("Previous Space") { SpaceHistory.shared.switchToPreviousSpace() }
                Divider().frame(height: 14)
                Button("Next Window") { WindowSwitchController.shared.activateNextWindow(reverse: false) }
                Button("Previous Window") { WindowSwitchController.shared.activateNextWindow(reverse: true) }
                Button("Preview Switcher") {
                    let windows = WindowCatalogService.shared.windowsForImmediateUse()
                    let destination = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/FasterSpaces-WindowSwitcher.png")
                    WindowSwitcherOverlay.shared.writePreview(to: destination, windows: windows, selectedIndex: 0)
                }
                Spacer()
                Button("Refresh") { model.refresh() }
                Button("Open Log") { Log.revealInFinder() }
                Button("Clear") { Log.clear(); model.refresh() }
            }
            .font(.caption)
            .controlSize(.mini)
        }
        .padding(16)
        .frame(width: 860, height: 560)
        .onAppear {
            model.start()
            screenCapture.refresh()
        }
        .onDisappear { model.stop() }
    }

    private func infoPill(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
