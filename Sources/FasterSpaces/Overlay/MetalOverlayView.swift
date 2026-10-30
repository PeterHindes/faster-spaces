import AppKit
import Metal
import QuartzCore

/// Resident full-screen surface for the window switcher. The surface is
/// created once, ordered in at alpha 0, and revealed by flipping alpha. The
/// renderer draws only the switcher card, so the transparent rest of the
/// screen stays interactive (`ignoresMouseEvents`).
///
/// New Window Plz used `NSView.displayLink`; this app still targets macOS 13,
/// so the animation loop uses a 60 Hz main-run-loop timer. Selection changes
/// also render immediately, so the timer only drives the short slide.
final class MetalOverlayView: NSView {
    private let device: MTLDevice
    private let metalLayer = CAMetalLayer()
    private var renderTimer: Timer?
    private var didReportFirstFrame = false

    var renderer: OverlayRenderer?
    var scene: OverlayScene = .demo
    var sceneStartTime: CFTimeInterval = 0
    var onFirstFrame: (() -> Void)?

    init(frame frameRect: NSRect, device: MTLDevice) {
        self.device = device
        super.init(frame: frameRect)
        wantsLayer = true
        layer = metalLayer
        layerContentsRedrawPolicy = .never

        metalLayer.device = device
        metalLayer.pixelFormat = OverlayRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.presentsWithTransaction = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        renderTimer?.invalidate()
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            updateDrawableSize()
        }
    }

    func updateDrawableSize() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded())
        )
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    func resumeAnimating() {
        updateDrawableSize()
        if renderTimer != nil { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.renderFrame(at: CACurrentMediaTime())
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
        didReportFirstFrame = false
        renderFrame(at: CACurrentMediaTime())
    }

    func pauseAnimating() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    func stopAnimating() {
        pauseAnimating()
        didReportFirstFrame = false
    }

    func renderImmediately() {
        renderFrame(at: CACurrentMediaTime())
    }

    private func renderFrame(at time: CFTimeInterval) {
        guard let renderer,
              window?.isVisible == true,
              bounds.width > 1, bounds.height > 1 else {
            return
        }
        updateDrawableSize()

        guard let drawable = metalLayer.nextDrawable() else {
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        renderer.render(
            drawable: drawable,
            scene: scene,
            pointSize: bounds.size,
            scale: scale,
            time: time,
            sceneStart: sceneStartTime
        )

        if !didReportFirstFrame {
            didReportFirstFrame = true
            let callback = onFirstFrame
            onFirstFrame = nil
            DispatchQueue.main.async {
                callback?()
            }
        }
    }
}
