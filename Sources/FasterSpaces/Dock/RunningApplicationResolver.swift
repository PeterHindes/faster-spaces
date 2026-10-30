import AppKit
import Foundation

enum RunningApplicationResolver {
    static func application(for tile: DockTile) -> NSRunningApplication? {
        let ourBundleIdentifier = Bundle.main.bundleIdentifier

        if let bundleIdentifier = tile.bundleIdentifier {
            let matches = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { $0.bundleIdentifier != ourBundleIdentifier }
            if let exact = matches.first(where: { sameBundleLocation($0, as: tile.applicationURL) }) {
                return exact
            }
            if let first = matches.first(where: { $0.activationPolicy == .regular }) ?? matches.first {
                return first
            }
        }

        if let applicationURL = tile.applicationURL {
            let target = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
            if let match = NSWorkspace.shared.runningApplications.first(where: { app in
                guard let bundleURL = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() else {
                    return false
                }
                return bundleURL == target && app.bundleIdentifier != ourBundleIdentifier
            }) {
                return match
            }
        }

        return application(titled: tile.title)
    }

    static func application(titled title: String) -> NSRunningApplication? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ourBundleIdentifier = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy != .prohibited &&
            app.bundleIdentifier != ourBundleIdentifier
        }

        if let exact = apps.first(where: { $0.localizedName == trimmed }) {
            return exact
        }

        let normalizedTitle = normalize(trimmed)
        if let bundleMatch = apps.first(where: { normalize(bundleName(of: $0)) == normalizedTitle }) {
            return bundleMatch
        }
        if let localizedMatch = apps.first(where: { normalize($0.localizedName ?? "") == normalizedTitle }) {
            return localizedMatch
        }

        return apps.first { app in
            let candidate = normalize(app.localizedName ?? "")
            guard !candidate.isEmpty else { return false }
            return candidate == normalizedTitle ||
                normalizedTitle.hasPrefix(candidate + " ") ||
                candidate.hasPrefix(normalizedTitle + " ")
        }
    }

    static func isRunning(titled title: String) -> Bool {
        application(titled: title) != nil
    }

    private static func sameBundleLocation(_ app: NSRunningApplication, as url: URL?) -> Bool {
        guard let url,
              let bundleURL = app.bundleURL else { return false }
        return bundleURL.standardizedFileURL.resolvingSymlinksInPath() ==
            url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func bundleName(of app: NSRunningApplication) -> String {
        app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    static func normalize(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let withoutExtension = folded.replacingOccurrences(of: ".app", with: "")
        let scalars = withoutExtension.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
