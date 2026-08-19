import CoreGraphics
import Foundation

/// Draws the presentation layer in the same top-left canvas-pixel space used
/// by `AnnotationRenderer`. Keeping this separate lets the live canvas install
/// one scale/translation and share every background, shadow and clipping rule
/// with encoded exports.
nonisolated enum PresentationRenderer {
    static func draw(
        in ctx: CGContext,
        base: CGImage,
        blurSources: [BlurSource: CGImage],
        annotations: [Annotation],
        presentation: Presentation,
        layout: PresentationLayout.Resolved,
        skipping skippedID: UUID? = nil
    ) {
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)
        drawBackground(presentation.background, in: canvasRect, ctx: ctx)
        drawShadow(for: layout.imageRect,
                   canvasSize: layout.canvasSize,
                   cornerRadius: presentation.cornerRadius,
                   shadow: presentation.shadow,
                   in: ctx)

        guard layout.imageRect.width > 0,
              layout.imageRect.height > 0,
              base.width > 0,
              base.height > 0
        else { return }

        // Two clips, not one. The picture and its redactions are meaningless
        // outside the frame, so they keep the rounded image rect. Annotations
        // are allowed onto the background — an arrow pointing at the mockup or
        // a caption under it — so they are bounded by the canvas instead.
        ctx.saveGState()
        // The canvas crops: a picture scaled past the canvas edge is cut there,
        // not allowed to spill. Export got this free from the bitmap's own
        // bounds, so without this clip the live preview showed more than the
        // file would carry.
        ctx.clip(to: canvasRect)
        clip(to: layout.imageRect,
             canvasSize: layout.canvasSize,
             cornerRadius: presentation.cornerRadius,
             in: ctx)
        applyImageTransform(layout: layout, base: base, ctx: ctx)
        AnnotationRenderer.drawBaseLayer(in: ctx,
                                         base: base,
                                         blurSources: blurSources,
                                         annotations: annotations,
                                         skipping: skippedID)
        ctx.restoreGState()

        // The loupe reads pixels out of the picture, so it is measured in the
        // picture's coordinates and travels with it.
        ctx.saveGState()
        ctx.clip(to: canvasRect)
        applyImageTransform(layout: layout, base: base, ctx: ctx)
        AnnotationRenderer.drawAnnotationLayer(in: ctx,
                                               base: base,
                                               blurSources: blurSources,
                                               annotations: annotations,
                                               skipping: skippedID,
                                               where: { $0.livesInImageSpace })
        ctx.restoreGState()

        // Commentary belongs to the page: no image transform, so scaling or
        // nudging the picture inside the canvas leaves it exactly where it is.
        ctx.saveGState()
        ctx.clip(to: canvasRect)
        AnnotationRenderer.drawAnnotationLayer(in: ctx,
                                               base: base,
                                               blurSources: blurSources,
                                               annotations: annotations,
                                               skipping: skippedID,
                                               where: { !$0.livesInImageSpace })
        ctx.restoreGState()
    }

    /// Editor-only pass: what the canvas cropped away, drawn faintly outside it.
    ///
    /// Anything past the canvas edge is gone from the file, and a user who
    /// cannot see it cannot fix it — an annotation dragged out of frame would
    /// simply vanish with no way to select, move or delete it. So the preview
    /// keeps drawing it, dimmed, *only* outside the canvas: the even-odd clip
    /// leaves everything inside untouched, so nothing on the artwork is
    /// greyed. Never called from the export path.
    ///
    /// The picture is drawn here too, and that is not a detail: it is
    /// draggable, so it is the thing most likely to end up off the page. Drawn
    /// only inside the canvas, a picture pushed past the edge left the editor
    /// showing a bare background with nothing to grab and no hint of where the
    /// screenshot had gone.
    static func drawGhostOutsideCanvas(
        in ctx: CGContext,
        base: CGImage,
        blurSources: [BlurSource: CGImage],
        annotations: [Annotation],
        layout: PresentationLayout.Resolved,
        cornerRadius: CGFloat = 0,
        skipping skippedID: UUID? = nil,
        alpha: CGFloat = 0.3
    ) {
        let canvasRect = CGRect(origin: .zero, size: layout.canvasSize)
        guard canvasRect.width > 0, canvasRect.height > 0,
              base.width > 0, base.height > 0
        else { return }
        // Reach far enough that an annotation dragged well off-canvas still
        // gets drawn; the clip below is what actually bounds the paint.
        let outside = canvasRect.insetBy(dx: -canvasRect.width * 4,
                                         dy: -canvasRect.height * 4)

        ctx.saveGState()
        ctx.addRect(outside)
        ctx.addRect(canvasRect)
        ctx.clip(using: .evenOdd)
        ctx.setAlpha(alpha)

        // The picture and its redactions, in the picture's own rounded frame —
        // the same two-clip split the real pass uses, so the ghost is the
        // artwork itself rather than a lookalike.
        if layout.imageRect.width > 0, layout.imageRect.height > 0 {
            ctx.saveGState()
            clip(to: layout.imageRect,
                 canvasSize: layout.canvasSize,
                 cornerRadius: cornerRadius,
                 in: ctx)
            applyImageTransform(layout: layout, base: base, ctx: ctx)
            AnnotationRenderer.drawBaseLayer(in: ctx,
                                             base: base,
                                             blurSources: blurSources,
                                             annotations: annotations,
                                             skipping: skippedID)
            ctx.restoreGState()
        }

        ctx.saveGState()
        applyImageTransform(layout: layout, base: base, ctx: ctx)
        AnnotationRenderer.drawAnnotationLayer(in: ctx,
                                               base: base,
                                               blurSources: blurSources,
                                               annotations: annotations,
                                               skipping: skippedID,
                                               where: { $0.livesInImageSpace })
        ctx.restoreGState()

        AnnotationRenderer.drawAnnotationLayer(in: ctx,
                                               base: base,
                                               blurSources: blurSources,
                                               annotations: annotations,
                                               skipping: skippedID,
                                               where: { !$0.livesInImageSpace })
        ctx.restoreGState()
    }

    private static func applyImageTransform(layout: PresentationLayout.Resolved,
                                            base: CGImage,
                                            ctx: CGContext) {
        ctx.translateBy(x: layout.imageRect.origin.x, y: layout.imageRect.origin.y)
        ctx.scaleBy(x: layout.imageRect.width / CGFloat(base.width),
                    y: layout.imageRect.height / CGFloat(base.height))
    }

    /// Not private: the inspector's swatches draw their previews through this
    /// same routine, so a tile can never promise a background the export would
    /// paint differently.
    static func drawBackground(_ background: Presentation.Background,
                               in rect: CGRect,
                               ctx: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        switch background {
        case .none:
            return
        case .solid(let color):
            ctx.setFillColor(cgColor(color))
            ctx.fill(rect)
        case .linearGradient(let stops, let angle):
            drawLinearGradient(stops: stops, angle: angle, in: rect, ctx: ctx)
        case .radialGradient(let stops):
            drawRadialGradient(stops: stops, in: rect, ctx: ctx)
        case .mesh(let colors):
            drawMesh(colors: colors, in: rect, ctx: ctx)
        }
    }

    /// A gradient of `stops` spread evenly from 0 to 1. One stop degenerates to
    /// a flat fill rather than to nothing, which is what a user who deleted the
    /// second stop expects to see.
    private static func gradient(for stops: [Presentation.Color]) -> CGGradient? {
        guard let first = stops.first else { return nil }
        let colors = stops.count == 1 ? [first, first] : stops
        let last = CGFloat(colors.count - 1)
        let locations = colors.indices.map { CGFloat($0) / last }
        return CGGradient(colorsSpace: sRGB,
                          colors: colors.map(cgColor) as CFArray,
                          locations: locations)
    }

    /// `drawLinearGradient` paints the whole clip region, not the rect it is
    /// handed — so without this clip a gradient floods the live preview well
    /// past the canvas it belongs to. The export never showed it because there
    /// the context *is* the canvas.
    private static func drawLinearGradient(stops: [Presentation.Color],
                                           angle: CGFloat,
                                           in rect: CGRect,
                                           ctx: CGContext) {
        guard let gradient = gradient(for: stops) else { return }
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        let radius = hypot(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let from = CGPoint(x: center.x - direction.x * radius,
                           y: center.y - direction.y * radius)
        let to = CGPoint(x: center.x + direction.x * radius,
                         y: center.y + direction.y * radius)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Centred radial gradient reaching the far corner, so the outermost stop
    /// still covers the corners of a non-square canvas.
    private static func drawRadialGradient(stops: [Presentation.Color],
                                           in rect: CGRect,
                                           ctx: CGContext) {
        guard let gradient = gradient(for: stops) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: hypot(rect.width, rect.height) / 2,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    /// Core Graphics has no mesh primitive, so a small bilinear image gives the
    /// same value semantics without introducing a SwiftUI/AppKit object into
    /// the detached renderer. Four colors are corners; shorter palettes repeat
    /// their last color rather than making the background disappear. The image
    /// is deliberately much smaller than the export and is enlarged once with
    /// high-quality interpolation, avoiding visible flat tiles at large sizes.
    private static func drawMesh(colors: [Presentation.Color],
                                 in rect: CGRect,
                                 ctx: CGContext) {
        guard let first = colors.first else {
            ctx.setFillColor(cgColor(.clear))
            ctx.fill(rect)
            return
        }
        let corners = [
            first,
            colors.count > 1 ? colors[1] : first,
            colors.count > 2 ? colors[2] : first,
            colors.count > 3 ? colors[3] : (colors.count > 1 ? colors[1] : first)
        ]
        let sampleSize = 64
        let bytesPerRow = sampleSize * 4
        var pixels = [UInt8](repeating: 0, count: sampleSize * bytesPerRow)
        let meshImage = pixels.withUnsafeMutableBytes { rawBuffer -> CGImage? in
            guard let baseAddress = rawBuffer.baseAddress,
                  let meshContext = CGContext(
                      data: baseAddress,
                      width: sampleSize,
                      height: sampleSize,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }

            for y in 0..<sampleSize {
                let vertical = CGFloat(y) / CGFloat(sampleSize - 1)
                for x in 0..<sampleSize {
                    let horizontal = CGFloat(x) / CGFloat(sampleSize - 1)
                    let top = mix(corners[0], corners[1], amount: horizontal)
                    let bottom = mix(corners[2], corners[3], amount: horizontal)
                    let color = mix(top, bottom, amount: vertical)
                    let alpha = component(color.alpha)
                    let index = y * bytesPerRow + x * 4
                    rawBuffer[index] = byte(component(color.red) * alpha)
                    rawBuffer[index + 1] = byte(component(color.green) * alpha)
                    rawBuffer[index + 2] = byte(component(color.blue) * alpha)
                    rawBuffer[index + 3] = byte(alpha)
                }
            }
            return meshContext.makeImage()
        }

        guard let meshImage else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(meshImage, in: rect)
        ctx.restoreGState()

        func component(_ value: CGFloat) -> CGFloat {
            min(1, max(0, value.isFinite ? value : 0))
        }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8((min(1, max(0, value)) * 255).rounded())
        }
    }

    private static func drawShadow(for imageRect: CGRect,
                                   canvasSize: CGSize,
                                   cornerRadius: CGFloat,
                                   shadow: Presentation.Shadow,
                                   in ctx: CGContext) {
        let opacity = min(1, max(0, shadow.opacity))
        let radius = min(1, max(0, cornerRadius)) * min(canvasSize.width, canvasSize.height)
        let blur = max(0, shadow.radius) * max(canvasSize.width, canvasSize.height)
        guard opacity > 0, blur > 0, imageRect.width > 0, imageRect.height > 0 else { return }

        var tint = shadow.color
        tint.alpha = opacity
        let path = roundedPath(for: imageRect, radius: radius)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(
            // Core Graphics applies the y component in its device-space
            // direction after the renderer's top-left flip, so negate it to
            // keep a positive normalized offset below the image.
            offset: CGSize(width: shadow.offset.x * canvasSize.width,
                           height: -shadow.offset.y * canvasSize.height),
            blur: blur,
            color: cgColor(tint)
        )
        // Core Graphics scales a shadow by the source alpha. Use an opaque
        // source so the requested opacity survives, then remove that source
        // from the transparency layer before compositing it over the canvas.
        ctx.setFillColor(cgColor(Presentation.Color(red: 0, green: 0, blue: 0, alpha: 1)))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setBlendMode(.clear)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setBlendMode(.normal)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func clip(to imageRect: CGRect,
                             canvasSize: CGSize,
                             cornerRadius: CGFloat,
                             in ctx: CGContext) {
        let radius = min(
            min(1, max(0, cornerRadius)) * min(canvasSize.width, canvasSize.height),
            min(imageRect.width, imageRect.height) / 2
        )
        ctx.addPath(roundedPath(for: imageRect, radius: radius))
        ctx.clip()
    }

    private static func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect,
               cornerWidth: max(0, radius),
               cornerHeight: max(0, radius),
               transform: nil)
    }

    private static func mix(_ lhs: Presentation.Color,
                            _ rhs: Presentation.Color,
                            amount: CGFloat) -> Presentation.Color {
        let t = min(1, max(0, amount))
        return Presentation.Color(
            red: lhs.red + (rhs.red - lhs.red) * t,
            green: lhs.green + (rhs.green - lhs.green) * t,
            blue: lhs.blue + (rhs.blue - lhs.blue) * t,
            alpha: lhs.alpha + (rhs.alpha - lhs.alpha) * t
        )
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    private static func cgColor(_ color: Presentation.Color) -> CGColor {
        func component(_ value: CGFloat) -> CGFloat {
            min(1, max(0, value.isFinite ? value : 0))
        }
        return CGColor(
            colorSpace: sRGB,
            components: [component(color.red), component(color.green),
                         component(color.blue), component(color.alpha)]
        ) ?? CGColor(gray: 0, alpha: 0)
    }
}
