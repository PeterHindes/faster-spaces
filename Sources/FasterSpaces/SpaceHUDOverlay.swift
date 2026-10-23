import AppKit
import QuartzCore

/// A compact, purely visual direction cue. Two rounded desktop tiles slide in
/// the direction of travel. Each additional Space crossed during one gesture
/// replays the tile motion, so a long swipe visibly steps through the Spaces.
/// The HUD is borderless and click-through and never touches the Dock.
final class SpaceHUDOverlay {
    static let shared = SpaceHUDOverlay()

    private var window: NSWindow?
    private var finishWorkItem: DispatchWorkItem?
    private var currentCard: CALayer?
    private var destinationCard: CALayer?
    private var currentLabel: CATextLayer?
    private var destinationLabel: CATextLayer?
    private var hudDirection = 0
    private var lastDestination = 0
    private var waitingForGestureEnd = false
    private(set) var isActive = false
    private let maxLifetime: TimeInterval = 2.0

    private let size = NSSize(width: 164, height: 58)
    private let cardSize = NSSize(width: 58, height: 34)
    private let gap: CGFloat = 16
    private let tileAnimationDuration: CFTimeInterval = 0.18

    private var accentColor: CGColor {
        NSColor(calibratedRed: 0.29, green: 0.48, blue: 1.0, alpha: 1).cgColor
    }

    private var inactiveColor: CGColor {
        NSColor.white.withAlphaComponent(0.14).cgColor
    }

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
        hudDirection = direction
        lastDestination = to
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
        root.addSublayer(current.card)
        root.addSublayer(destination.card)
        currentCard = current.card
        destinationCard = destination.card
        currentLabel = current.label
        destinationLabel = destination.label

        window.contentView = view
        window.orderFrontRegardless()
        window.displayIfNeeded()
        self.window = window

        animateTiles(direction: direction, duration: tileAnimationDuration)

        // A gesture-owned HUD stays visible after the tile animation until the
        // fingers lift (or two seconds pass without another step). Menu/URL
        // switches use the short 0.25 s lifetime instead.
        if waitForGestureEnd {
            scheduleFinish(after: maxLifetime)
        } else {
            scheduleFinish(after: 0.18)
        }
    }

    /// A long swipe crossed another Space. Replay the two-tile motion with the
    /// previous destination becoming the new origin tile.
    func advance(to number: Int, direction: Int) {
        guard isActive, number != lastDestination else { return }
        currentLabel?.string = "\(lastDestination)"
        destinationLabel?.string = "\(number)"
        lastDestination = number

        if direction != hudDirection {
            hudDirection = direction
            positionCards(direction: direction)
        }
        animateTiles(direction: direction, duration: tileAnimationDuration)

        // Keep the HUD alive through a genuinely long multi-Space gesture, but
        // still guarantee it disappears if no further events arrive.
        if waitingForGestureEnd {
            scheduleFinish(after: maxLifetime)
        }
    }

    /// Called when the physical swipe ends. The gesture-owned HUD can now fade.
    func gestureEnded() {
        guard isActive, waitingForGestureEnd else { return }
        waitingForGestureEnd = false
        scheduleFinish(after: 0.04)
    }

    private func positionCards(direction: Int) {
        guard let currentCard, let destinationCard else { return }
        let currentX = direction > 0 ? 16 : 16 + cardSize.width + gap
        let destinationX = direction > 0 ? 16 + cardSize.width + gap : 16
        currentCard.frame.origin.x = currentX
        destinationCard.frame.origin.x = destinationX
    }

    private func animateTiles(direction: Int, duration: CFTimeInterval) {
        guard let currentCard, let destinationCard,
              let currentLabel, let destinationLabel
        else {
            return
        }

        // Remove the previous fill-mode animations and restore the model state
        // before replaying. Otherwise a second step starts from the faded,
        // moved end state of the first.
        currentCard.removeAllAnimations()
        destinationCard.removeAllAnimations()
        currentCard.transform = CATransform3DIdentity
        destinationCard.transform = CATransform3DIdentity
        currentCard.opacity = 1
        currentCard.backgroundColor = accentColor
        currentCard.borderColor = NSColor.white.withAlphaComponent(0.34).cgColor
        destinationCard.backgroundColor = inactiveColor
        destinationCard.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        currentLabel.foregroundColor = NSColor.white.cgColor
        destinationLabel.foregroundColor = NSColor.white.withAlphaComponent(0.78).cgColor

        let travel = (cardSize.width + gap) * CGFloat(direction > 0 ? -1 : 1)
        let timing = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.3, 1.0)

        let currentSlide = CABasicAnimation(keyPath: "transform.translation.x")
        currentSlide.fromValue = 0
        currentSlide.toValue = travel

        let currentFade = CABasicAnimation(keyPath: "opacity")
        currentFade.fromValue = 1
        currentFade.toValue = 0.08

        let destinationSlide = CABasicAnimation(keyPath: "transform.translation.x")
        destinationSlide.fromValue = 0
        destinationSlide.toValue = travel

        let destinationColor = CABasicAnimation(keyPath: "backgroundColor")
        destinationColor.fromValue = inactiveColor
        destinationColor.toValue = accentColor

        for animation in [currentSlide, currentFade, destinationSlide, destinationColor] {
            animation.duration = duration
            animation.timingFunction = timing
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }

        currentCard.add(currentSlide, forKey: "slide")
        currentCard.add(currentFade, forKey: "fade")
        destinationCard.add(destinationSlide, forKey: "slide")
        destinationCard.add(destinationColor, forKey: "color")
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
    ) -> (card: CALayer, label: CATextLayer) {
        let card = CALayer()
        card.frame = frame
        card.cornerRadius = 7
        card.borderWidth = 1
        card.borderColor = NSColor.white.withAlphaComponent(highlight ? 0.34 : 0.16).cgColor
        card.backgroundColor = highlight ? accentColor : inactiveColor
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

        return (card, label)
    }

    private func finish() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        currentCard = nil
        destinationCard = nil
        currentLabel = nil
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
