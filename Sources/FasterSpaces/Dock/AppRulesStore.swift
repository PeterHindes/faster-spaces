import AppKit
import Combine
import Foundation

enum DockClickAction: String, Codable, CaseIterable, Identifiable {
    case moveHere
    case newWindow
    case unchanged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .moveHere: return "Bring Here"
        case .newWindow: return "New Window"
        case .unchanged: return "None"
        }
    }

    var detail: String {
        switch self {
        case .moveHere: return "Bring the existing window to this Space"
        case .newWindow: return "Open another window"
        case .unchanged: return "Use the normal Dock click by default"
        }
    }
}

struct DockAppRule: Codable, Identifiable, Equatable {
    var bundleIdentifier: String
    var displayName: String
    var action: DockClickAction

    var id: String { bundleIdentifier }
}

final class AppRulesStore: ObservableObject {
    static let shared = AppRulesStore()

    @Published private(set) var rules: [DockAppRule]

    private let defaults: UserDefaults
    private let rulesKey = "dockClickRules.v1"
    private let seedRemovalKey = "dockClickRules.v2.removedLegacySeeds"
    private let lock = NSLock()
    private var dockActions: [String: DockClickAction] = [:]

    private static let legacySeeds: [(id: String, name: String)] = [
        ("com.apple.iCal", "Calendar"),
        ("com.apple.ActivityMonitor", "Activity Monitor")
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: rulesKey),
           let decoded = try? JSONDecoder().decode([DockAppRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }

        // 1.4.0 seeded Calendar and Activity Monitor automatically. They were
        // not user selections, so remove them once if they are still untouched.
        if !defaults.bool(forKey: seedRemovalKey) {
            let before = rules
            rules.removeAll { rule in
                guard rule.action == .moveHere else { return false }
                return Self.legacySeeds.contains {
                    $0.id == rule.bundleIdentifier && $0.name == rule.displayName
                }
            }
            defaults.set(true, forKey: seedRemovalKey)
            if rules != before {
                save()
                return
            }
        }

        rebuildDockActions()
        let imported = importLegacyRulesIfNeeded()
        if imported > 0 {
            Log.info("Imported \(imported) Dock app rule(s) from New Window Plz")
        }
    }

    /// Bring over the per-app behaviors from the old New Window Plz install.
    /// Safe to call repeatedly; the marker prevents accidentally overwriting a
    /// rule the user has already changed here.
    @discardableResult
    func importLegacyRules(force: Bool) -> Int {
        importLegacyRulesIfNeeded(force: force)
    }

    @discardableResult
    private func importLegacyRulesIfNeeded(force: Bool = false) -> Int {
        let marker = "dockClickRules.importedFromNewWindowPlz"
        if !force, defaults.bool(forKey: marker) { return 0 }
        guard let legacy = UserDefaults(suiteName: "com.peter.newwindowplz"),
              let data = legacy.data(forKey: "dockClickRules.v1"),
              let decoded = try? JSONDecoder().decode([DockAppRule].self, from: data),
              !decoded.isEmpty else {
            defaults.set(true, forKey: marker)
            return 0
        }

        if rules.isEmpty || force {
            rules = decoded
        } else {
            for rule in decoded where !rules.contains(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
                rules.append(rule)
            }
        }
        rules.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        save()
        defaults.set(true, forKey: marker)
        return decoded.count
    }

    func rule(for bundleIdentifier: String?) -> DockAppRule? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return rules.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Thread-safe lookup used by the Dock event tap. An unlisted app returns
    /// nil; a listed app with .none returns .none and must pass through.
    func dockTapAction(bundleIdentifier: String?, title: String? = nil) -> DockClickAction? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            lock.lock()
            let action = dockActions[bundleIdentifier]
            lock.unlock()
            if let action { return action }
        }
        if let title, !title.isEmpty {
            lock.lock()
            let action = dockActions["name:\(title.lowercased())"]
            lock.unlock()
            return action
        }
        return nil
    }

    func action(for bundleIdentifier: String?, title: String? = nil) -> DockClickAction? {
        dockTapAction(bundleIdentifier: bundleIdentifier, title: title)
    }

    /// Adding an app always starts at New Window. Selecting an app that is
    /// already listed refreshes its display name but leaves its behavior alone.
    @discardableResult
    func addOrUpdate(bundleIdentifier: String?, title: String) -> (rule: DockAppRule, added: Bool) {
        let trimmedID = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey: String
        if let trimmedID, !trimmedID.isEmpty {
            resolvedKey = trimmedID
        } else {
            resolvedKey = "name:\(title.lowercased())"
        }

        if let index = rules.firstIndex(where: { $0.bundleIdentifier == resolvedKey }) {
            var existing = rules[index]
            if !title.isEmpty {
                existing.displayName = title
            }
            rules[index] = existing
            save()
            return (existing, false)
        }

        let rule = DockAppRule(
            bundleIdentifier: resolvedKey,
            displayName: title.isEmpty ? resolvedKey : title,
            action: .newWindow
        )
        rules.append(rule)
        rules.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        save()
        return (rule, true)
    }

    @discardableResult
    func addApplication(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url) else { return false }
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return addOrUpdate(
            bundleIdentifier: bundle.bundleIdentifier,
            title: displayName
        ).added
    }

    func setAction(_ action: DockClickAction, for bundleIdentifier: String) {
        guard let index = rules.firstIndex(where: { $0.id == bundleIdentifier }) else { return }
        rules[index].action = action
        save()
    }

    func remove(_ bundleIdentifier: String) {
        rules.removeAll { $0.id == bundleIdentifier }
        save()
    }

    func appIcon(for bundleIdentifier: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func save() {
        rebuildDockActions()
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: rulesKey)
    }

    private func rebuildDockActions() {
        var snapshot: [String: DockClickAction] = [:]
        for rule in rules {
            snapshot[rule.bundleIdentifier] = rule.action
        }
        lock.lock()
        dockActions = snapshot
        lock.unlock()
    }
}
