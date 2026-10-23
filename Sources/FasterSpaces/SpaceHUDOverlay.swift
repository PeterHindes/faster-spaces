import AppKit
import QuartzCore

/// A compact, purely visual direction cue. Two rounded desktop tiles slide in
/// the direction of travel for 0.25 s. It is a borderless, click-through HUD
/// and has no interaction with the Dock or the Space switch itself.
final class SpaceHUDOverlay {
    static let shared = SpaceHUDOverlay()

    private var window: NSWindow?
    private var activeSince = Date.distantPast
    private var finishWorkItem: DispatchWorkItem?
    private var destinationLabel: CATextLayer?
    private var hudDirection = 0
    private var waitingForGestureEnd = false
    private(set) var isActive = false
    private let maxLifetime: TimeInterval = 2.0

    private let size = NSSize(width: 164, height: 58)
    private let cardSize = NSSize(width: 58, height: 34)
    private let gap: CGFloat = 16

    private init() {}

    func show(
        from: Int,
        to: Int,
        direction: Int,
        on screen: NSScreen,
        waitForGestureEnd: Bool = false
    ) {
        guard !isActive else { return }
        isActive = true
        activeSince = Date()
        hudDirection = direction
        waitingForGestureEnd = waitForGestureEnd

        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 26
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

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        let root = CALayer()
        root.frame = NSRect(origin: .zero, size: size)
        view.layer?.addSublayer(root)

        let background = CALayer()
        background.frame = root.bounds
        background.cornerRadius = 18
        background.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.86).cgColor
        background.borderWidth = 1
        background.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        root.addSublayer(background)

        let currentX = direction > 0 ? 16 : 16 + cardSize.width + gap
        let destinationX = direction > 0 ? 16 + cardSize.width + gap : 16
        let y = (size.height - cardSize.height) / 2

        let current = makeCard(
            number: from,
            frame: NSRect(x: currentX, y: y, width: cardSize.width, height: cardSize.height),
            highlight: true,
            scale: screen.backingScaleFactor
        )
        let destination = makeCard(
            number: to,
            frame: NSRect(x: destinationX, y: y, width: cardSize.width, height: cardSize.height),
            highlight: false,
            scale: screen.backingScaleFactor
        )
        root.addSublayer(current)
        root.addSublayer(destination)
        destinationLabel = destination.sublayers?
            .compactMap { $0 as? CATextLayer }
            .first

        window.contentView = view
        window.orderFrontRegardless()
        window.displayIfNeeded()
        self.window = window

        let travel = (cardSize.width + gap) * CGFloat(direction > 0 ? -1 : 1)
        let duration: CFTimeInterval = 0.18
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1.0)

        let currentSlide = CABasicAnimation(keyPath: "transform.translation.x")
        currentSlide.fromValue = 0
        currentSlide.toValue = travel
        currentSlide.duration = duration
        currentSlide.timingFunction = timing
        currentSlide.fillMode = .forwards
        currentSlide.isRemovedOnCompletion = false

        let currentFade = CABasicAnimation(keyPath: "opacity")
        currentFade.fromValue = 1
        currentFade.toValue = 0.08
        currentFade.duration = duration
        currentFade.timingFunction = timing
        currentFade.fillMode = .forwards
        currentFade.isRemovedOnCompletion = false

        let destinationSlide = CABasicAnimation(keyPath: "transform.translation.x")
        destinationSlide.fromValue = 0
        destinationSlide.toValue = travel
        destinationSlide.duration = duration
        destinationSlide.timingFunction = timing
        destinationSlide.fillMode = .forwards
        destinationSlide.isRemovedOnCompletion = false

        let destinationColor = CABasicAnimation(keyPath: "backgroundColor")
        destinationColor.fromValue = NSColor.white.withAlphaComponent(0.14).cgColor
        destinationColor.toValue = NSColor(calibratedRed: 0.29, green: 0.48, blue: 1.0, alpha: 1).cgColor
        destinationColor.duration = duration
        destinationColor.timingFunction = timing
        destinationColor.fillMode = .forwards
        destinationColor.isRemovedOnCompletion = false

        current.add(currentSlide, forKey: "slide")
        current.add(currentFade, forKey: "fade")
        destination.add(destinationSlide, forKey: "slide")
        destination.add(destinationColor, forKey: "color")

        // A gesture-owned HUD stays visible after the tile animation until the
        // fingers lift (or two seconds pass). Menu/URL switches use the short
        // 0.25 s lifetime instead.
        if waitForGestureEnd {
            scheduleFinish(after: maxLifetime)
        } else {
            scheduleFinish(after: 0.18)
        }
    }

    /// Called when the physical swipe ends. The gesture-owned HUD can now fade.
    func gestureEnded() {
        guard isActive, waitingForGestureEnd else { return }
        waitingForGestureEnd = false
        scheduleFinish(after: 0.04)
    }

    private func scheduleFinish(after delay: TimeInterval) {
        finishWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, self.isActive else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.07
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                self?.finish()
            }
        }
        finishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makeCard(
        number: Int,
        frame: NSRect,
        highlight: Bool,
        scale: CGFloat
    ) -> CALayer {
        let card = CALayer()
        card.frame = frame
        card.cornerRadius = 7
        card.borderWidth = 1
        card.borderColor = NSColor.white.withAlphaComponent(highlight ? 0.34 : 0.16).cgColor
        card.backgroundColor = highlight
            ? NSColor(calibratedRed: 0.29, green: 0.48, blue: 1.0, alpha: 1).cgColor
            : NSColor.white.withAlphaComponent(0.14).cgColor
        card.masksToBounds = true

        let bar = CALayer()
        bar.frame = NSRect(x: 0, y: frame.height - 7, width: frame.width, height: 7)
        bar.backgroundColor = NSColor.white.withAlphaComponent(highlight ? 0.24 : 0.10).cgColor
        card.addSublayer(bar)

        let label = CATextLayer()
        label.string = "\(number)"
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.fontSize = 13
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.withAlphaComponent(highlight ? 1 : 0.78).cgColor
        label.contentsScale = scale
        label.frame = NSRect(x: 0, y: 3, width: frame.width, height: frame.height - 10)
        card.addSublayer(label)

        return card
    }

    /// Keep the destination number accurate when a long swipe crosses more
    /// than one Space while the HUD is still on screen.
    func updateDestination(_ number: Int, direction: Int) {
        guard isActive, direction == hudDirection else { return }
        destinationLabel?.string = "\(number)"
    }

    private func finish() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        destinationLabel = nil
        waitingForGestureEnd = false
        isActive = false
    }
}

extension NSScreen {
    static var underCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? main
    }
}
