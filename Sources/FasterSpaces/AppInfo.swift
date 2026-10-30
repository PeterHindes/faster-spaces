import Foundation

/// Product identity that is safe to reference from nonisolated code (the
/// self-test and CLI modes run before NSApplication exists).
enum AppInfo {
    static let version = "2.1.1"
    static let name = "Faster Spaces"
}
