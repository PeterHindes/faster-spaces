import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let version = AppInfo.version

    private let settings = SettingsStore.shared
    private let accessibility = AccessibilityManager.shared
    private let switcher = SpaceSwitcher.shared
    private let dockStatus = DockStatusModel.shared
    private let dockRules = AppRulesStore.shared

    private lazy var dockInspector = DockInspector()
    private lazy var dockGeometry = DockGeometryCache()
    private lazy var dockEventTap = DockEventTap(
        inspector: dockInspector,
        geometryCache: dockGeometry,
        rules: dockRules
    )
    private lazy var dockController = DockClickController(
        inspector: dockInspector,
        geometryCache: dockGeometry,
        eventTap: dockEventTap,
        newWindowController: NewWindowController(model: dockStatus),
        model: dockStatus,
        settings: settings,
        rules: dockRules
    )
    private let controlClickFilter = ControlClickFilter()

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var lastYankGuardActivation = Date.distantPast
    private var isRelaunchingForScreenCapture = false

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
        configureMainMenu()
        observeApp()
        MultitouchTracker.shared.start()
        WindowCatalogService.shared.start()
        WindowSwitcherOverlay.shared.prepare()
        SpaceHistory.shared.start()
        LaunchAtLogin.refreshIfEnabled()
        settings.refreshLaunchAtLogin()
        if settings.completedOnboarding,
           !UserDefaults.standard.bool(forKey: "loginItemInitialized") {
            UserDefaults.standard.set(true, forKey: "loginItemInitialized")
            settings.setLaunchAtLogin(true)
        }
        accessibility.start()
        syncDockFeatures()

        let relaunch = consumeRelaunchContext()
        if relaunch.resumeOnboarding {
            Log.info("Resuming onboarding at step \(relaunch.onboardingStep) after relaunch")
            AppUIState.shared.onboardingStep = relaunch.onboardingStep
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showOnboarding(resetStep: false)
            }
        } else if relaunch.reopenSettings {
            Log.info("Reopening Settings after relaunch")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showSettings()
            }
        } else if !settings.completedOnboarding {
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
        WindowSwitchController.shared.endSwipe()
        WindowSwitchController.shared.cancelOptionTab()
        SpaceHistory.shared.stop()
        dockController.stop()
        controlClickFilter.stop()
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
            button.toolTip = "Faster Spaces — Space \(snapshot.currentNumber) of \(snapshot.spaceCount) · \(settings.fingerSummary)"
        } else {
            button.toolTip = "Faster Spaces · \(settings.fingerSummary)"
        }
    }

    private func configureMenu() {
        statusMenu.delegate = self
        statusItem.menu = statusMenu
    }

    /// A minimal main menu so a regular (Command-Tab visible) Faster Spaces
    /// behaves like a normal app while Settings is open.
    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Faster Spaces")
        appItem.submenu = appMenu

        let about = NSMenuItem(
            title: "About Faster Spaces",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        appMenu.addItem(about)

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        updates.target = self
        appMenu.addItem(updates)

        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "Hide Faster Spaces",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        appMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = NSApp
        appMenu.addItem(showAll)

        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Faster Spaces",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        appMenu.addItem(quit)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
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

        let previous = NSMenuItem(
            title: "Back to Previous Space",
            action: #selector(switchToPreviousSpace),
            keyEquivalent: ""
        )
        previous.target = self
        previous.isEnabled = settings.previousSpaceEnabled
        menu.addItem(previous)

        menu.addItem(.separator())

        let multi = NSMenuItem(
            title: "Multi-Space Swipe",
            action: #selector(toggleMultiSpace),
            keyEquivalent: ""
        )
        multi.target = self
        multi.state = settings.multiSpaceEnabled ? .on : .off
        menu.addItem(multi)

        let windowSwipe = NSMenuItem(
            title: "Window Swipe (\(settings.windowFingers) fingers)",
            action: #selector(toggleWindowSwipe),
            keyEquivalent: ""
        )
        windowSwipe.target = self
        windowSwipe.state = settings.windowSwipeEnabled ? .on : .off
        menu.addItem(windowSwipe)

        let windowSwitcher = NSMenuItem(
            title: "Window Switcher (⌥Tab)",
            action: #selector(toggleWindowSwitcher),
            keyEquivalent: ""
        )
        windowSwitcher.target = self
        windowSwitcher.state = settings.windowSwitcherEnabled ? .on : .off
        menu.addItem(windowSwitcher)

        let hyper = NSMenuItem(
            title: "Superkey Hyper Key",
            action: #selector(toggleHyperKey),
            keyEquivalent: ""
        )
        hyper.target = self
        hyper.state = settings.hyperKeyEnabled ? .on : .off
        menu.addItem(hyper)

        let dockClicks = NSMenuItem(
            title: "Dock Click Actions",
            action: #selector(toggleDockClicks),
            keyEquivalent: ""
        )
        dockClicks.target = self
        dockClicks.state = settings.dockClicksEnabled ? .on : .off
        menu.addItem(dockClicks)

        if settings.dockClicksEnabled {
            let pickDock = NSMenuItem(
                title: dockStatus.isPickingApp ? "Cancel Dock App Picker" : "Add Dock App…",
                action: #selector(toggleDockPicker),
                keyEquivalent: ""
            )
            pickDock.target = self
            menu.addItem(pickDock)
        }

        if settings.seekEnabled {
            let seek = NSMenuItem(
                title: "Seek…",
                action: #selector(openSeek),
                keyEquivalent: ""
            )
            seek.target = self
            menu.addItem(seek)
        }

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

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        checkForUpdates.target = self
        menu.addItem(checkForUpdates)

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
        center.addObserver(
            self, selector: #selector(pickDockAppFromNotification),
            name: .fasterSpacesPickDockApp, object: nil
        )
        center.addObserver(
            self, selector: #selector(windowCatalogDidChange),
            name: .fasterSpacesWindowCatalogDidChange, object: nil
        )
        center.addObserver(
            self, selector: #selector(showOnboardingFromNotification),
            name: .fasterSpacesShowOnboarding, object: nil
        )
        center.addObserver(
            self, selector: #selector(screenCaptureDidBecomeGranted),
            name: .fasterSpacesScreenCaptureDidBecomeGranted, object: nil
        )
        center.addObserver(
            self, selector: #selector(restartForScreenCapture),
            name: .fasterSpacesRestartForScreenCapture, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusItem()
                    self?.syncDockFeatures()
                    if let self,
                       self.settings.windowSnapshotsEnabled,
                       ScreenCaptureStatusModel.shared.needsRestart,
                       self.settings.autoRestartForScreenCapture {
                        self.scheduleScreenCaptureRestart()
                    }
                }
            }
            .store(in: &cancellables)
    }

    @objc private func spaceDidSwitch() {
        updateStatusItem()
    }

    @objc private func statusDidChange() {
        updateStatusItem()
        syncDockFeatures()
        if accessibility.isTrusted, accessibility.tapInstalled, settings.completedOnboarding {
            onboardingWindow?.close()
        }
    }

    /// Keep the Dock click taps in sync with the permission and the two
    /// independent toggles. Starting twice is a no-op.
    private func syncDockFeatures() {
        guard settings.dockClicksEnabled, accessibility.isTrusted else {
            dockController.stop()
            controlClickFilter.stop()
            return
        }
        _ = dockController.start()
        if settings.dockDisableControlClick {
            _ = controlClickFilter.start()
        } else {
            controlClickFilter.stop()
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

    @objc private func toggleWindowSwipe() {
        settings.windowSwipeEnabled.toggle()
    }

    @objc private func toggleWindowSwitcher() {
        settings.windowSwitcherEnabled.toggle()
    }

    @objc private func toggleHyperKey() {
        settings.hyperKeyEnabled.toggle()
    }

    @objc private func toggleDockClicks() {
        settings.dockClicksEnabled.toggle()
        DispatchQueue.main.async { [weak self] in
            self?.syncDockFeatures()
        }
    }

    @objc private func toggleDockPicker() {
        _ = dockController.start()
        dockController.toggleAppPicker()
    }

    @objc private func openSeek() {
        SeekController.shared.begin()
    }

    @objc private func switchToPreviousSpace() {
        SpaceHistory.shared.switchToPreviousSpace()
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

    @objc private func showOnboardingFromNotification() {
        showOnboarding()
    }

    @objc private func screenCaptureDidBecomeGranted() {
        guard settings.windowSnapshotsEnabled,
              settings.autoRestartForScreenCapture else { return }
        scheduleScreenCaptureRestart()
    }

    @objc private func restartForScreenCapture() {
        scheduleScreenCaptureRestart()
    }

    /// Screen Recording grants are usually not honored by an already-running
    /// process. Save enough context to restore the window the user was in and
    /// relaunch a fresh process.
    private func scheduleScreenCaptureRestart() {
        guard !isRelaunchingForScreenCapture else { return }
        isRelaunchingForScreenCapture = true
        saveRelaunchContext()
        Log.info("Screen Recording granted; scheduling relaunch to activate previews")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppRelauncher.relaunch(reason: "Screen Recording permission")
        }
    }

    private func saveRelaunchContext() {
        let defaults = UserDefaults.standard
        defaults.set(onboardingWindow?.isVisible == true, forKey: "relaunch.resumeOnboarding")
        defaults.set(AppUIState.shared.onboardingStep, forKey: "relaunch.onboardingStep")
        defaults.set(settingsWindow?.isVisible == true, forKey: "relaunch.reopenSettings")
        defaults.set(true, forKey: "relaunch.pending")
    }

    private func consumeRelaunchContext() -> (resumeOnboarding: Bool, onboardingStep: Int, reopenSettings: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "relaunch.pending") else {
            return (false, 0, false)
        }
        let resume = defaults.bool(forKey: "relaunch.resumeOnboarding")
        let step = defaults.integer(forKey: "relaunch.onboardingStep")
        let reopen = defaults.bool(forKey: "relaunch.reopenSettings")
        defaults.removeObject(forKey: "relaunch.pending")
        defaults.removeObject(forKey: "relaunch.resumeOnboarding")
        defaults.removeObject(forKey: "relaunch.onboardingStep")
        defaults.removeObject(forKey: "relaunch.reopenSettings")
        return (resume, step, reopen)
    }

    @objc private func pickDockAppFromNotification() {
        _ = dockController.start()
        dockController.toggleAppPicker()
    }

    @objc private func windowCatalogDidChange() {
        WindowSwitcherOverlay.shared.prepareWindowSwitcherCache(
            windows: WindowCatalogService.shared.windows
        )
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
                string: "Instant Spaces and window switching without the slide.\n\n"
                    + "Spaces use the Dock's own gesture pipeline. The window switcher is "
                    + "adapted from New Window Plz. The Hyper key and keyboard presets are "
                    + "inspired by Superkey. Uses WhichSpace, InstantSpaceSwitcher and noswoosh techniques.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
    }

    @objc private func checkForUpdatesAction() {
        UpdateChecker.shared.check { [weak self] state in
            self?.presentUpdateResult(state)
        }
    }

    private func presentUpdateResult(_ state: UpdateChecker.State) {
        switch state {
        case .available(let version):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Faster Spaces \(version) is available"
            alert.informativeText = "You're running \(AppInfo.version). Open the release page to download the update."
            alert.addButton(withTitle: "Download…")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                UpdateChecker.shared.openReleasePage()
            }
        case .upToDate:
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "Faster Spaces \(AppInfo.version) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let message):
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .idle, .checking:
            break
        }
    }

    // MARK: Windows

    private func showSettings() {
        accessibility.refresh()
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Faster Spaces Settings",
                size: NSSize(width: 720, height: 720),
                view: SettingsView()
            )
        }
        present(settingsWindow)
    }

    private func showOnboarding(resetStep: Bool = true) {
        if resetStep {
            AppUIState.shared.onboardingStep = 0
        }
        if onboardingWindow == nil {
            onboardingWindow = makeWindow(
                title: "Welcome to Faster Spaces",
                size: NSSize(width: 640, height: 720),
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
                size: NSSize(width: 860, height: 560),
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
        window.contentMinSize = NSSize(width: 620, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
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

        // Become a regular app before ordering the window. Switching the
        // policy after the window is already front can leave the app out of
        // Command-Tab until the next activation change.
        setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()

        // The WindowServer applies a policy change asynchronously. Re-assert
        // it once the window is actually on screen.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible else { return }
            self.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(
                options: [.activateAllWindows, .activateIgnoringOtherApps]
            )
            window.makeKey()
        }
    }

    private func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        let applied = NSApp.setActivationPolicy(policy)
        Log.info(
            "Activation policy -> \(policy == .regular ? "regular (Command-Tab visible)" : "accessory")"
                + " (applied: \(applied))"
        )
    }

    /// Accessory apps do not appear in Command-Tab. While one of our real
    /// windows is open, temporarily become a regular app so the settings /
    /// onboarding window is reachable; revert when the last one closes.
    private func updateActivationPolicy() {
        let visible = [settingsWindow, onboardingWindow, diagnosticsWindow]
            .compactMap { $0 }
            .contains { $0.isVisible }
        let desired: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        setActivationPolicy(desired)
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    /// Render the onboarding window to a PNG for documentation/screenshots.
    private func captureOnboardingSnapshot() {
        guard let window = onboardingWindow, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error("Onboarding snapshot: could not create bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.error("Onboarding snapshot: could not encode PNG")
            return
        }
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/FasterSpaces-Onboarding.png")
        do {
            try data.write(to: destination)
            Log.info("Onboarding snapshot written to \(destination.path)")
        } catch {
            Log.error("Onboarding snapshot failed: \(error.localizedDescription)")
        }
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

    /// Development aid: post an untagged Option-Tab sequence from inside the
    /// trusted app so the real event-tap path can be exercised without a human
    /// at the keyboard. The tap swallows every one of these events.
    private func simulateOptionTab(commit: Bool) {
        SwipeInterceptor.shared.resetOptionTabCancellation()
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                return
            }
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
        post(0x30, down: true, flags: [.maskAlternate])
        post(0x30, down: false, flags: [.maskAlternate])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if commit {
                post(0x30, down: true, flags: [.maskAlternate])
                post(0x30, down: false, flags: [.maskAlternate])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    post(0x24, down: true, flags: [.maskAlternate])
                    post(0x24, down: false, flags: [.maskAlternate])
                }
            } else {
                post(0x35, down: true, flags: [.maskAlternate])
                post(0x35, down: false, flags: [.maskAlternate])
            }
        }
    }

    /// Development aid: post a Caps Lock layer key + a key through the real
    /// event tap. The frontmost app receives whatever the layer resolves to.
    private func simulateLayer() {
        SettingsStore.shared.hyperKeyEnabled = true
        SettingsStore.shared.hyperKeySource = 0
        SettingsStore.shared.layerDefaultAction = 0
        let source = CGEventSource(stateID: .hidSystemState)
        func postFlags(_ down: Bool) {
            guard let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: 57)
            event.flags = down ? [.maskAlphaShift] : []
            event.post(tap: .cgSessionEventTap)
        }
        func postKey(_ code: CGKeyCode, down: Bool) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                return
            }
            event.flags = []
            event.post(tap: .cgSessionEventTap)
        }
        postFlags(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            postKey(13, down: true) // W -> seeded arrow-up mapping
            postKey(13, down: false)
            postKey(12, down: true) // Q -> passthrough
            postKey(12, down: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                postFlags(false)
            }
        }
    }

    /// Development aid: exercise the real Hyper+S path with untagged Caps Lock
    /// and S events. The event tap performs the actual remapping.
    private func simulateSeekTrigger() {
        SettingsStore.shared.seekEnabled = true
        SettingsStore.shared.hyperKeyEnabled = true
        SettingsStore.shared.hyperKeySource = 0
        let source = CGEventSource(stateID: .hidSystemState)
        func postFlags(_ down: Bool) {
            guard let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: 57)
            event.flags = down ? [.maskAlphaShift] : []
            event.post(tap: .cgSessionEventTap)
        }
        func postKey(_ code: CGKeyCode, down: Bool) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
                return
            }
            event.flags = []
            event.post(tap: .cgSessionEventTap)
        }
        postFlags(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            postKey(1, down: true) // S
            postKey(1, down: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                postFlags(false)
            }
        }
    }

    private func applyTab(_ value: String?) {
        guard let value, let tab = Int(value), (0...4).contains(tab) else { return }
        AppUIState.shared.settingsTab = tab
    }

    // MARK: URL commands

    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "fasterspaces" else { return }
        Log.debug("URL command: \(url.absoluteString)")
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
        case "window":
            let directionName = value("direction")?.lowercased() ?? "next"
            let count = max(1, min(Int(value("count") ?? "1") ?? 1, 10))
            _ = WindowSwitchController.shared.activateNextWindow(reverse: directionName == "previous")
            if count > 1 {
                Log.info("Window switch URL count=\(count) is informational; one step applied")
            }
        case "previous-space":
            SpaceHistory.shared.switchToPreviousSpace()
        case "settings":
            applyTab(value("tab"))
            showSettings()
        case "check-updates":
            UpdateChecker.shared.check()
        case "diagnostics":
            showDiagnostics()
        case "onboarding":
            showOnboarding()
        case "onboarding-snapshot":
            if let step = Int(value("step") ?? "0") {
                AppUIState.shared.onboardingStep = min(max(step, 0), 3)
            }
            showOnboarding(resetStep: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.captureOnboardingSnapshot()
            }
        case "toggle":
            settings.enabled.toggle()
        case "status":
            let status = "Status: \(switcher.currentSummary()); trusted=\(accessibility.isTrusted); tap=\(accessibility.tapInstalled); postEvent=\(CGPreflightPostEventAccess()); listen=\(CGPreflightListenEventAccess()); screenRecording=\(ScreenCaptureStatusModel.shared.isGranted); snapshots=\(settings.windowSnapshotsEnabled)"
            Log.info(status)
        case "snapshot":
            applyTab(value("tab"))
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.captureSettingsSnapshot()
            }
        case "hud":
            WindowSwitchController.shared.previewHUD()
        case "hud-snapshot":
            WindowSwitchController.shared.previewHUD()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let destination = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/FasterSpaces-WindowHUD.png")
                WindowSwitchHUD.shared.capturePNG(to: destination)
            }
        case "window-preview":
            let windows = WindowCatalogService.shared.windowsForImmediateUse()
            let index = max(0, min(Int(value("index") ?? "0") ?? 0, max(windows.count - 1, 0)))
            let destination = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/FasterSpaces-WindowSwitcher.png")
            WindowSwitcherOverlay.shared.writePreview(
                to: destination,
                windows: windows,
                selectedIndex: index,
                showSnapshots: value("snapshots") == "1"
            )
        case "window-swipe":
            let steps = max(1, min(Int(value("steps") ?? "1") ?? 1, 10))
            WindowSwitchController.shared.previewSwipe(steps: steps)
        case "test-option-tab":
            simulateOptionTab(commit: value("mode")?.lowercased() == "commit")
        case "test-gesture":
            let fingers = Int(value("fingers") ?? "") ?? SettingsStore.shared.windowFingers
            let progress = Double(value("progress") ?? "") ?? 0.20
            SwipeInterceptor.shared.testGesture(fingers: fingers, progress: progress)
        case "seek":
            SeekController.shared.begin(query: value("query"), bundleIdentifier: value("bundle"))
        case "seek-snapshot":
            SeekController.shared.begin(query: value("query"), bundleIdentifier: value("bundle"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let destination = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop/FasterSpaces-Seek.png")
                SeekController.shared.capturePNG(to: destination)
            }
        case "seek-commit":
            SeekController.shared.commitSelectedForTesting()
        case "seek-close":
            SeekController.shared.close()
        case "screen-permission":
            let granted = ScreenCaptureStatusModel.shared.request()
            Log.info("Screen Recording request returned \(granted)")
        case "screen-settings":
            ScreenCaptureStatusModel.shared.openSystemSettings()
        case "restart":
            NotificationCenter.default.post(name: .fasterSpacesRestartForScreenCapture, object: nil)
        case "hide-windows":
            settingsWindow?.close()
            onboardingWindow?.close()
            diagnosticsWindow?.close()
            DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
        case "ax-dump":
            SeekController.debugDump(bundleIdentifier: value("bundle") ?? "com.apple.TextEdit")
        case "test-seek-trigger":
            simulateSeekTrigger()
        case "test-layer":
            simulateLayer()
        case "dock":
            settings.dockClicksEnabled.toggle()
            DispatchQueue.main.async { [weak self] in self?.syncDockFeatures() }
        case "pick-dock":
            _ = dockController.start()
            dockController.toggleAppPicker()
        case "dock-status":
            Log.info("Dock status: enabled=\(settings.dockClicksEnabled) active=\(dockStatus.monitoringActive) tiles=\(dockStatus.cachedDockTileCount) picker=\(dockStatus.isPickingApp)")
        case "dock-rules":
            for rule in dockRules.rules {
                Log.info("Dock rule: \(rule.displayName) [\(rule.bundleIdentifier)] = \(rule.action.title)")
            }
        case "dock-tiles":
            let snapshot = dockInspector.scan()
            for tile in snapshot.tiles {
                Log.info("Dock tile: \(tile.title) frame=\(tile.frame) running=\(tile.isRunning) bundle=\(tile.bundleIdentifier ?? "-")")
            }
        case "add-dock-app":
            guard let bundle = value("bundle"), !bundle.isEmpty else { break }
            let name = value("name") ?? bundle
            let result = dockRules.addOrUpdate(bundleIdentifier: bundle, title: name)
            if let raw = value("action")?.lowercased(),
               let action = DockClickAction.allCases.first(where: { $0.rawValue.lowercased() == raw || $0.title.lowercased() == raw }) {
                dockRules.setAction(action, for: result.rule.id)
            }
            Log.info("Dock rule added: \(result.rule.displayName) = \(result.rule.action.title)")
        case "click-dock":
            guard let title = value("title") else { break }
            let snapshot = dockInspector.scan()
            guard let tile = snapshot.tiles.first(where: {
                $0.title.localizedCaseInsensitiveContains(title)
            }) else {
                Log.info("Dock tile not found: \(title)")
                break
            }
            let point = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            let source = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cgSessionEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cgSessionEventTap)
            CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cgSessionEventTap)
            Log.info("Posted Dock click at \(point) for \(tile.title)")
        default:
            showSettings()
        }
    }
}
