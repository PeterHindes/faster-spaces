import AppKit
import CoreText
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

enum OverlayRendererError: LocalizedError {
    case commandQueue
    case noShaderSource
    case shaderCompilation(String)
    case missingFunction(String)
    case pipeline(String)
    case texture
    case previewEncoding

    var errorDescription: String? {
        switch self {
        case .commandQueue:
            return "Could not create a Metal command queue."
        case .noShaderSource:
            return "The Metal shader source is missing from the app bundle."
        case .shaderCompilation(let message):
            return "Could not compile the Metal shaders: \(message)"
        case .missingFunction(let name):
            return "Metal shader function “\(name)” is missing."
        case .pipeline(let message):
            return "Could not create a Metal pipeline: \(message)"
        case .texture:
            return "Could not create a Metal texture."
        case .previewEncoding:
            return "Could not encode the overlay preview."
        }
    }
}

enum OverlayScene {
    case demo
    case appSwitcher(AltTabScene)
}

private struct BackgroundUniforms {
    var resolution: SIMD2<Float>
    var cardCenter: SIMD2<Float>
    var cardHalfSize: SIMD2<Float>
    var time: Float
    var intro: Float
}

private struct TextUniforms {
    var resolution: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct IconUniforms {
    var resolution: SIMD2<Float>
    var tint: SIMD4<Float>
    var shape: SIMD4<Float>
}

private struct QuadVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct TextTexture {
    let texture: MTLTexture
    let pointSize: CGSize
}

private struct TextQuad {
    let texture: MTLTexture
    let origin: CGPoint
    let size: CGSize
    let alpha: Float
}

private struct SnapshotTexture {
    let texture: MTLTexture
    let pixelSize: CGSize
}

final class OverlayRenderer {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm
    static let textureScale: CGFloat = 3.0

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let rendererDescription: String

    private let backgroundPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let iconPipeline: MTLRenderPipelineState

    private let eyebrow: TextTexture
    private let title: TextTexture
    private let subtitle: TextTexture
    private let footer: TextTexture
    private let switcherHeader: TextTexture
    private let switcherHint: TextTexture

    private let whiteTexture: MTLTexture
    private let placeholderIcon: MTLTexture
    private var appIconCache: [String: MTLTexture] = [:]
    private var windowLabelCache: [String: TextTexture] = [:]
    private var snapshotCache: [CGWindowID: SnapshotTexture] = [:]

    init(device: MTLDevice) throws {
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw OverlayRendererError.commandQueue
        }
        queue.label = "NewWindowPlz Overlay Queue"
        commandQueue = queue

        guard let shaderURL = Bundle.main.url(forResource: "OverlayShaders", withExtension: "metal.txt"),
              let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            throw OverlayRendererError.noShaderSource
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw OverlayRendererError.shaderCompilation(error.localizedDescription)
        }

        func function(_ name: String) throws -> MTLFunction {
            guard let function = library.makeFunction(name: name) else {
                throw OverlayRendererError.missingFunction(name)
            }
            return function
        }

        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.label = "Overlay Background"
        backgroundDescriptor.vertexFunction = try function("overlay_background_vertex")
        backgroundDescriptor.fragmentFunction = try function("overlay_background_fragment")
        let backgroundAttachment = backgroundDescriptor.colorAttachments[0]!
        backgroundAttachment.pixelFormat = Self.pixelFormat
        backgroundAttachment.isBlendingEnabled = true
        backgroundAttachment.sourceRGBBlendFactor = .sourceAlpha
        backgroundAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        backgroundAttachment.sourceAlphaBlendFactor = .one
        backgroundAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            backgroundPipeline = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
        } catch {
            throw OverlayRendererError.pipeline(error.localizedDescription)
        }

        let textDescriptor = MTLRenderPipelineDescriptor()
        textDescriptor.label = "Overlay Text"
        textDescriptor.vertexFunction = try function("overlay_text_vertex")
        textDescriptor.fragmentFunction = try function("overlay_text_fragment")
        let textAttachment = textDescriptor.colorAttachments[0]!
        textAttachment.pixelFormat = Self.pixelFormat
        textAttachment.isBlendingEnabled = true
        textAttachment.sourceRGBBlendFactor = .one
        textAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        textAttachment.sourceAlphaBlendFactor = .one
        textAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            textPipeline = try device.makeRenderPipelineState(descriptor: textDescriptor)
        } catch {
            throw OverlayRendererError.pipeline(error.localizedDescription)
        }

        let iconDescriptor = MTLRenderPipelineDescriptor()
        iconDescriptor.label = "Overlay App Icon"
        iconDescriptor.vertexFunction = try function("overlay_icon_vertex")
        iconDescriptor.fragmentFunction = try function("overlay_icon_fragment")
        let iconAttachment = iconDescriptor.colorAttachments[0]!
        iconAttachment.pixelFormat = Self.pixelFormat
        iconAttachment.isBlendingEnabled = true
        iconAttachment.sourceRGBBlendFactor = .one
        iconAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        iconAttachment.sourceAlphaBlendFactor = .one
        iconAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            iconPipeline = try device.makeRenderPipelineState(descriptor: iconDescriptor)
        } catch {
            throw OverlayRendererError.pipeline(error.localizedDescription)
        }

        eyebrow = try Self.makeTextTexture(
            device: device,
            text: "NEW WINDOW PLZ",
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: NSColor(white: 1.0, alpha: 0.42),
            tracking: 3.2
        )
        title = try Self.makeTextTexture(
            device: device,
            text: "Overlay pipeline ready",
            font: .systemFont(ofSize: 38, weight: .semibold),
            color: NSColor(white: 1.0, alpha: 0.96),
            tracking: -0.4
        )
        subtitle = try Self.makeTextTexture(
            device: device,
            text: "Prewarmed Metal  ·  no window creation  ·  non-blocking submit",
            font: .systemFont(ofSize: 13.5, weight: .regular),
            color: NSColor(white: 1.0, alpha: 0.60),
            tracking: 0.1
        )
        footer = try Self.makeTextTexture(
            device: device,
            text: "ONE PERSISTENT SURFACE   ·   ZERO WINDOW CREATION",
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: NSColor(white: 1.0, alpha: 0.38),
            tracking: 2.1
        )
        switcherHeader = try Self.makeTextTexture(
            device: device,
            text: "SWITCH WINDOW",
            font: .systemFont(ofSize: 10.5, weight: .semibold),
            color: NSColor(white: 1.0, alpha: 0.44),
            tracking: 3.1
        )
        switcherHint = try Self.makeTextTexture(
            device: device,
            text: "TAB  CYCLE   ·   ⇧TAB  BACK   ·   RELEASE ⌥  SWITCH   ·   ESC  CANCEL",
            font: .systemFont(ofSize: 10.5, weight: .medium),
            color: NSColor(white: 1.0, alpha: 0.40),
            tracking: 0.7
        )
        whiteTexture = try Self.makeSolidTexture(device: device, red: 255, green: 255, blue: 255, alpha: 255)
        placeholderIcon = try Self.makePlaceholderIcon(device: device)

        rendererDescription = "\(device.name) · Metal · resident switcher surface"
    }

    /// Called when the current-Space window set changes, not on the reveal
    /// path. App icons are cached per bundle; window labels are cached by the
    /// visible title string.
    func prepareWindowSwitcherCache(for windows: [AltTabWindow]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prepareWindowSwitcherCache(for: windows)
            }
            return
        }

        let desiredApps = Set(windows.map(\.appCacheKey))
        let desiredLabels = Set(windows.map(\.shortTitle))
        let desiredWindows = Set(windows.map(\.windowID))

        appIconCache = appIconCache.filter { desiredApps.contains($0.key) }
        windowLabelCache = windowLabelCache.filter { desiredLabels.contains($0.key) }
        snapshotCache = snapshotCache.filter { desiredWindows.contains($0.key) }

        for window in windows {
            if appIconCache[window.appCacheKey] == nil {
                let running = NSRunningApplication(processIdentifier: window.pid)
                let iconImage = running?.icon ??
                    running?.bundleURL.flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
                appIconCache[window.appCacheKey] =
                    (try? Self.makeIconTexture(device: device, image: iconImage)) ?? placeholderIcon
            }

            if windowLabelCache[window.shortTitle] == nil {
                windowLabelCache[window.shortTitle] = try? Self.makeTextTexture(
                    device: device,
                    text: window.shortTitle,
                    font: .systemFont(ofSize: 11.5, weight: .medium),
                    color: NSColor(white: 1.0, alpha: 0.92),
                    tracking: 0.1
                )
            }
        }
    }

    func cacheWindowSnapshot(windowID: CGWindowID, image: CGImage) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.cacheWindowSnapshot(windowID: windowID, image: image)
            }
            return
        }
        guard let snapshot = try? Self.makeSnapshotTexture(device: device, image: image) else {
            return
        }
        snapshotCache[windowID] = snapshot
    }

    func render(drawable: CAMetalDrawable,
                scene: OverlayScene,
                pointSize: CGSize,
                scale: CGFloat,
                time: CFTimeInterval,
                sceneStart: CFTimeInterval) {
        guard pointSize.width > 1, pointSize.height > 1,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        commandBuffer.label = "Overlay Frame"
        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = drawable.texture
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.storeAction = .store

        encodeScene(
            into: commandBuffer,
            passDescriptor: passDescriptor,
            drawableSize: CGSize(width: drawable.texture.width, height: drawable.texture.height),
            pointSize: pointSize,
            scale: scale,
            time: time,
            sceneStart: sceneStart,
            scene: scene
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func writePreview(to url: URL,
                      pointSize: CGSize,
                      scale: CGFloat,
                      scene: OverlayScene = .demo) throws {
        let width = max(1, Int((pointSize.width * scale).rounded()))
        let height = max(1, Int((pointSize.height * scale).rounded()))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw OverlayRendererError.texture
        }

        let passDescriptor = MTLRenderPassDescriptor()
        let attachment = passDescriptor.colorAttachments[0]!
        attachment.texture = texture
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.storeAction = .store

        encodeScene(
            into: commandBuffer,
            passDescriptor: passDescriptor,
            drawableSize: CGSize(width: width, height: height),
            pointSize: pointSize,
            scale: scale,
            time: 1.35,
            sceneStart: 0,
            scene: scene
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(
            &bgra,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        var rgba = bgra
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let blue = bgra[index]
            rgba[index] = bgra[index + 2]
            rgba[index + 1] = bgra[index + 1]
            rgba[index + 2] = blue
            rgba[index + 3] = 255
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw OverlayRendererError.previewEncoding
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OverlayRendererError.previewEncoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OverlayRendererError.previewEncoding
        }
        try (data as Data).write(to: url)
    }

    private func encodeScene(into commandBuffer: MTLCommandBuffer,
                             passDescriptor: MTLRenderPassDescriptor,
                             drawableSize: CGSize,
                             pointSize: CGSize,
                             scale: CGFloat,
                             time: CFTimeInterval,
                             sceneStart: CFTimeInterval,
                             scene: OverlayScene) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.label = "Overlay Scene"

        switch scene {
        case .demo:
            let intro = Float(min(max((time - sceneStart) / 0.16, 0), 1))
            encodeDemoContents(
                encoder: encoder,
                drawableSize: drawableSize,
                pointSize: pointSize,
                scale: scale,
                time: time,
                intro: intro
            )
        case .appSwitcher(let switcher):
            encodeSwitcherContents(
                encoder: encoder,
                drawableSize: drawableSize,
                pointSize: pointSize,
                scale: scale,
                time: time,
                switcher: switcher
            )
        }

        encoder.endEncoding()
    }

    private func encodeDemoContents(encoder: MTLRenderCommandEncoder,
                                    drawableSize: CGSize,
                                    pointSize: CGSize,
                                    scale: CGFloat,
                                    time: CFTimeInterval,
                                    intro: Float) {
        let cardWidth = min(pointSize.width * 0.72, 760)
        let cardHeight = min(pointSize.height * 0.44, 340)
        let cardRect = CGRect(
            x: (pointSize.width - cardWidth) * 0.5,
            y: (pointSize.height - cardHeight) * 0.5,
            width: cardWidth,
            height: cardHeight
        )
        encodeBackground(
            encoder: encoder,
            cardRect: cardRect,
            drawableSize: drawableSize,
            scale: scale,
            time: time,
            intro: intro
        )

        let quads = demoTextQuads(cardRect: cardRect, intro: intro)
        encoder.setRenderPipelineState(textPipeline)
        for quad in quads {
            let origin = CGPoint(
                x: quad.origin.x,
                y: quad.origin.y + CGFloat((1 - intro) * 7)
            )
            drawTextQuad(
                encoder: encoder,
                texture: quad.texture,
                origin: origin,
                size: quad.size,
                alpha: quad.alpha,
                resolution: pointSize
            )
        }
    }

    private func encodeSwitcherContents(encoder: MTLRenderCommandEncoder,
                                        drawableSize: CGSize,
                                        pointSize: CGSize,
                                        scale: CGFloat,
                                        time: CFTimeInterval,
                                        switcher: AltTabScene) {
        if switcher.showSnapshots {
            encodeSnapshotSwitcher(
                encoder: encoder,
                drawableSize: drawableSize,
                pointSize: pointSize,
                scale: scale,
                time: time,
                switcher: switcher
            )
        } else {
            encodeIconSwitcher(
                encoder: encoder,
                drawableSize: drawableSize,
                pointSize: pointSize,
                scale: scale,
                time: time,
                switcher: switcher
            )
        }
    }

    private func encodeIconSwitcher(encoder: MTLRenderCommandEncoder,
                                    drawableSize: CGSize,
                                    pointSize: CGSize,
                                    scale: CGFloat,
                                    time: CFTimeInterval,
                                    switcher: AltTabScene) {
        let visible = AltTabSelection.visibleRange(
            count: switcher.windows.count,
            selectedIndex: switcher.selectedIndex,
            maxVisible: AltTabLayout.iconVisibleLimit
        )
        guard !visible.isEmpty else { return }

        let slotWidth: CGFloat = 112
        let visibleCount = visible.count
        let cardWidth = min(
            pointSize.width * 0.84,
            max(600, CGFloat(visibleCount) * slotWidth + 140)
        )
        let cardHeight = min(pointSize.height * 0.46, 320)
        let cardRect = CGRect(
            x: (pointSize.width - cardWidth) * 0.5,
            y: (pointSize.height - cardHeight) * 0.5,
            width: cardWidth,
            height: cardHeight
        )

        encodeBackground(
            encoder: encoder,
            cardRect: cardRect,
            drawableSize: drawableSize,
            scale: scale,
            time: time,
            intro: 1.0
        )

        let iconSize: CGFloat = 84
        let iconTop = cardRect.minY + 74
        let rowWidth = CGFloat(visibleCount) * slotWidth
        let firstCenter = cardRect.midX - rowWidth * 0.5 + slotWidth * 0.5

        encoder.setRenderPipelineState(iconPipeline)

        if switcher.windows.indices.contains(switcher.selectedIndex) {
            let selectedSlot = switcher.selectedIndex - visible.lowerBound
            if selectedSlot >= 0, selectedSlot < visibleCount {
                let centerX = firstCenter + CGFloat(selectedSlot) * slotWidth
                drawIconQuad(
                    encoder: encoder,
                    texture: whiteTexture,
                    origin: CGPoint(x: centerX - 58, y: iconTop - 16),
                    size: CGSize(width: 116, height: 116),
                    tint: SIMD4<Float>(0.10, 0.45, 0.85, 0.10),
                    brightness: 1.0,
                    cornerRadius: 36,
                    resolution: pointSize
                )
                drawIconQuad(
                    encoder: encoder,
                    texture: whiteTexture,
                    origin: CGPoint(x: centerX - 52, y: iconTop - 10),
                    size: CGSize(width: 104, height: 104),
                    tint: SIMD4<Float>(0.15, 0.52, 0.95, 0.24),
                    brightness: 1.0,
                    cornerRadius: 30,
                    resolution: pointSize
                )
            }
        }

        for (offset, windowIndex) in visible.enumerated() {
            let window = switcher.windows[windowIndex]
            let centerX = firstCenter + CGFloat(offset) * slotWidth
            let selected = windowIndex == switcher.selectedIndex

            drawIconQuad(
                encoder: encoder,
                texture: appIconCache[window.appCacheKey] ?? placeholderIcon,
                origin: CGPoint(x: centerX - iconSize * 0.5, y: iconTop),
                size: CGSize(width: iconSize, height: iconSize),
                tint: SIMD4<Float>(1, 1, 1, 1),
                brightness: selected ? 1.0 : 0.52,
                cornerRadius: 20,
                resolution: pointSize
            )
        }

        encoder.setRenderPipelineState(textPipeline)
        drawCenteredText(
            encoder: encoder,
            text: switcherHeader,
            centerX: cardRect.midX,
            top: cardRect.minY + 28,
            alpha: 0.9,
            resolution: pointSize
        )
        drawCenteredText(
            encoder: encoder,
            text: switcherHint,
            centerX: cardRect.midX,
            top: cardRect.maxY - 33,
            alpha: 0.9,
            resolution: pointSize
        )

        for (offset, windowIndex) in visible.enumerated() {
            let window = switcher.windows[windowIndex]
            guard let label = windowLabelCache[window.shortTitle] else { continue }
            let centerX = firstCenter + CGFloat(offset) * slotWidth
            let selected = windowIndex == switcher.selectedIndex
            let maxWidth: CGFloat = 100
            let fitScale = min(1, maxWidth / max(1, label.pointSize.width))
            drawTextQuad(
                encoder: encoder,
                texture: label.texture,
                origin: CGPoint(
                    x: centerX - label.pointSize.width * fitScale * 0.5,
                    y: iconTop + 96
                ),
                size: CGSize(
                    width: label.pointSize.width * fitScale,
                    height: label.pointSize.height * fitScale
                ),
                alpha: selected ? 1.0 : 0.46,
                resolution: pointSize
            )
        }
    }

    private func encodeSnapshotSwitcher(encoder: MTLRenderCommandEncoder,
                                        drawableSize: CGSize,
                                        pointSize: CGSize,
                                        scale: CGFloat,
                                        time: CFTimeInterval,
                                        switcher: AltTabScene) {
        let maxVisible = AltTabLayout.snapshotVisibleLimit
        let currentRange = AltTabSelection.visibleRange(
            count: switcher.windows.count,
            selectedIndex: switcher.selectedIndex,
            maxVisible: maxVisible
        )
        guard !currentRange.isEmpty else { return }

        var drawRange = currentRange
        var slideOffset: CGFloat = 0
        if let previousSelected = switcher.previousSelectedIndex,
           let transitionStart = switcher.selectionTransitionStart {
            let previousRange = AltTabSelection.visibleRange(
                count: switcher.windows.count,
                selectedIndex: previousSelected,
                maxVisible: maxVisible
            )
            let delta = currentRange.lowerBound - previousRange.lowerBound
            if abs(delta) == 1 {
                let progress = min(max((time - transitionStart) / 0.26, 0), 1)
                let eased = 1 - pow(1 - progress, 3)
                let slotStep = cardStep(pointSize: pointSize)
                slideOffset = CGFloat(delta) * slotStep * CGFloat(1 - eased)
                if progress < 1 {
                    drawRange = Range(
                        uncheckedBounds: (
                            lower: min(previousRange.lowerBound, currentRange.lowerBound),
                            upper: max(previousRange.upperBound, currentRange.upperBound)
                        )
                    )
                }
            }
        }

        let layout = snapshotLayout(pointSize: pointSize, visibleCount: currentRange.count)
        let panelRect = layout.panelRect
        let rowTop = panelRect.minY + 58
        let firstCenter = panelRect.midX - layout.rowWidth * 0.5 + layout.cardWidth * 0.5

        encodeBackground(
            encoder: encoder,
            cardRect: panelRect,
            drawableSize: drawableSize,
            scale: scale,
            time: time,
            intro: 1.0
        )

        encoder.setScissorRect(clipRect(
            for: CGRect(
                x: panelRect.minX + 14,
                y: rowTop - 14,
                width: panelRect.width - 28,
                height: layout.cardHeight + 28
            ),
            scale: scale,
            drawableSize: drawableSize
        ))

        encoder.setRenderPipelineState(iconPipeline)

        let selectedIndex = switcher.selectedIndex
        if drawRange.contains(selectedIndex) {
            let origin = cardOrigin(
                for: selectedIndex,
                currentRange: currentRange,
                firstCenter: firstCenter,
                layout: layout,
                rowTop: rowTop,
                slideOffset: slideOffset
            )
            drawIconQuad(
                encoder: encoder,
                texture: whiteTexture,
                origin: CGPoint(x: origin.x - 10, y: origin.y - 10),
                size: CGSize(width: layout.cardWidth + 20, height: layout.cardHeight + 20),
                tint: SIMD4<Float>(0.11, 0.46, 0.86, 0.12),
                brightness: 1.0,
                cornerRadius: layout.cardCornerRadius + 10,
                resolution: pointSize
            )
            drawIconQuad(
                encoder: encoder,
                texture: whiteTexture,
                origin: CGPoint(x: origin.x - 2.5, y: origin.y - 2.5),
                size: CGSize(width: layout.cardWidth + 5, height: layout.cardHeight + 5),
                tint: SIMD4<Float>(0.20, 0.58, 1.0, 0.92),
                brightness: 1.0,
                cornerRadius: layout.cardCornerRadius + 2.5,
                resolution: pointSize
            )
        }

        for windowIndex in drawRange {
            guard switcher.windows.indices.contains(windowIndex) else { continue }
            let window = switcher.windows[windowIndex]
            let selected = windowIndex == selectedIndex
            let origin = cardOrigin(
                for: windowIndex,
                currentRange: currentRange,
                firstCenter: firstCenter,
                layout: layout,
                rowTop: rowTop,
                slideOffset: slideOffset
            )

            drawIconQuad(
                encoder: encoder,
                texture: whiteTexture,
                origin: origin,
                size: CGSize(width: layout.cardWidth, height: layout.cardHeight),
                tint: SIMD4<Float>(0.030, 0.039, 0.062, 0.97),
                brightness: 1.0,
                cornerRadius: layout.cardCornerRadius,
                resolution: pointSize
            )

            let thumbnailRect = CGRect(
                x: origin.x + 8,
                y: origin.y + 8,
                width: layout.cardWidth - 16,
                height: layout.cardHeight - 58
            )
            drawIconQuad(
                encoder: encoder,
                texture: whiteTexture,
                origin: thumbnailRect.origin,
                size: thumbnailRect.size,
                tint: SIMD4<Float>(0.012, 0.016, 0.026, 0.98),
                brightness: 1.0,
                cornerRadius: 14,
                resolution: pointSize
            )

            if let snapshot = snapshotCache[window.windowID] {
                let fitScale = min(
                    thumbnailRect.width / max(1, snapshot.pixelSize.width),
                    thumbnailRect.height / max(1, snapshot.pixelSize.height)
                )
                let displaySize = CGSize(
                    width: snapshot.pixelSize.width * fitScale,
                    height: snapshot.pixelSize.height * fitScale
                )
                drawIconQuad(
                    encoder: encoder,
                    texture: snapshot.texture,
                    origin: CGPoint(
                        x: thumbnailRect.midX - displaySize.width * 0.5,
                        y: thumbnailRect.midY - displaySize.height * 0.5
                    ),
                    size: displaySize,
                    tint: SIMD4<Float>(1, 1, 1, 1),
                    brightness: selected ? 1.0 : 0.84,
                    cornerRadius: 10,
                    resolution: pointSize
                )
            } else {
                let placeholderSize: CGFloat = min(44, thumbnailRect.height * 0.42)
                drawIconQuad(
                    encoder: encoder,
                    texture: appIconCache[window.appCacheKey] ?? placeholderIcon,
                    origin: CGPoint(
                        x: thumbnailRect.midX - placeholderSize * 0.5,
                        y: thumbnailRect.midY - placeholderSize * 0.5
                    ),
                    size: CGSize(width: placeholderSize, height: placeholderSize),
                    tint: SIMD4<Float>(1, 1, 1, 1),
                    brightness: 0.62,
                    cornerRadius: placeholderSize * 0.23,
                    resolution: pointSize
                )
            }

            drawIconQuad(
                encoder: encoder,
                texture: appIconCache[window.appCacheKey] ?? placeholderIcon,
                origin: CGPoint(x: origin.x + 12, y: origin.y + layout.cardHeight - 42),
                size: CGSize(width: 22, height: 22),
                tint: SIMD4<Float>(1, 1, 1, 1),
                brightness: selected ? 1.0 : 0.72,
                cornerRadius: 6,
                resolution: pointSize
            )
        }

        encoder.setRenderPipelineState(textPipeline)

        for windowIndex in drawRange {
            guard switcher.windows.indices.contains(windowIndex) else { continue }
            let window = switcher.windows[windowIndex]
            guard let label = windowLabelCache[window.shortTitle] else { continue }
            let selected = windowIndex == selectedIndex
            let origin = cardOrigin(
                for: windowIndex,
                currentRange: currentRange,
                firstCenter: firstCenter,
                layout: layout,
                rowTop: rowTop,
                slideOffset: slideOffset
            )
            let maxWidth = layout.cardWidth - 52
            let fitScale = min(1, maxWidth / max(1, label.pointSize.width))
            drawTextQuad(
                encoder: encoder,
                texture: label.texture,
                origin: CGPoint(
                    x: origin.x + 40,
                    y: origin.y + layout.cardHeight - 40
                ),
                size: CGSize(
                    width: label.pointSize.width * fitScale,
                    height: label.pointSize.height * fitScale
                ),
                alpha: selected ? 1.0 : 0.62,
                resolution: pointSize
            )
        }

        encoder.setScissorRect(MTLScissorRect(
            x: 0,
            y: 0,
            width: max(1, Int(drawableSize.width)),
            height: max(1, Int(drawableSize.height))
        ))

        drawCenteredText(
            encoder: encoder,
            text: switcherHeader,
            centerX: panelRect.midX,
            top: panelRect.minY + 26,
            alpha: 0.9,
            resolution: pointSize
        )
        drawCenteredText(
            encoder: encoder,
            text: switcherHint,
            centerX: panelRect.midX,
            top: panelRect.maxY - 30,
            alpha: 0.9,
            resolution: pointSize
        )
    }

    private struct SnapshotLayout {
        let panelRect: CGRect
        let rowWidth: CGFloat
        let cardWidth: CGFloat
        let cardHeight: CGFloat
        let cardCornerRadius: CGFloat
    }

    private func snapshotLayout(pointSize: CGSize, visibleCount: Int) -> SnapshotLayout {
        let horizontalPadding: CGFloat = 34
        let gap: CGFloat = 18
        let count = max(1, visibleCount)
        let maxCardWidth: CGFloat = 300
        let idealPanelWidth = min(pointSize.width * 0.94, 1480)
        let cappedRowWidth = CGFloat(count) * maxCardWidth + CGFloat(count - 1) * gap
        let panelWidth = min(idealPanelWidth, cappedRowWidth + horizontalPadding * 2)
        let cardWidth = (panelWidth - horizontalPadding * 2 - gap * CGFloat(count - 1)) / CGFloat(count)
        let cardHeight = min(cardWidth * 0.82, 240)
        let panelHeight = 58 + cardHeight + 66
        let panelRect = CGRect(
            x: (pointSize.width - panelWidth) * 0.5,
            y: (pointSize.height - panelHeight) * 0.5,
            width: panelWidth,
            height: panelHeight
        )
        let rowWidth = CGFloat(count) * cardWidth + CGFloat(count - 1) * gap
        return SnapshotLayout(
            panelRect: panelRect,
            rowWidth: rowWidth,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            cardCornerRadius: 22
        )
    }

    private func cardStep(pointSize: CGSize) -> CGFloat {
        let layout = snapshotLayout(
            pointSize: pointSize,
            visibleCount: AltTabLayout.snapshotVisibleLimit
        )
        return layout.cardWidth + 18
    }

    private func cardOrigin(for windowIndex: Int,
                            currentRange: Range<Int>,
                            firstCenter: CGFloat,
                            layout: SnapshotLayout,
                            rowTop: CGFloat,
                            slideOffset: CGFloat) -> CGPoint {
        let step = layout.cardWidth + 18
        let centerX = firstCenter +
            CGFloat(windowIndex - currentRange.lowerBound) * step +
            slideOffset
        return CGPoint(
            x: centerX - layout.cardWidth * 0.5,
            y: rowTop
        )
    }

    private func clipRect(for rect: CGRect, scale: CGFloat, drawableSize: CGSize) -> MTLScissorRect {
        let x = max(0, Int((rect.minX * scale).rounded(.down)))
        let y = max(0, Int((rect.minY * scale).rounded(.down)))
        let width = max(1, Int((rect.width * scale).rounded(.up)))
        let height = max(1, Int((rect.height * scale).rounded(.up)))
        let maxWidth = max(1, Int(drawableSize.width)) - x
        let maxHeight = max(1, Int(drawableSize.height)) - y
        return MTLScissorRect(
            x: x,
            y: y,
            width: min(width, maxWidth),
            height: min(height, maxHeight)
        )
    }

    private func encodeBackground(encoder: MTLRenderCommandEncoder,
                                  cardRect: CGRect,
                                  drawableSize: CGSize,
                                  scale: CGFloat,
                                  time: CFTimeInterval,
                                  intro: Float) {
        var background = BackgroundUniforms(
            resolution: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            cardCenter: SIMD2(
                Float(cardRect.midX * scale),
                Float(cardRect.midY * scale)
            ),
            cardHalfSize: SIMD2(
                Float(cardRect.width * 0.5 * scale),
                Float(cardRect.height * 0.5 * scale)
            ),
            time: Float(time),
            intro: intro
        )
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setFragmentBytes(
            &background,
            length: MemoryLayout<BackgroundUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func drawIconQuad(encoder: MTLRenderCommandEncoder,
                              texture: MTLTexture,
                              origin: CGPoint,
                              size: CGSize,
                              tint: SIMD4<Float>,
                              brightness: Float,
                              cornerRadius: CGFloat,
                              resolution: CGSize) {
        var vertices = quadVertices(origin: origin, size: size)
        let halfHeight = max(1, size.height * 0.5)
        let normalizedRadius = Float(min(cornerRadius, halfHeight) / halfHeight)
        let aspect = Float(size.width / max(1, size.height))
        var uniforms = IconUniforms(
            resolution: SIMD2(Float(resolution.width), Float(resolution.height)),
            tint: tint,
            shape: SIMD4(brightness, normalizedRadius, aspect, 0)
        )
        encoder.setVertexBytes(
            &vertices,
            length: MemoryLayout<QuadVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<IconUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<IconUniforms>.stride,
            index: 1
        )
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawCenteredText(encoder: MTLRenderCommandEncoder,
                                  text: TextTexture,
                                  centerX: CGFloat,
                                  top: CGFloat,
                                  alpha: Float,
                                  resolution: CGSize) {
        drawTextQuad(
            encoder: encoder,
            texture: text.texture,
            origin: CGPoint(x: centerX - text.pointSize.width * 0.5, y: top),
            size: text.pointSize,
            alpha: alpha,
            resolution: resolution
        )
    }

    private func drawTextQuad(encoder: MTLRenderCommandEncoder,
                              texture: MTLTexture,
                              origin: CGPoint,
                              size: CGSize,
                              alpha: Float,
                              resolution: CGSize) {
        var vertices = quadVertices(origin: origin, size: size)
        var uniforms = TextUniforms(
            resolution: SIMD2(Float(resolution.width), Float(resolution.height)),
            color: SIMD4(1, 1, 1, alpha)
        )
        encoder.setVertexBytes(
            &vertices,
            length: MemoryLayout<QuadVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<TextUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<TextUniforms>.stride,
            index: 1
        )
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func quadVertices(origin: CGPoint, size: CGSize) -> [QuadVertex] {
        let maxX = origin.x + size.width
        let maxY = origin.y + size.height
        return [
            QuadVertex(position: SIMD2(Float(origin.x), Float(origin.y)), texCoord: SIMD2(0, 0)),
            QuadVertex(position: SIMD2(Float(maxX), Float(origin.y)), texCoord: SIMD2(1, 0)),
            QuadVertex(position: SIMD2(Float(origin.x), Float(maxY)), texCoord: SIMD2(0, 1)),
            QuadVertex(position: SIMD2(Float(maxX), Float(origin.y)), texCoord: SIMD2(1, 0)),
            QuadVertex(position: SIMD2(Float(maxX), Float(maxY)), texCoord: SIMD2(1, 1)),
            QuadVertex(position: SIMD2(Float(origin.x), Float(maxY)), texCoord: SIMD2(0, 1))
        ]
    }

    private func demoTextQuads(cardRect: CGRect, intro: Float) -> [TextQuad] {
        let centerX = cardRect.midX
        let alpha = 0.25 + 0.75 * intro
        var quads: [TextQuad] = []

        func add(_ texture: TextTexture, top: CGFloat, baseAlpha: Float) {
            let origin = CGPoint(
                x: centerX - texture.pointSize.width * 0.5,
                y: top
            )
            quads.append(TextQuad(
                texture: texture.texture,
                origin: origin,
                size: texture.pointSize,
                alpha: baseAlpha * alpha
            ))
        }

        add(eyebrow, top: cardRect.minY + 39, baseAlpha: 1.0)
        add(title, top: cardRect.minY + 70, baseAlpha: 1.0)
        add(subtitle, top: cardRect.minY + 127, baseAlpha: 1.0)
        add(footer, top: cardRect.maxY - 48, baseAlpha: 1.0)
        return quads
    }

    private static func makeTextTexture(device: MTLDevice,
                                        text: String,
                                        font: NSFont,
                                        color: NSColor,
                                        tracking: CGFloat) throws -> TextTexture {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): tracking
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let padding: CGFloat = 4
        let pointWidth = ceil(lineWidth) + padding * 2
        let pointHeight = ceil(ascent + descent + leading) + padding * 2
        let width = max(1, Int(ceil(pointWidth * textureScale)))
        let height = max(1, Int(ceil(pointHeight * textureScale)))
        let bytesPerRow = width * 4

        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return
            }

            context.scaleBy(x: textureScale, y: textureScale)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(true)
            context.setShouldSmoothFonts(false)
            context.textPosition = CGPoint(x: padding, y: padding + descent)
            CTLineDraw(line, context)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OverlayRendererError.texture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )

        return TextTexture(
            texture: texture,
            pointSize: CGSize(width: pointWidth, height: pointHeight)
        )
    }

    private static func makeIconTexture(device: MTLDevice, image: NSImage?) throws -> MTLTexture {
        let dimension = 256
        let bytesPerRow = dimension * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * dimension)

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: dimension,
                    height: dimension,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return
            }

            context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
            context.interpolationQuality = .high
            guard let image else { return }
            var proposedRect = NSRect(x: 0, y: 0, width: dimension, height: dimension)
            guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                return
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OverlayRendererError.texture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimension, dimension),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    private static func makeSnapshotTexture(device: MTLDevice, image: CGImage) throws -> SnapshotTexture {
        let width = max(1, image.width)
        let height = max(1, image.height)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OverlayRendererError.texture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        return SnapshotTexture(
            texture: texture,
            pixelSize: CGSize(width: width, height: height)
        )
    }

    private static func makePlaceholderIcon(device: MTLDevice) throws -> MTLTexture {
        let dimension = 256
        let bytesPerRow = dimension * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * dimension)

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: dimension,
                    height: dimension,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return
            }

            context.setFillColor(CGColor(red: 0.12, green: 0.14, blue: 0.20, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
            context.fillEllipse(in: CGRect(x: 72, y: 72, width: 112, height: 112))
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OverlayRendererError.texture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimension, dimension),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    private static func makeSolidTexture(device: MTLDevice,
                                         red: UInt8,
                                         green: UInt8,
                                         blue: UInt8,
                                         alpha: UInt8) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw OverlayRendererError.texture
        }
        var pixel = [red, green, blue, alpha]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &pixel,
            bytesPerRow: 4
        )
        return texture
    }
}
