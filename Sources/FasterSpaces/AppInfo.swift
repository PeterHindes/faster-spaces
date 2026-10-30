import Foundation

/// Product identity that is safe to reference from nonisolated code (the
/// self-test and CLI modes run before NSApplication exists). The build script
/// stamps CFBundleShortVersionString from the last reachable release tag, or
/// `dev` when the checkout has no tag.
enum AppInfo {
    static let version: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "dev" : trimmed
    }()
    static let name = "Faster Spaces"
}
