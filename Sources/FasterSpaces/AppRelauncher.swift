import AppKit
import Foundation

/// Relaunch the app in a fresh process. macOS's Screen Recording grant is
/// frequently not honored by the already-running process, so the onboarding
/// and Settings use this after the permission arrives. A detached shell waits
/// for this process to exit, then opens the same bundle.
enum AppRelauncher {
    static func relaunch(reason: String) {
        let path = Bundle.main.bundlePath
        Log.info("Relaunching Faster Spaces for \(reason)")
        let script = "sleep 2.0; /usr/bin/open \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            Log.error("Could not schedule relaunch: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}
