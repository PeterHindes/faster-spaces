import AppKit
import QuartzCore
import UniformTypeIdentifiers

/// A compact, click-through window strip. It is the visual language of the
/// Spaces HUD applied to windows: a row of app icons and window titles where
/// the selected window is highlighted. It is purely cosmetic and never blocks
/// the switch or the event tap.
final class WindowSwitchHUD {
    static let shared = WindowSwitchHUD()

    private var window: NSWindow?
    private var background: CALayer?
    private var cardsLayer: CALayer?
    private var countLabel: CATextLayer?
    private var finishWorkItem: DispatchWorkItem?
    private var iconCache: [pid_t: CGImage] = [:]
    private var currentWindows: [SwitchWindow] = []
    private var currentIndex = 0
    private var visibleStart = 0
    private var visibleEnd = 0
    private var generation = 0

    private let cardWidth: CGFloat = 84
    private let cardHeight: CGFloat = 62
    private let gap: CGFloat = 8
    private let padding: CGFloat = 12
    private let headerHeight: CGFloat = 18
    private let animationDuration: CFTimeInterval = 0.16

    private var accentColor: CGColor {
        NSColor(calibratedRed: 0.29, green: 0.48, blue: 1.0, alpha: 1).cgColor
    }

    private var inactiveColor: CGColor {
        NSColor.white.withAlphaComponent(0.10).cgColor
    }

    private init() {}

    private(set) var isVisible = false

    var selectedWindow: SwitchWindow? {
        currentWindows.indices.contains(currentIndex) ? currentWindows[currentIndex] : nil
    }

    // MARK: Show / update / hide

    func show(windows: [SwitchWindow], selectedIndex: Int, on screen: NSScreen) {
        guard !windows.isEmpty else { return }
        finishWorkItem?.cancel()
        finishWorkItem = nil
        generation += 1
        currentWindows = windows
        currentIndex = min(max(selectedIndex, 0), windows.count - 1)

        if !isVisible {
            buildWindow(on: screen)
            isVisible = true
        }

        let range = visibleRange()
        rebuildCards(range: range, animateFrom: nil)
        visibleStart = range.lowerBound
        visibleEnd = range.upperBound
        window?.alphaValue = 1
        window?.orderFrontRegardless()
    }

    func update(windows: [SwitchWindow], selectedIndex: Int) {
        guard isVisible, !windows.isEmpty else { return }
        let previousIndex = currentIndex
        currentWindows = windows
        currentIndex = min(max(selectedIndex, 0), windows.count - 1)

        let range = visibleRange()
        if range.lowerBound != visibleStart || range.upperBound != visibleEnd {
            let oldStart = visibleStart
            visibleStart = range.lowerBound
            visibleEnd = range.upperBound
            rebuildCards(range: range, animateFrom: oldStart)
        } else {
            updateSelection(previousIndex: previousIndex, animate: true)
        }
        updateCountLabel()
        window?.orderFrontRegardless()
    }

    func hide(immediately: Bool = false) {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        guard let window else {
            reset()
            return
        }
        guard !immediately else {
            window.orderOut(nil)
            reset()
            return
        }
        let token = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            window.orderOut(nil)
            self.reset()
        }
    }

    /// The Spaces HUD waits for the physical gesture to finish. The window HUD
    /// is hidden by the controller when the gesture ends, so it only needs a
    /// safety timeout for a lost end event.
    func scheduleSafetyHide(after delay: TimeInterval = 2.0) {
        finishWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        finishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Window construction

    private func buildWindow(on screen: NSScreen) {
        let size = contentSize(cardCount: min(currentWindows.count, SettingsStore.shared.effectiveWindowVisibleCount))
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 70
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isMovable = false
        window.alphaValue = 1

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        let root = CALayer()
        root.frame = NSRect(origin: .zero, size: size)
        view.layer?.addSublayer(root)

        let backgroundLayer = CALayer()
        backgroundLayer.frame = root.bounds
        backgroundLayer.cornerRadius = 18
        backgroundLayer.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.90).cgColor
        backgroundLayer.borderWidth = 1
        backgroundLayer.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        root.addSublayer(backgroundLayer)

        let label = CATextLayer()
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        label.fontSize = 9
        label.alignmentMode = .right
        label.foregroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        label.contentsScale = screen.backingScaleFactor
        label.frame = NSRect(
            x: size.width - 130,
            y: size.height - 16,
            width: 118,
            height: 11
        )
        root.addSublayer(label)

        let cards = CALayer()
        cards.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        root.addSublayer(cards)

        window.contentView = view
        self.window = window
        self.background = backgroundLayer
        cardsLayer = cards
        countLabel = label
    }

    // MARK: Cards

    private func contentSize(cardCount: Int) -> NSSize {
        let count = max(cardCount, 1)
        let width = padding * 2 + CGFloat(count) * cardWidth + CGFloat(count - 1) * gap
        return NSSize(width: width, height: cardHeight + padding * 2 + headerHeight)
    }

    private func visibleRange() -> Range<Int> {
        let settings = SettingsStore.shared
        let maxVisible = min(settings.effectiveWindowVisibleCount, currentWindows.count)
        guard maxVisible > 0 else { return 0..<0 }
        guard currentWindows.count > maxVisible else { return 0..<currentWindows.count }
        let preferredStart = currentIndex - maxVisible / 2
        let start = min(max(preferredStart, 0), currentWindows.count - maxVisible)
        return start..<(start + maxVisible)
    }

    private func rebuildCards(range: Range<Int>, animateFrom oldStart: Int?) {
        guard let cardsLayer, let window else { return }
        let size = window.frame.size
        // Resize the resident window if the visible count changed.
        if abs(size.width - contentSize(cardCount: range.count).width) > 0.5 {
            var frame = window.frame
            frame.size = contentSize(cardCount: range.count)
            let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            frame.origin.x = screenFrame.midX - frame.width / 2
            window.setFrame(frame, display: false)
            background?.frame = NSRect(origin: .zero, size: frame.size)
            cardsLayer.frame = NSRect(origin: .zero, size: frame.size)
            countLabel?.frame = NSRect(
                x: frame.width - 130,
                y: frame.height - 16,
                width: 118,
                height: 11
            )
        }

        cardsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let count = range.count
        let totalWidth = CGFloat(count) * cardWidth + CGFloat(max(count - 1, 0)) * gap
        let startX = (cardsLayer.bounds.width - totalWidth) / 2
        let y = padding
        let offset = (oldStart == nil) ? 0 : CGFloat((oldStart! - range.lowerBound)) * (cardWidth + gap)

        for (slot, index) in range.enumerated() {
            let card = makeCard(
                for: currentWindows[index],
                index: index,
                selected: index == currentIndex,
                screen: window.screen
            )
            let finalX = startX + CGFloat(slot) * (cardWidth + gap)
            card.frame = NSRect(x: finalX + offset, y: y, width: cardWidth, height: cardHeight)
            cardsLayer.addSublayer(card)

            if oldStart != nil {
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.fromValue = card.position.x + offset
                slide.toValue = card.position.x
                slide.duration = animationDuration
                slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1.0)
                card.add(slide, forKey: "slide")
            }
        }
        updateCountLabel()
    }

    private func makeCard(
        for window: SwitchWindow,
        index: Int,
        selected: Bool,
        screen: NSScreen?
    ) -> CALayer {
        let card = CALayer()
        card.cornerRadius = 10
        card.borderWidth = 1
        card.masksToBounds = true
        card.backgroundColor = selected ? accentColor : inactiveColor
        card.borderColor = NSColor.white.withAlphaComponent(selected ? 0.34 : 0.10).cgColor

        if let icon = icon(for: window) {
            let iconLayer = CALayer()
            iconLayer.contents = icon
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.frame = NSRect(x: (cardWidth - 28) / 2, y: 26, width: 28, height: 28)
            card.addSublayer(iconLayer)
        }

        let appLabel = CATextLayer()
        appLabel.string = window.shortAppName
        appLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        appLabel.fontSize = 10
        appLabel.alignmentMode = .center
        appLabel.truncationMode = .end
        appLabel.foregroundColor = NSColor.white.withAlphaComponent(selected ? 1 : 0.82).cgColor
        appLabel.contentsScale = screen?.backingScaleFactor ?? 2
        appLabel.frame = NSRect(x: 4, y: 14, width: cardWidth - 8, height: 12)
        card.addSublayer(appLabel)

        // Do not repeat the app name as the window title. When macOS withholds
        // a title (or it equals the app name), show the window's ordinal so two
        // windows from the same app are still distinguishable.
        let trimmedTitle = window.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameAsApp = trimmedTitle.isEmpty || trimmedTitle == window.appName
        let duplicateCount = currentWindows.filter { $0.pid == window.pid }.count
        let ordinal = currentWindows[...index].filter { $0.pid == window.pid }.count
        let subtitle: String
        if sameAsApp {
            subtitle = duplicateCount > 1 ? "Window \(ordinal)" : "Window"
        } else {
            subtitle = window.shortTitle
        }

        let titleLabel = CATextLayer()
        titleLabel.string = subtitle
        titleLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        titleLabel.fontSize = 9
        titleLabel.alignmentMode = .center
        titleLabel.truncationMode = .end
        titleLabel.foregroundColor = NSColor.white.withAlphaComponent(selected ? 0.78 : 0.52).cgColor
        titleLabel.contentsScale = screen?.backingScaleFactor ?? 2
        titleLabel.frame = NSRect(x: 4, y: 4, width: cardWidth - 8, height: 11)
        card.addSublayer(titleLabel)

        return card
    }

    private func updateSelection(previousIndex: Int, animate: Bool) {
        guard let cardsLayer, let sublayers = cardsLayer.sublayers else { return }
        let range = visibleStart..<visibleEnd
        for (slot, layer) in sublayers.enumerated() {
            let index = range.lowerBound + slot
            guard currentWindows.indices.contains(index) else { continue }
            let selected = index == currentIndex
            let color = selected ? accentColor : inactiveColor
            if animate {
                let animation = CABasicAnimation(keyPath: "backgroundColor")
                animation.fromValue = layer.backgroundColor
                animation.toValue = color
                animation.duration = animationDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "color")
            }
            layer.backgroundColor = color
            layer.borderColor = NSColor.white
                .withAlphaComponent(selected ? 0.34 : 0.10)
                .cgColor
            layer.sublayers?.forEach { sublayer in
                if let text = sublayer as? CATextLayer {
                    let isTitle = text.fontSize <= 9
                    text.foregroundColor = NSColor.white
                        .withAlphaComponent(selected ? (isTitle ? 0.78 : 1) : (isTitle ? 0.52 : 0.82))
                        .cgColor
                }
            }
        }
        _ = previousIndex
    }

    private func updateCountLabel() {
        countLabel?.string = currentWindows.isEmpty
            ? ""
            : "\(currentIndex + 1) / \(currentWindows.count)"
    }

    /// Render the resident HUD to a PNG. This is a development aid for
    /// verifying layout without Screen Recording permission.
    func capturePNG(to url: URL) {
        guard let window, let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
            Log.info("Window HUD snapshot written to \(url.path)")
        } catch {
            Log.error("Window HUD snapshot failed: \(error.localizedDescription)")
        }
    }

    // MARK: Icons

    private func icon(for window: SwitchWindow) -> CGImage? {
        if let cached = iconCache[window.pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return nil }
        let icon = app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
        var rect = NSRect(origin: .zero, size: icon.size)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        iconCache[window.pid] = cgImage
        return cgImage
    }

    private func reset() {
        window?.contentView = nil
        window = nil
        background = nil
        cardsLayer = nil
        countLabel = nil
        currentWindows = []
        currentIndex = 0
        visibleStart = 0
        visibleEnd = 0
        isVisible = false
        generation += 1
        iconCache.removeAll()
    }
}
