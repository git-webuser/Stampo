import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import OSLog

/// One shared CoreGraphics draw routine used by both the live SwiftUI Canvas
/// preview and the bitmap export — preview and file always match.
///
/// Coordinate contract: `draw(in:)` expects a context whose current transform
/// puts the origin at the image's **top-left with y growing downward**, in
/// image pixel units (the same space the Annotation model uses). SwiftUI's
/// `withCGContext` already provides top-left orientation; `renderBitmap`
/// flips the bottom-left-native bitmap context before calling in.
enum AnnotationRenderer {

    // MARK: Blur source preparation (once per style+level per document)

    /// Filter-strength multiplier for an intensity detent. Level 3 keeps the
    /// original image-relative strength; the scale is roughly geometric so
    /// each detent is a visible step.
    private static func intensityMultiplier(_ level: Int) -> CGFloat {
        switch BlurIntensity.clamped(level) {
        case 1: return 0.35
        case 2: return 0.6
        case 3: return 1.0
        case 4: return 1.6
        default: return 2.5
        }
    }

    /// Full-size gaussian-blurred copy of the base. Blur annotations clip to
    /// their rect and draw this image — no per-region CI math, no CI
    /// coordinate flips, no edge bleed (clamp + crop handles the borders).
    static func makeBlurred(base: CGImage, level: Int = BlurIntensity.defaultLevel) -> CGImage? {
        let input = CIImage(cgImage: base)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        let radius = CGFloat(max(8, min(base.width, base.height) / 80)) * intensityMultiplier(level)
        filter.radius = Float(max(3, radius))
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// Full-size pixelated copy of the base for the pixelate style.
    static func makePixelated(base: CGImage, level: Int = BlurIntensity.defaultLevel) -> CGImage? {
        let input = CIImage(cgImage: base)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        let scale = CGFloat(max(8, min(base.width, base.height) / 50)) * intensityMultiplier(level)
        filter.scale = Float(max(4, scale))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: Whole-image rotation

    /// A quarter-turned copy of the image (dimensions swap W↔H). Drawn through
    /// a rotated CTM so the result is a plain, upright CGImage in the new frame.
    static func rotated90(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: h, height: w,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        // Bottom-left origin: rotate about the new canvas so the source lands
        // upright in the swapped dimensions.
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Drawing

    /// Draws base image + annotations into a top-left-oriented pixel-space
    /// context. `skipping` omits one annotation (the one being text-edited —
    /// the live TextField overlay renders it instead).
    static func draw(
        in ctx: CGContext,
        base: CGImage,
        blurSources: [BlurSource: CGImage],
        annotations: [Annotation],
        skipping skippedID: UUID? = nil
    ) {
        let W = CGFloat(base.width), H = CGFloat(base.height)
        let fullRect = CGRect(x: 0, y: 0, width: W, height: H)

        drawImageInFlippedSpace(base, in: fullRect, ctx: ctx)

        // Blur/pixelate is a redaction layer — it always sits directly on the
        // image, beneath every other annotation. Draw those first, then the
        // rest in their own order on top.
        for annotation in annotations
            where annotation.id != skippedID && annotation.kind == .blur {
            let key = BlurSource(style: annotation.blurStyle, level: annotation.blurLevel)
            guard let source = blurSources[key] else { continue }
            ctx.saveGState()
            ctx.clip(to: annotation.rect)
            drawImageInFlippedSpace(source, in: fullRect, ctx: ctx)
            ctx.restoreGState()
        }

        for annotation in annotations
            where annotation.id != skippedID && annotation.kind != .blur {
            switch annotation.kind {
            case .arrow: drawArrow(annotation, ctx: ctx)
            case .rect:  drawShape(annotation, isOval: false, ctx: ctx)
            case .oval:  drawShape(annotation, isOval: true, ctx: ctx)
            case .text:  drawText(annotation, ctx: ctx)
            case .step:  drawStep(annotation, ctx: ctx)
            case .blur:  break  // handled in the first pass
            }
        }
    }

    /// `CGContext.draw` renders images bottom-up; under our flipped (top-left)
    /// transform that would mirror them. Un-flip locally around the full
    /// canvas: correct everywhere, including inside clip regions (the clip
    /// stays fixed in device space).
    private static func drawImageInFlippedSpace(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func drawArrow(_ a: Annotation, ctx: CGContext) {
        // `bold` draws a heavier shaft and a proportionally larger head so
        // arrows read clearly over busy screenshots; other styles keep the
        // annotation's own line width.
        let shaftWidth = a.arrowStyle == .bold ? a.lineWidth * 1.8 : a.lineWidth
        let headWidth = a.arrowStyle == .bold ? a.lineWidth * 1.8 : a.lineWidth
        let (b1, b2) = Annotation.arrowheadBarbs(from: a.start, tip: a.end, lineWidth: headWidth)
        let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
        let headLength = max(12, headWidth * 4)
        // The filled head overlaps the shaft, so pull the shaft back under it.
        let shaftEnd = CGPoint(x: a.end.x - headLength * 0.6 * cos(angle),
                               y: a.end.y - headLength * 0.6 * sin(angle))

        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(shaftWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Shaft.
        if a.arrowStyle == .dashed {
            let dash = max(6, shaftWidth * 2.4)
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
        }
        ctx.move(to: a.start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Filled triangle head.
        ctx.move(to: a.end)
        ctx.addLine(to: b1)
        ctx.addLine(to: b2)
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawShape(_ a: Annotation, isOval: Bool, ctx: CGContext) {
        if a.fillOpacity > 0 {
            ctx.setFillColor(a.color.multipliedAlpha(a.fillOpacity).cgColor)
            if isOval {
                ctx.fillEllipse(in: a.rect)
            } else {
                ctx.fill(a.rect)
            }
        }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineJoin(.miter)
        if isOval {
            ctx.strokeEllipse(in: a.rect)
        } else {
            ctx.stroke(a.rect)
        }
    }

    /// Bold font sized so `label` fits inside a marker of `diameter`, capped
    /// so a single digit doesn't balloon. Fitting by measured width *and*
    /// height keeps "1" and "10" visually proportional (fixes the old
    /// digit-count shrink where two digits went tiny).
    static func stepFontSize(label: String, diameter: CGFloat) -> CGFloat {
        let text = label.isEmpty ? "0" : label
        let usable = diameter * 0.66
        let cap = max(12, diameter * 0.56)            // single-digit ceiling
        let reference: CGFloat = 100
        let refFont = NSFont.systemFont(ofSize: reference, weight: .bold)
        let measured = (text as NSString).size(withAttributes: [.font: refFont])
        guard measured.width > 0, measured.height > 0 else { return cap }
        let scale = min(usable / measured.width, usable / measured.height)
        return min(cap, reference * scale)
    }

    private static func drawStep(_ a: Annotation, ctx: CGContext) {
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: a.rect)

        let fontSize = stepFontSize(label: a.stepLabel, diameter: a.stepDiameter)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: a.color.contrastingTextColor,
        ]
        let string = NSAttributedString(string: a.stepLabel, attributes: attributes)
        let measured = string.boundingRect(
            with: CGSize(width: a.stepDiameter, height: a.stepDiameter),
            options: [.usesLineFragmentOrigin]
        )
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        string.draw(
            at: CGPoint(x: a.rect.midX - measured.width / 2,
                        y: a.rect.midY - measured.height / 2)
        )
        NSGraphicsContext.current = previous
    }

    /// Base font honoring the bold/italic flags.
    static func textFont(for a: Annotation) -> NSFont {
        let font = NSFont.systemFont(ofSize: a.fontSize, weight: a.bold ? .bold : .regular)
        return a.italic
            ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            : font
    }

    static func textAttributes(for a: Annotation) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: textFont(for: a),
            .foregroundColor: a.color.nsColor,
        ]
        if a.textShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = a.fontSize / 9
            shadow.shadowOffset = .zero
            attrs[.shadow] = shadow
        }
        if a.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if a.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    /// Padding between a background plate's edge and the glyphs.
    static func textInset(for a: Annotation) -> CGFloat {
        a.textBackground == .none ? 0 : max(4, a.fontSize * 0.2)
    }

    /// Measured pixel size of the annotation, including any background inset
    /// so its selection bounds match what's drawn.
    static func measureText(_ a: Annotation) -> CGSize {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        let bounds = NSAttributedString(string: a.text, attributes: textAttributes(for: a))
            .boundingRect(with: unbounded, options: [.usesLineFragmentOrigin])
        let inset = textInset(for: a)
        return CGSize(width: ceil(bounds.width) + inset * 2,
                      height: ceil(bounds.height) + inset * 2)
    }

    private static func drawText(_ a: Annotation, ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let origin = CGPoint(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y))

        // Backing plate.
        if a.textBackground != .none {
            let plate = a.textBackground == .dark
                ? NSColor.black.withAlphaComponent(0.55)
                : NSColor.white.withAlphaComponent(0.75)
            ctx.setFillColor(plate.cgColor)
            let radius = min(a.rect.width, a.rect.height) * 0.18
            let path = CGPath(roundedRect: CGRect(origin: origin, size: a.rect.size),
                              cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Bridge to AppKit string drawing in the already-flipped context.
        let inset = textInset(for: a)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: a.text, attributes: textAttributes(for: a))
            .draw(with: CGRect(origin: CGPoint(x: origin.x + inset, y: origin.y + inset),
                               size: CGSize(width: a.rect.width - inset * 2,
                                            height: a.rect.height - inset * 2)),
                  options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current = previous
    }

    // MARK: Export

    /// Renders the document at the base image's native pixel size.
    /// The output rep's pixel dimensions always equal the source's.
    static func renderBitmap(
        base: CGImage,
        blurSources: [BlurSource: CGImage] = [:],
        annotations: [Annotation]
    ) -> NSBitmapImageRep? {
        let W = base.width, H = base.height
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // 1pt == 1px so annotation pixel coordinates need no scaling.
        rep.size = NSSize(width: W, height: H)

        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let ctx = gc.cgContext
        // Bitmap contexts are bottom-left native; flip into the renderer's
        // top-left pixel-space contract.
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        draw(in: ctx, base: base, blurSources: blurSources,
             annotations: annotations)
        ctx.flush()
        return rep
    }
}
