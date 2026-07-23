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
            case .line:  drawLine(annotation, ctx: ctx)
            case .arrow: drawArrow(annotation, ctx: ctx)
            case .rect:  drawShape(annotation, isOval: false, ctx: ctx)
            case .oval:  drawShape(annotation, isOval: true, ctx: ctx)
            case .roundedRect, .triangle, .polygon, .star, .bubble:
                drawPathShape(annotation, ctx: ctx)
            case .text:  drawText(annotation, ctx: ctx)
            case .freehand: drawFreehand(annotation, ctx: ctx)
            case .step:  drawStep(annotation, ctx: ctx)
            case .loupe: drawLoupe(annotation, base: base, blurSources: blurSources,
                                   annotations: annotations, ctx: ctx)
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

    private static func drawLine(_ a: Annotation, ctx: CGContext) {
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if a.lineStyle == .dashed {
            let dash = max(6, a.lineWidth * 2.4)
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
        }
        ctx.move(to: a.start)
        ctx.addLine(to: a.end)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// Smooth midpoint-quadratic path shared by pen and marker. Rendering is
    /// kept in this common export routine so the live preview and saved bitmap
    /// are pixel-for-pixel consistent.
    private static func drawFreehand(_ a: Annotation, ctx: CGContext) {
        guard let first = a.freehandPoints.first else { return }
        let color = a.color.multipliedAlpha(a.freehandStyle.opacity)

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        if a.freehandPoints.count == 1 {
            let radius = a.lineWidth / 2
            ctx.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius,
                                       width: a.lineWidth, height: a.lineWidth))
            ctx.restoreGState()
            return
        }

        ctx.move(to: first)
        if a.freehandPoints.count == 2 {
            ctx.addLine(to: a.freehandPoints[1])
        } else {
            for index in 1..<(a.freehandPoints.count - 1) {
                let control = a.freehandPoints[index]
                let next = a.freehandPoints[index + 1]
                let midpoint = CGPoint(x: (control.x + next.x) / 2,
                                       y: (control.y + next.y) / 2)
                ctx.addQuadCurve(to: midpoint, control: control)
            }
            if let last = a.freehandPoints.last { ctx.addLine(to: last) }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawArrow(_ a: Annotation, ctx: CGContext) {
        // `bold` draws a heavier shaft and a proportionally larger head so
        // arrows read clearly over busy screenshots; other styles keep the
        // annotation's own line width.
        let shaftWidth = a.arrowStyle == .bold ? a.lineWidth * 1.8 : a.lineWidth
        let headWidth = a.arrowStyle == .bold ? a.lineWidth * 1.8 : a.lineWidth

        // Curved shaft: stroke the full Bézier, then paint the heads over its
        // ends — the filled triangle covers the round cap, so no inset math.
        if let control = a.curveControl {
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setFillColor(a.color.cgColor)
            ctx.setLineWidth(shaftWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if a.arrowStyle == .dashed {
                let dash = max(6, shaftWidth * 2.4)
                ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
            }
            ctx.move(to: a.start)
            ctx.addQuadCurve(to: a.end, control: control)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            if a.arrowHeadPlacement.includesStart {
                drawArrowhead(from: a.arrowheadAnchor(towardTip: a.start, opposite: a.end),
                              tip: a.start, lineWidth: headWidth, ctx: ctx)
            }
            if a.arrowHeadPlacement.includesEnd {
                drawArrowhead(from: a.arrowheadAnchor(towardTip: a.end, opposite: a.start),
                              tip: a.end, lineWidth: headWidth, ctx: ctx)
            }
            return
        }

        let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
        let headLength = max(12, headWidth * 4)
        let overlap = headLength * 0.6
        let shaftLength = hypot(a.end.x - a.start.x, a.end.y - a.start.y)
        let headCount = (a.arrowHeadPlacement.includesStart ? 1 : 0)
            + (a.arrowHeadPlacement.includesEnd ? 1 : 0)
        let inset = min(overlap, headCount > 0 ? shaftLength / CGFloat(headCount) : 0)
        // Pull each shaft endpoint under its filled head. With two heads this
        // keeps the dashed/solid shaft visually centered between them. The
        // inset is capped so heads on a very short arrow never cross the shaft.
        let shaftStart = a.arrowHeadPlacement.includesStart
            ? CGPoint(x: a.start.x + inset * cos(angle),
                      y: a.start.y + inset * sin(angle))
            : a.start
        let shaftEnd = a.arrowHeadPlacement.includesEnd
            ? CGPoint(x: a.end.x - inset * cos(angle),
                      y: a.end.y - inset * sin(angle))
            : a.end

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
        ctx.move(to: shaftStart)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Filled triangle heads point outwards at their respective endpoints.
        if a.arrowHeadPlacement.includesStart {
            drawArrowhead(from: a.end, tip: a.start, lineWidth: headWidth, ctx: ctx)
        }
        if a.arrowHeadPlacement.includesEnd {
            drawArrowhead(from: a.start, tip: a.end, lineWidth: headWidth, ctx: ctx)
        }
    }

    private static func drawArrowhead(from: CGPoint, tip: CGPoint,
                                      lineWidth: CGFloat, ctx: CGContext) {
        let (b1, b2) = Annotation.arrowheadBarbs(from: from, tip: tip, lineWidth: lineWidth)
        ctx.move(to: tip)
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

    /// Path-outlined closed shapes (rounded rect, triangle, polygon, star,
    /// bubble): the same fill-then-stroke as rect/oval, over the shared
    /// outline path hit-testing uses. Round joins keep star and triangle
    /// tips from throwing long miter spikes at acute angles.
    private static func drawPathShape(_ a: Annotation, ctx: CGContext) {
        guard let outline = a.pathShapeOutline else { return }
        if a.fillOpacity > 0 {
            ctx.setFillColor(a.color.multipliedAlpha(a.fillOpacity).cgColor)
            ctx.addPath(outline)
            ctx.fillPath()
        }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineJoin(.round)
        ctx.addPath(outline)
        ctx.strokePath()
    }

    /// Outline path of a loupe body: an ellipse or a rounded rectangle. Used
    /// for the content clip, the border stroke, and a callout's source
    /// marker so they always coincide.
    static func loupePath(shape: LoupeShape, in r: CGRect) -> CGPath {
        switch shape {
        case .oval:
            return CGPath(ellipseIn: r, transform: nil)
        case .roundedRect:
            let radius = min(r.width, r.height) * 0.2
            return CGPath(roundedRect: r, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        }
    }

    static func loupePath(for a: Annotation) -> CGPath {
        loupePath(shape: a.loupeShape, in: a.rect)
    }

    /// Magnifier: scaled-up pixels inside the loupe shape, then a border
    /// stroke in the annotation color. An in-place loupe magnifies what's
    /// beneath it; a callout magnifies the region around `loupeSource`,
    /// drawing the source marker and a straight connector between the two
    /// bodies first, so the magnifier reads as layered above them. By
    /// default the magnified content respects blur redaction (the blur pass
    /// is replayed inside the magnified frame); `loupeRevealsOriginal` opts
    /// into raw base pixels instead.
    private static func drawLoupe(_ a: Annotation, base: CGImage,
                                  blurSources: [BlurSource: CGImage],
                                  annotations: [Annotation], ctx: CGContext) {
        let r = a.rect
        guard r.width > 0, r.height > 0 else { return }
        let center = CGPoint(x: r.midX, y: r.midY)
        let scale = max(1, a.loupeScale)
        let fullRect = CGRect(x: 0, y: 0,
                              width: CGFloat(base.width), height: CGFloat(base.height))
        let outline = loupePath(for: a)

        // Callout chrome beneath the magnifier: connector, then the source
        // marker's outline.
        if let sourceRect = a.loupeSourceRect {
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(a.lineWidth)
            if let (from, to) = a.loupeConnectorPoints() {
                ctx.move(to: from)
                ctx.addLine(to: to)
                ctx.strokePath()
            }
            ctx.addPath(loupePath(shape: a.loupeShape, in: sourceRect))
            ctx.strokePath()
        }

        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        // Map the sampled region onto the display: its center (the loupe's
        // own center in place, the source center for a callout) lands on the
        // display center, magnified. The clip stays fixed in device space.
        let sampleCenter = a.loupeSource ?? center
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -sampleCenter.x, y: -sampleCenter.y)
        drawImageInFlippedSpace(base, in: fullRect, ctx: ctx)
        if !a.loupeRevealsOriginal {
            // Replay the blur redaction pass inside the magnified frame.
            // Blur rects are image-space, so under this CTM each clips at
            // its magnified position — redacted stays redacted.
            for blur in annotations where blur.kind == .blur {
                let key = BlurSource(style: blur.blurStyle, level: blur.blurLevel)
                guard let source = blurSources[key] else { continue }
                ctx.saveGState()
                ctx.clip(to: blur.rect)
                drawImageInFlippedSpace(source, in: fullRect, ctx: ctx)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()

        // Border on top.
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.addPath(outline)
        ctx.strokePath()
    }

    /// Bold font sized so `label` fits inside a marker of `diameter`, capped
    /// so a single digit doesn't balloon. Fitting by measured width *and*
    /// height keeps "1" and "10" visually proportional (fixes the old
    /// digit-count shrink where two digits went tiny).
    static func stepFontSize(label: String, diameter: CGFloat,
                             fontPreset: AnnotationFontPreset = .system) -> CGFloat {
        let text = label.isEmpty ? "0" : label
        let usable = diameter * 0.66
        let cap = max(12, diameter * 0.56)            // single-digit ceiling
        let reference: CGFloat = 100
        let refFont = fontPreset.nsFont(ofSize: reference, bold: true)
        let measured = (text as NSString).size(withAttributes: [.font: refFont])
        guard measured.width > 0, measured.height > 0 else { return cap }
        let scale = min(usable / measured.width, usable / measured.height)
        return min(cap, reference * scale)
    }

    static func stepFont(for a: Annotation) -> NSFont {
        let fitted = stepFontSize(label: a.stepLabel, diameter: a.stepDiameter,
                                  fontPreset: a.fontPreset)
        // An explicit label size can only shrink the label — the fitted size
        // is the largest that stays inside the circle.
        let size = min(a.stepLabelSize ?? fitted, fitted)
        return a.fontPreset.nsFont(ofSize: size, bold: true)
    }

    private static func drawStep(_ a: Annotation, ctx: CGContext) {
        ctx.setFillColor(a.color.cgColor)
        ctx.fillEllipse(in: a.rect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: stepFont(for: a),
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
        a.fontPreset.nsFont(ofSize: a.fontSize, bold: a.bold, italic: a.italic)
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = a.textAlignment.nsAlignment
        attrs[.paragraphStyle] = paragraph
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
