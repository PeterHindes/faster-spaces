import AppKit
import Foundation

@main
struct FasterSpacesMain {
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--self-test") {
            SelfTest.run()
        }

        if arguments.contains("--finger-info") {
            let settings = SettingsStore.shared
            print(FingerConfiguration.autoSourceDescription)
            print("Spaces: \(settings.spacesFingers) fingers (mode \(settings.spacesFingersMode))")
            print("Windows: \(settings.windowFingers) fingers (mode \(settings.windowSwipeFingers))")
            exit(0)
        }

        if arguments.contains("--window-list") {
            let windows = CurrentSpaceWindows.snapshot()
            print("\(windows.count) current-Space window(s):")
            for window in windows {
                print("  \(window.appName) [\(window.windowID)] — \(window.shortTitle)")
            }
            exit(0)
        }

        if arguments.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version)")
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
