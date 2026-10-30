import AppKit

final class DockAppPickerHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    func showInstruction() {
        show(
            "Click a Dock app to add it. New apps start at New Window; change the behavior in Settings.",
            autoHide: false
        )
    }

    func showConfirmation(name: String, action: DockClickAction) {
        show("\(name): \(action.title)", autoHide: true)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func show(_ text: String, autoHide: Bool) {
        hideWorkItem?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        label?.stringValue = text
        position(panel)
        panel.orderFrontRegardless()

        if autoHide {
            let item = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 62),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 15
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        self.label = label

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(icon)
        effect.addSubview(label)
        panel.contentView = effect

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: 520, height: 62)
        let frame = NSRect(
            x: visible.midX - size.width * 0.5,
            y: visible.maxY - size.height - 18,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }
}
