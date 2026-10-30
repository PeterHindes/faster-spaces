import Foundation

/// A small LaunchAgent-backed login item.
///
/// SMAppService is the preferred modern API, but it rejects some locally
/// signed builds and can require manual approval in Login Items. A classic
/// per-user LaunchAgent is reliable for a self-contained .app and is easy to
/// remove. It starts the same executable macOS is already running, with
/// `RunAtLoad` and no `KeepAlive` (quitting the app must actually quit it).
enum LaunchAtLogin {
    static let label = "com.fasterplz.fasterspaces.login"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            return enable()
        } else {
            disable()
            return true
        }
    }

    /// Rewrite the agent if the app has been moved since it was registered, and
    /// make sure launchd has the current copy.
    static func refreshIfEnabled() {
        guard isEnabled else { return }
        _ = enable()
    }

    private static func enable() -> Bool {
        guard let executable = Bundle.main.executablePath else {
            Log.error("Launch at login: no executable path")
            return false
        }

        let directory = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        if !BuildMode.isRelease {
            plist["StandardErrorPath"] = Log.fileURL.path
        }

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            Log.error("Launch at login: could not write agent: \(error.localizedDescription)")
            return false
        }

        // Do NOT bootstrap the agent here: the app is already running, and
        // `bootstrap` would immediately launch a second copy. The plist is
        // loaded by launchd at the next login.
        Log.info("Launch at login enabled for next login: \(executable)")
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func disable() {
        // Removing the plist is enough for future logins. Deliberately do not
        // `bootout` here: if this process was started by the agent, booting it
        // out would terminate the app the user is currently using.
        try? FileManager.default.removeItem(at: plistURL)
        Log.info("Launch at login disabled")
    }
}
