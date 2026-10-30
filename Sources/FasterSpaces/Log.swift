import AppKit
import Foundation

/// Tiny thread-safe logger. The event-tap callback runs on the main run loop,
/// but logging is also used from permission polling and URL handling, so the
/// lock keeps writes and the in-memory ring buffer consistent.
enum Log {
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case error = "ERROR"
    }

    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let maxLines = 500
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static let fileURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FasterSpaces.log")
    }()

    static var isDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debugLogging")
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        write(.debug, message())
    }

    static func info(_ message: @autoclosure () -> String) {
        write(.info, message())
    }

    static func error(_ message: @autoclosure () -> String) {
        write(.error, message())
    }

    private static func write(_ level: Level, _ message: String) {
        guard !BuildMode.isRelease else { return }

        let stamp = formatter.string(from: Date())
        let line = "\(stamp) [\(level.rawValue)] \(message)\n"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()

        if let data = line.data(using: .utf8) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        NotificationCenter.default.post(name: .fasterSpacesLogDidChange, object: nil)
    }

    static func recent() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined()
    }

    static func clear() {
        guard !BuildMode.isRelease else { return }
        lock.lock()
        lines.removeAll()
        lock.unlock()
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: .fasterSpacesLogDidChange, object: nil)
    }

    static func revealInFinder() {
        guard !BuildMode.isRelease else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
