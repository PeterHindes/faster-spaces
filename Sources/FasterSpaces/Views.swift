import AppKit
import SwiftUI

// MARK: - View state

/// Small observable state shared by the settings and diagnostics windows.
/// Using explicit ObservableObjects avoids SwiftUI's State macro, whose
/// plugin cannot run inside the restricted build sandbox used for this app.
final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var showResetConfirmation = false
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
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Faster Spaces")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Your Spaces gesture, without the slide.")
                    .font(.subheadline)
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
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 2)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var accessibility = AccessibilityManager.shared
    @ObservedObject private var ui = AppUIState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsHeader()
                    .padding(.bottom, 2)

                statusCard

                SettingsCard(title: "Gesture", systemImage: "hand.draw") {
                    SettingToggle(
                        title: "Enable Faster Spaces",
                        detail: "Replace the animated macOS Space swipe with an instant switch.",
                        isOn: $settings.enabled
                    )
                    Divider()
                    SettingToggle(
                        title: "Direction HUD (0.25 s)",
                        detail: "Shows two small desktop tiles sliding in the direction of the switch. No screen recording or screenshots.",
                        isOn: $settings.subtleTransitionEnabled
                    )
                    Divider()
                    HStack(spacing: 12) {
                        Image(systemName: "fingerprint")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("3 or 4 fingers, following macOS")
                            Text("Faster Spaces intercepts the same Spaces gesture you already use. Change it in System Settings → Trackpad → More Gestures.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text("Automatic")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Divider()
                    SettingToggle(
                        title: "Reverse swipe direction",
                        detail: "Only needed if your setup reports the gesture backwards.",
                        isOn: $settings.invertDirection
                    )
                }

                SettingsCard(title: "Multiple Spaces", systemImage: "rectangle.stack") {
                    SettingToggle(
                        title: "Cross multiple Spaces in one swipe",
                        detail: "Keep swiping after the first Space to jump further. Useful when you have a long row of desktops.",
                        isOn: $settings.multiSpaceEnabled
                    )
                    if settings.multiSpaceEnabled {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Distance per Space")
                                Spacer()
                                Text(distanceLabel)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.progressPerSpace, in: 0.08...0.30, step: 0.01)
                            HStack {
                                Text("More Spaces — shorter travel")
                                Spacer()
                                Text("Fewer Spaces — longer travel")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        Divider()
                        Stepper(
                            value: $settings.maximumSpacesPerSwipe,
                            in: 1...8
                        ) {
                            Text("Maximum \(settings.maxSpaces) \(settings.maxSpaces == 1 ? "Space" : "Spaces") per swipe")
                        }
                        Text("The first Space moves immediately. Each additional Space needs another \(distancePercent)% of the gesture's travel. Swipe back during the same gesture to retrace the Spaces you crossed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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
                    Divider()
                    SettingToggle(
                        title: "Trackpad feedback",
                        detail: "A subtle haptic tick each time a Space is crossed.",
                        isOn: $settings.hapticFeedback
                    )
                    Divider()
                    SettingToggle(
                        title: "Prevent empty-desktop bounce",
                        detail: "Stop macOS from pulling you away from an empty Space a moment after you land.",
                        isOn: $settings.yankGuardEnabled
                    )
                }

                SettingsCard(title: "Troubleshooting", systemImage: "stethoscope") {
                    HStack(spacing: 10) {
                        Button("Diagnostics…") { NotificationCenter.default.post(name: .fasterSpacesShowDiagnostics, object: nil) }
                        Button("Open log") { Log.revealInFinder() }
                        Spacer()
                        Button("Reset Accessibility…") { ui.showResetConfirmation = true }
                            .disabled(!accessibility.isTrusted)
                    }
                    Text("If a rebuild changed the app's signature, resetting the Accessibility entry lets macOS ask for permission again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Faster Spaces \(AppDelegate.version)")
                    Spacer()
                    Text("Instant Spaces via the Dock's own gesture pipeline")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 640, height: 760)
        .onAppear { accessibility.refresh() }
        .alert("Reset Accessibility permission?", isPresented: $ui.showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { accessibility.resetPermission() }
        } message: {
            Text("macOS will forget the current Accessibility grant. Quit and reopen Faster Spaces, then grant permission again.")
        }
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.45), radius: 4)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(accessibility.statusText)
                    .font(.headline)
                Text(accessibility.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = accessibility.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                if !accessibility.isTrusted {
                    Button("Grant Access…") {
                        accessibility.requestPermissionPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                } else if !accessibility.tapInstalled {
                    Button("Finish Setup") {
                        accessibility.retryTap()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Open Settings") {
                        accessibility.openSystemSettings()
                    }
                }
                Button("Check Again") { accessibility.refresh() }
                    .buttonStyle(.link)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(statusColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(statusColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if accessibility.isTrusted, accessibility.tapInstalled { return .green }
        if accessibility.isTrusted { return .orange }
        return .red
    }

    private var distancePercent: Int {
        Int((settings.effectiveProgressPerSpace * 100).rounded())
    }

    private var distanceLabel: String {
        "\(distancePercent)% of gesture travel"
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @ObservedObject private var accessibility = AccessibilityManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    let onDone: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.35, green: 0.55, blue: 1.0), Color(red: 0.55, green: 0.35, blue: 0.95)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 92, height: 92)
                    Image(systemName: "rectangle.split.2x1.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text("Faster Spaces")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("The Space swipe you already use — now without the slide.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 34)
            .padding(.bottom, 24)

            VStack(spacing: 12) {
                step(
                    number: 1,
                    title: "Grant Accessibility access",
                    detail: "macOS gates gesture replacement behind Accessibility. This app never records keystrokes or screen contents.",
                    accessory: AnyView(permissionAccessory)
                )
                step(
                    number: 2,
                    title: "Keep your current Spaces gesture",
                    detail: "Three or four fingers both work. Faster Spaces follows whatever is configured in System Settings.",
                    accessory: AnyView(
                        Button("Open Trackpad Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                    )
                )
                step(
                    number: 3,
                    title: "Swipe",
                    detail: "Move between Spaces instantly. Turn on Multiple Spaces in Settings to cross more than one per swipe.",
                    accessory: nil
                )
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 16)

            VStack(spacing: 8) {
                Button(action: {
                    settings.completedOnboarding = true
                    settings.setLaunchAtLogin(true)
                    onDone()
                }) {
                    Text("Start Using Faster Spaces")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Starts at login. You can turn this off in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Settings…", action: onOpenSettings)
                    Spacer()
                    if !accessibility.isTrusted {
                        Text("Accessibility is still required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 560, height: 700)
        .onAppear { accessibility.refresh() }
    }

    @ViewBuilder
    private var permissionAccessory: some View {
        if accessibility.isTrusted, accessibility.tapInstalled {
            Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        } else if accessibility.isTrusted {
            Button("Finish Setup") { accessibility.retryTap() }
                .buttonStyle(.bordered)
        } else {
            Button("Grant Access…") { accessibility.requestPermissionPrompt() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func step(
        number: Int,
        title: String,
        detail: String,
        accessory: AnyView?
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let accessory {
                    accessory.padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @ObservedObject private var accessibility = AccessibilityManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var model = DiagnosticsModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics")
                        .font(.title2.bold())
                    Text("Live gesture and switch log. Debug logging is \(settings.debugLogging ? "on" : "off").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Debug logging", isOn: $settings.debugLogging)
                    .toggleStyle(.switch)
            }

            HStack(spacing: 18) {
                infoPill("Tap", accessibility.tapInstalled ? "Active" : "Off", color: accessibility.tapInstalled ? .green : .red)
                infoPill("Permission", accessibility.isTrusted ? "Granted" : "Missing", color: accessibility.isTrusted ? .green : .red)
                infoPill("macOS", "\(SpaceSwitcher.macOSMajorVersion())", color: .secondary)
                infoPill("Spaces", SpaceSwitcher.shared.snapshot().map { "\($0.currentNumber)/\($0.spaceCount)" } ?? "—", color: .secondary)
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

            HStack {
                Button("Switch Left") {
                    SpaceSwitcher.shared.switchOne(direction: -1, reason: "diagnostics")
                }
                Button("Switch Right") {
                    SpaceSwitcher.shared.switchOne(direction: 1, reason: "diagnostics")
                }
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Open Log") { Log.revealInFinder() }
                Button("Clear") {
                    Log.clear()
                    model.refresh()
                }
            }
            .font(.caption)
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func infoPill(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}
