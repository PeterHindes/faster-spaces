import Foundation

enum DockSystemApps {
    /// Dock tiles that are system launchers rather than document apps. A
    /// "new window" command makes no sense for these and would swallow the
    /// click, so always let the Dock handle them.
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.launchpad.launcher",
        "com.apple.apps.launcher",
        "com.apple.exposelauncher",
        "com.apple.missioncontrol",
        "com.apple.ScreenSaver.Engine"
    ]

    private static let excludedURLNames: Set<String> = [
        "launchpad",
        "apps"
    ]

    static func isExcluded(_ tile: DockTile) -> Bool {
        if let bundleIdentifier = tile.bundleIdentifier,
           excludedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        if let applicationURL = tile.applicationURL {
            let name = applicationURL.deletingPathExtension().lastPathComponent.lowercased()
            if excludedURLNames.contains(name) {
                return true
            }
        }
        return false
    }
}
