import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let version = "1.0.3"

    private let settings = SettingsStore.shared
    private let accessibility = AccessibilityManager.shared
    private let switcher = SpaceSwitcher.shared

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var lastYankGuardActivation = Date.distantPast

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A LaunchAgent starts the executable directly; make sure a manual
        // launch and a login launch can never run two copies.
        if let bundleID = Bundle.main.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let oldest = running.min(by: { $0.processIdentifier < $1.processIdentifier }),
               oldest.processIdentifier != getpid() {
                NSApp.terminate(nil)
                return
            }
        }

        NSApp.setActivationPolicy(.accessory)
        Log.info("Faster Spaces \(Self.version) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        configureStatusItem()
        configureMenu()
        observeApp()
        MultitouchTracker.shared.start()
        LaunchAtLogin.refreshIfEnabled()
        settings.refreshLaunchAtLogin()
        if settings.completedOnboarding,
           !UserDefaults.standard.bool(forKey: "loginItemInitialized") {
            UserDefaults.standard.set(true, forKey: "loginItemInitialized")
            settings.setLaunchAtLogin(true)
        }
        accessibility.start()

        if !settings.completedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showOnboarding()
            }
        } else if !accessibility.isTrusted {
            // The app is already set up but permission was removed. Surface it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwipeInterceptor.shared.uninstall()
    }

    // MARK: Status item

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = menuBarImage()
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.toolTip = "Faster Spaces"
    }

    private func menuBarImage() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "rectangle.split.2x1",
            accessibilityDescription: "Faster Spaces"
        )
        image?.isTemplate = true
        return image
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let snapshot = switcher.snapshot()
        button.image = menuBarImage()
        button.image?.isTemplate = true
        if settings.showSpaceInMenuBar, let snapshot {
            button.title = " \(snapshot.currentNumber)/\(snapshot.spaceCount)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            button.title = ""
        }
        if let snapshot {
            button.toolTip = "Faster Spaces — Space \(snapshot.currentNumber) of \(snapshot.spaceCount)"
        } else {
            button.toolTip = "Faster Spaces"
        }
    }

    private func configureMenu() {
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = switcher.snapshot()

        let title = NSMenuItem(title: "Faster Spaces", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let spaceLine = snapshot.map { "Space \($0.currentNumber) of \($0.spaceCount)" } ?? "Spaces unavailable"
        let spaceItem = NSMenuItem(title: spaceLine, action: nil, keyEquivalent: "")
        spaceItem.isEnabled = false
        menu.addItem(spaceItem)

        if !accessibility.isTrusted {
            let permission = NSMenuItem(
                title: "Grant Accessibility…",
                action: #selector(grantAccessibility),
                keyEquivalent: ""
            )
            permission.target = self
            menu.addItem(permission)
        } else if !accessibility.tapInstalled {
            let retry = NSMenuItem(
                title: "Finish Setup…",
                action: #selector(openSettingsAction),
                keyEquivalent: ""
            )
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())

        let left = NSMenuItem(title: "Switch Left", action: #selector(switchLeft), keyEquivalent: "")
        left.target = self
        left.isEnabled = (snapshot?.currentNumber ?? 1) > 1
        menu.addItem(left)

        let right = NSMenuItem(title: "Switch Right", action: #selector(switchRight), keyEquivalent: "")
        right.target = self
        right.isEnabled = (snapshot?.currentNumber ?? 1) < (snapshot?.spaceCount ?? 1)
        menu.addItem(right)

        menu.addItem(.separator())

        let multi = NSMenuItem(
            title: "Multi-Space Swipe",
            action: #selector(toggleMultiSpace),
            keyEquivalent: ""
        )
        multi.target = self
        multi.state = settings.multiSpaceEnabled ? .on : .off
        menu.addItem(multi)

        let enabled = NSMenuItem(
            title: settings.enabled ? "Pause" : "Resume",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabled.target = self
        menu.addItem(enabled)

        menu.addItem(.separator())

        let preferences = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        preferences.target = self
        menu.addItem(preferences)

        let diagnostics = NSMenuItem(
            title: "Diagnostics…",
            action: #selector(openDiagnosticsAction),
            keyEquivalent: "d"
        )
        diagnostics.keyEquivalentModifierMask = [.command, .option]
        diagnostics.target = self
        menu.addItem(diagnostics)

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = settings.launchAtLogin ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Faster Spaces", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Faster Spaces", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        updateStatusItem()
    }

    // MARK: Observation

    private func observeApp() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(spaceDidSwitch),
            name: .fasterSpacesDidSwitch, object: nil
        )
        center.addObserver(
            self, selector: #selector(statusDidChange),
            name: .fasterSpacesStatusDidChange, object: nil
        )
        center.addObserver(
            self, selector: #selector(showDiagnosticsFromNotification),
            name: .fasterSpacesShowDiagnostics, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
    }

    @objc private func spaceDidSwitch() {
        updateStatusItem()
    }

    @objc private func statusDidChange() {
        updateStatusItem()
        if accessibility.isTrusted, accessibility.tapInstalled, settings.completedOnboarding {
            onboardingWindow?.close()
        }
    }

    @objc private func activeSpaceDidChange() {
        updateStatusItem()
        installYankGuardIfNeeded()
    }

    // MARK: Empty-desktop protection

    private func installYankGuardIfNeeded() {
        guard settings.yankGuardEnabled, accessibility.isTrusted else { return }
        guard !anyOwnWindowVisible else { return }
        let now = Date()
        guard now.timeIntervalSince(lastYankGuardActivation) > 0.75 else { return }

        // Let the landing settle, then take activation only if there is
        // nothing on the new Space. This prevents the Dock from following an
        // off-Space window back out, without disabling Dock-icon-follow.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.settings.yankGuardEnabled, !self.anyOwnWindowVisible else { return }
            guard !self.switcher.activeSpaceHasWindows() else { return }
            self.lastYankGuardActivation = Date()
            NSApp.activate(ignoringOtherApps: true)
            Log.debug("Took activation on an empty Space to prevent the yank")
        }
    }

    private var anyOwnWindowVisible: Bool {
        [settingsWindow, onboardingWindow, diagnosticsWindow]
            .compactMap { $0 }
            .contains { $0.isVisible }
    }

    // MARK: Actions

    @objc private func switchLeft() {
        switcher.switchOne(direction: -1, reason: "menu")
        updateStatusItem()
    }

    @objc private func switchRight() {
        switcher.switchOne(direction: 1, reason: "menu")
        updateStatusItem()
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
    }

    @objc private func toggleMultiSpace() {
        settings.multiSpaceEnabled.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
    }

    @objc private func grantAccessibility() {
        accessibility.requestPermissionPrompt()
        showSettings()
    }

    @objc private func openSettingsAction() {
        showSettings()
    }

    @objc private func openDiagnosticsAction() {
        showDiagnostics()
    }

    @objc private func showDiagnosticsFromNotification() {
        showDiagnostics()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Faster Spaces",
            .applicationVersion: Self.version,
            .credits: NSAttributedString(
                string: "Instant Spaces switching without the slide.\n\n"
                    + "Uses the Dock's own gesture pipeline. Inspired by WhichSpace, "
                    + "InstantSpaceSwitcher and noswoosh.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
    }

    // MARK: Windows

    private func showSettings() {
        accessibility.refresh()
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Faster Spaces Settings",
                size: NSSize(width: 640, height: 760),
                view: SettingsView()
            )
        }
        present(settingsWindow)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(
                title: "Welcome to Faster Spaces",
                size: NSSize(width: 560, height: 700),
                view: OnboardingView(
                    onDone: { [weak self] in
                        self?.settings.completedOnboarding = true
                        self?.onboardingWindow?.close()
                        self?.onboardingWindow = nil
                    },
                    onOpenSettings: { [weak self] in
                        self?.showSettings()
                    }
                )
            )
        }
        present(onboardingWindow)
    }

    private func showDiagnostics() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = makeWindow(
                title: "Faster Spaces Diagnostics",
                size: NSSize(width: 760, height: 560),
                view: DiagnosticsView()
            )
        }
        present(diagnosticsWindow)
    }

    private func makeWindow<V: View>(
        title: String,
        size: NSSize,
        resizable: Bool = false,
        view: V
    ) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Explicitly size after installing the hosting view. Without this the
        // ScrollView can report its full content height as the window's ideal
        // size, producing an absurdly tall window.
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Render the settings window to a PNG for documentation/screenshots.
    /// This is a development aid; it runs only when explicitly asked via the
    /// fasterspaces://snapshot URL.
    private func captureSettingsSnapshot() {
        guard let window = settingsWindow, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error("Snapshot: could not create bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.error("Snapshot: could not encode PNG")
            return
        }
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/FasterSpaces-Settings.png")
        do {
            try data.write(to: destination)
            Log.info("Snapshot written to \(destination.path)")
        } catch {
            Log.error("Snapshot failed: \(error.localizedDescription)")
        }
    }

    // MARK: URL commands

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "fasterspaces" else { return }
        let host = url.host?.lowercased() ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        func value(_ name: String) -> String? {
            query.first(where: { $0.name == name })?.value
        }

        switch host {
        case "switch":
            let directionName = value("direction")?.lowercased()
            let count = max(1, min(Int(value("count") ?? "1") ?? 1, 8))
            let direction = directionName == "left" ? -1 : 1
            switcher.switchBy(steps: count, direction: direction, reason: "url")
            updateStatusItem()
        case "settings":
            showSettings()
        case "diagnostics":
            showDiagnostics()
        case "onboarding":
            showOnboarding()
        case "toggle":
            settings.enabled.toggle()
        case "status":
            let status = "Status: \(switcher.currentSummary()); trusted=\(accessibility.isTrusted); tap=\(accessibility.tapInstalled)"
            Log.info(status)
        case "snapshot":
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.captureSettingsSnapshot()
            }
        default:
            showSettings()
        }
    }
}
