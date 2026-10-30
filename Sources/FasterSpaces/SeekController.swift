import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// A lightweight, Accessibility-only "Seek" feature inspired by Superkey.
///
/// Type a phrase, pick a match from the focused app's accessibility tree, and
/// click it. It deliberately does **not** capture the screen or run OCR: text
/// inside images is not found, and the app keeps its no-Screen-Recording
/// privacy model. Text exposed by native controls and web content is found.
final class SeekController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = SeekController()

    private struct Match {
        let text: String
        let role: String
        let frame: CGRect
        let element: AXUIElement
    }

    private final class SeekPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private var panel: SeekPanel?
    private var searchField: NSSearchField?
    private var tableView: NSTableView?
    private var statusLabel: NSTextField?
    private var allMatches: [Match] = []
    private var filtered: [Match] = []
    private var targetPID: pid_t = 0
    private var targetName = ""
    private var targetApplication: NSRunningApplication?
    private var generation = 0
    private var isSearching = false
    private var isClosing = false

    private let panelSize = NSSize(width: 600, height: 440)

    private override init() {
        super.init()
    }

    var isOpen: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Trigger

    /// Called from the event tap before the Hyper presets. Returns true when
    /// the event opened Seek and must be swallowed.
    @discardableResult
    func handleKeyDown(event: CGEvent, hyperActive: Bool) -> Bool {
        let settings = SettingsStore.shared
        guard settings.seekEnabled, !isOpen else { return false }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch settings.seekTrigger {
        case 0:
            guard hyperActive, keyCode == 1 else { return false } // S
        default:
            let relevant = event.flags.intersection(
                [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            )
            guard keyCode == 3, // F
                  relevant == [.maskControl, .maskAlternate, .maskCommand] else {
                return false
            }
        }

        begin()
        return true
    }

    // MARK: - Open / close

    func begin(query: String? = nil, bundleIdentifier: String? = nil) {
        guard AXIsProcessTrusted() else {
            Log.error("Seek requires Accessibility permission")
            return
        }
        if isOpen {
            panel?.makeKeyAndOrderFront(nil)
            if let query {
                searchField?.stringValue = query
                applyFilter()
            }
            return
        }

        let app: NSRunningApplication?
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first { !$0.isTerminated }
        } else {
            app = targetApplicationForSeek()
        }
        guard let app else {
            Log.error("Seek: no target application")
            return
        }
        targetApplication = app
        targetPID = app.processIdentifier
        targetName = app.localizedName ?? "app"
        allMatches = []
        filtered = []
        generation += 1
        let currentGeneration = generation

        buildPanel()
        searchField?.stringValue = query ?? ""
        isSearching = true
        statusLabel?.stringValue = "Searching \(targetName)…"
        showPanel()
        applyFilter()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let matches = Self.collectMatches(pid: app.processIdentifier)
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.isSearching = false
                self.allMatches = matches
                self.applyFilter()
                Log.info("Seek found \(matches.count) text element(s) in \(self.targetName)")
            }
        }
    }

    func close(reactivateTarget: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        generation += 1
        panel?.orderOut(nil)
        panel?.resignKey()
        allMatches = []
        filtered = []
        tableView?.reloadData()
        searchField?.stringValue = ""
        isSearching = false
        if reactivateTarget, let targetApplication, !targetApplication.isTerminated {
            targetApplication.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Target

    private func targetApplicationForSeek() -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != own {
            return front
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier != own &&
            $0.activationPolicy == .regular &&
            !$0.isTerminated
        }
    }

    // MARK: - Accessibility collection

    private static func collectMatches(pid: pid_t) -> [Match] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.20)

        var roots = AX.elements(app, kAXWindowsAttribute as String)
        if roots.isEmpty, let focused = AX.element(app, kAXFocusedWindowAttribute as String) {
            roots = [focused]
        }
        if roots.isEmpty { return [] }

        let searchableRoles: Set<String> = [
            "AXStaticText", "AXTextField", "AXTextArea", "AXComboBox",
            "AXButton", "AXLink", "AXCheckBox", "AXRadioButton",
            "AXPopUpButton", "AXCell", "AXHeading", "AXListItem",
            "AXWebArea", "AXImage",
        ]
        let ignoredRoles: Set<String> = [
            "AXMenuBar", "AXMenu", "AXMenuItem", "AXApplication",
            "AXWindow", "AXSheet", "AXDrawer", "AXScrollBar",
        ]

        var matches: [Match] = []
        var visited = 0
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(1.2)
        var stack: [(element: AXUIElement, depth: Int)] = roots.map { ($0, 0) }

        while let item = stack.popLast() {
            guard visited < 6_000, Date() < deadline, matches.count < 400 else { break }
            visited += 1
            if item.depth > 12 { continue }

            let role = AX.string(item.element, kAXRoleAttribute as String) ?? ""
            // Ignored roles are not matches themselves, but their children
            // must still be traversed: roots are AXWindow elements.
            if !ignoredRoles.contains(role), searchableRoles.contains(role) {
                let values = [
                    AX.string(item.element, kAXTitleAttribute as String),
                    AX.string(item.element, kAXValueAttribute as String),
                    AX.string(item.element, kAXDescriptionAttribute as String),
                    AX.string(item.element, kAXHelpAttribute as String),
                    AX.string(item.element, "AXPlaceholderValue"),
                ]
                if let frame = AX.frame(item.element),
                   frame.width >= 4, frame.height >= 4,
                   isOnScreen(frame) {
                    for raw in values {
                        guard let raw else { continue }
                        let text = raw
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\t", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let display = text.count > 220 ? String(text.prefix(220)) + "…" : text
                        let key = "\(display)|\(Int(frame.minX))|\(Int(frame.minY))"
                        guard !seen.contains(key) else { continue }
                        seen.insert(key)
                        matches.append(Match(
                            text: display,
                            role: role,
                            frame: frame,
                            element: item.element
                        ))
                    }
                }
            }

            for child in AX.elements(item.element, kAXChildrenAttribute as String) {
                stack.append((child, item.depth + 1))
            }
        }

        // Top-to-bottom, left-to-right reading order.
        matches.sort {
            if abs($0.frame.minY - $1.frame.minY) > 4 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        return matches
    }

    private static func isOnScreen(_ frame: CGRect) -> Bool {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return true }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for display in displays.prefix(Int(count)) {
            if CGDisplayBounds(display).insetBy(dx: -1, dy: -1).contains(center) {
                return true
            }
        }
        return false
    }

    /// Development aid: dump the accessibility tree so a missing match can be
    /// diagnosed without guessing at roles or attribute types.
    static func debugDump(bundleIdentifier: String) {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first else {
            Log.info("AX dump: app not running: \(bundleIdentifier)")
            return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        let roots = AX.elements(element, kAXWindowsAttribute as String)
        Log.info("AX dump for \(bundleIdentifier) pid=\(app.processIdentifier) windows=\(roots.count)")
        var stack: [(AXUIElement, Int)] = roots.map { ($0, 0) }
        var count = 0
        let deadline = Date().addingTimeInterval(2.0)
        while let (node, depth) = stack.popLast(), count < 250, Date() < deadline {
            count += 1
            let role = AX.string(node, kAXRoleAttribute as String) ?? "?"
            let title = AX.string(node, kAXTitleAttribute as String) ?? ""
            let value = AX.string(node, kAXValueAttribute as String) ?? ""
            let desc = AX.string(node, kAXDescriptionAttribute as String) ?? ""
            let frame = AX.frame(node)
            var valueType = "nil"
            if let raw = AX.attribute(node, kAXValueAttribute as String) {
                valueType = "\(CFGetTypeID(raw))"
            }
            Log.info("AX[\(depth)] role=\(role) title=\(title.prefix(40)) value=\(value.prefix(60)) desc=\(desc.prefix(30)) vtype=\(valueType) frame=\(frame?.debugDescription ?? "nil")")
            guard depth < 8 else { continue }
            for child in AX.elements(node, kAXChildrenAttribute as String) {
                stack.append((child, depth + 1))
            }
        }
        Log.info("AX dump complete: \(count) nodes")
    }

    // MARK: - Panel

    private func buildPanel() {
        guard panel == nil else { return }

        let panel = SeekPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.placeholderString = "Seek text on screen…"
        search.font = .systemFont(ofSize: 19, weight: .regular)
        search.focusRingType = .none
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.sendsSearchStringImmediately = true

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.width = 540
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↑↓ choose   ·   Return click   ·   Esc cancel")
        hint.font = .systemFont(ofSize: 10, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(icon)
        effect.addSubview(search)
        effect.addSubview(status)
        effect.addSubview(scroll)
        effect.addSubview(hint)
        panel.contentView = effect

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: effect.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            search.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            search.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            search.heightAnchor.constraint(equalToConstant: 28),

            status.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 22),
            status.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -22),
            status.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),

            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),

            hint.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])

        self.panel = panel
        self.searchField = search
        self.tableView = table
        self.statusLabel = status
    }

    private func showPanel() {
        guard let panel else { return }
        let screen = NSScreen.underCursor ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.maxY - panelSize.height - 120
            )
            panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    /// Clicking away closes Seek instead of leaving a floating, non-key panel
    /// that would keep swallowing the keyboard paths.
    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, panel?.isVisible == true else { return }
        close(reactivateTarget: false)
    }

    // MARK: - Filtering

    private func applyFilter() {
        let query = (searchField?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if query.isEmpty {
            filtered = Array(allMatches.prefix(200))
        } else {
            let matches = allMatches.filter { $0.text.lowercased().contains(query) }
            filtered = matches.sorted { lhs, rhs in
                let lprefix = lhs.text.lowercased().hasPrefix(query)
                let rprefix = rhs.text.lowercased().hasPrefix(query)
                if lprefix != rprefix { return lprefix }
                return lhs.text.count < rhs.text.count
            }
            filtered = Array(filtered.prefix(200))
        }

        tableView?.reloadData()
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView?.scrollRowToVisible(0)
        }
        updateStatus(query: query)
    }

    private func updateStatus(query: String) {
        if isSearching {
            statusLabel?.stringValue = "Searching \(targetName)…"
            return
        }
        if allMatches.isEmpty {
            statusLabel?.stringValue = "No accessibility text found in \(targetName). Seek does not use OCR."
        } else if filtered.isEmpty {
            statusLabel?.stringValue = "No matches for “\(query)” in \(targetName)"
        } else {
            statusLabel?.stringValue = "\(filtered.count) match\(filtered.count == 1 ? "" : "es") in \(targetName)"
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SeekCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13, weight: .regular)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            title.tag = 101
            let role = NSTextField(labelWithString: "")
            role.font = .systemFont(ofSize: 10, weight: .medium)
            role.textColor = .secondaryLabelColor
            role.alignment = .right
            role.translatesAutoresizingMaskIntoConstraints = false
            role.tag = 102
            cell.addSubview(title)
            cell.addSubview(role)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                title.trailingAnchor.constraint(equalTo: role.leadingAnchor, constant: -8),
                role.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                role.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                role.widthAnchor.constraint(equalToConstant: 110),
            ])
        }

        let match = filtered[row]
        (cell.viewWithTag(101) as? NSTextField)?.stringValue = match.text
        (cell.viewWithTag(102) as? NSTextField)?.stringValue = roleLabel(match.role)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // The table owns the selection; nothing else to mirror.
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "AXStaticText": return "text"
        case "AXTextField": return "field"
        case "AXTextArea": return "text area"
        case "AXButton": return "button"
        case "AXLink": return "link"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "popup"
        case "AXComboBox": return "combo box"
        case "AXCell": return "cell"
        case "AXHeading": return "heading"
        case "AXListItem": return "item"
        case "AXWebArea": return "web"
        case "AXImage": return "image"
        default: return role.replacingOccurrences(of: "AX", with: "")
        }
    }

    // MARK: - Field delegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            moveSelection(by: 1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty, let tableView else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Commit

    /// Development aid used by `fasterspaces://seek-commit`.
    func commitSelectedForTesting() {
        commit()
    }

    private func commit() {
        guard let tableView else { return }
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let match = filtered[row]
        let target = targetApplication
        close(reactivateTarget: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.click(match)
            target?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private static func click(_ match: Match) {
        let role = match.role
        if role == "AXButton" || role == "AXCheckBox" || role == "AXRadioButton" ||
            role == "AXLink" || role == "AXMenuItem" {
            if AXUIElementPerformAction(match.element, kAXPressAction as CFString) == .success {
                Log.info("Seek pressed \(role) “\(match.text.prefix(60))”")
                return
            }
        }

        let point = CGPoint(x: match.frame.midX, y: match.frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(15_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        Log.info("Seek clicked \(role) “\(match.text.prefix(60))” at \(point)")
    }

    // MARK: - Snapshot aid

    func capturePNG(to url: URL) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        Log.info("Seek snapshot written to \(url.path)")
    }
}
