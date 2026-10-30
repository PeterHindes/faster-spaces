import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

final class NewWindowController {
    private let queue = DispatchQueue(label: "com.peter.newwindowplz.new-window", qos: .userInitiated)
    private let resolver = NewWindowMenuResolver()
    private let model: DockStatusModel
    var onWillActivate: (() -> Void)?

    init(model: DockStatusModel) {
        self.model = model
    }

    func openNewWindow(in application: NSRunningApplication, tile: DockTile) {
        let pid = application.processIdentifier
        let name = application.localizedName ?? tile.title

        queue.async { [weak self] in
            guard let self else { return }
            let start = CACurrentMediaTime()
            DispatchQueue.main.sync { [weak self] in
                self?.onWillActivate?()
            }

            guard !application.isTerminated else {
                self.reportFailure("\(name) quit before the window could open.")
                return
            }

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.45)

            var method: String?

            if let match = self.resolver.match(for: appElement, pid: pid) {
                let error = AXUIElementPerformAction(match.element, kAXPressAction as CFString)
                if error == .success {
                    method = "menu “\(match.title)”"
                } else {
                    Log.error("AXPress failed for \(name): \(error.rawValue)")
                    self.resolver.invalidate(pid: pid)

                    if let retry = self.resolver.match(for: appElement, pid: pid),
                       AXUIElementPerformAction(retry.element, kAXPressAction as CFString) == .success {
                        method = "menu “\(retry.title)”"
                    }
                }
            }

            if method == nil {
                // No usable menu item. Activate first, then send the standard
                // New command directly to the process. This covers apps with
                // custom or lazily-built menus.
                DispatchQueue.main.sync {
                    _ = application.activate(options: [.activateIgnoringOtherApps])
                }
                Thread.sleep(forTimeInterval: 0.30)
                self.postCommandN(to: pid)
                method = "⌘N fallback"
            } else {
                // Give the freshly-created window a beat to become key before
                // bringing the application forward.
                Thread.sleep(forTimeInterval: 0.025)
                DispatchQueue.main.async {
                    application.activate(options: [.activateIgnoringOtherApps])
                }
            }

            let elapsed = (CACurrentMediaTime() - start) * 1_000
            let summary = "\(name) → \(method ?? "new window") · \(String(format: "%.1f", elapsed)) ms"
            Log.info("\(summary)")
            DispatchQueue.main.async {
                self.model.lastAction = summary
                self.model.lastFailure = nil
            }
        }
    }

    func forget(pid: pid_t) {
        queue.async { [weak self] in
            self?.resolver.invalidate(pid: pid)
        }
    }

    private func postCommandN(to pid: pid_t) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyN: CGKeyCode = 0x2D

        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: true) {
            down.flags = .maskCommand
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyN, keyDown: false) {
            up.flags = .maskCommand
            up.postToPid(pid)
        }
    }

    private func reportFailure(_ message: String) {
        Log.error("\(message)")
        DispatchQueue.main.async { [weak self] in
            self?.model.lastFailure = message
        }
    }
}
