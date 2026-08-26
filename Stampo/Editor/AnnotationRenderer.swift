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
nonisolated enum AnnotationRenderer {

    // MARK: Blur source preparation (once per style+level per document)

    /// Filter-strength multiplier for an intensity detent. Level 3 keeps the
    /// original image-relative strength; the scale is roughly geometric so
    /// each detent is a visible step.
    nonisolated private static func intensityMultiplier(_ level: Int) -> CGFloat {
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
    nonisolated static func makeBlurred(base: CGImage, level: Int = BlurIntensity.defaultLevel) -> CGImage? {
        let input = CIImage(cgImage: base)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        let radius = CGFloat(max(8, min(base.width, base.height) / 80)) * intensityMultiplier(level)
        filter.radius = Float(max(3, radius))
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// Full-size pixelated copy of the base for the pixelate style.
    nonisolated static func makePixelated(base: CGImage, level: Int = BlurIntensity.defaultLevel) -> CGImage? {
        let input = CIImage(cgImage: base)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        let scale = CGFloat(max(8, min(base.width, base.height) / 50)) * intensityMultiplier(level)
        filter.scale = Float(max(4, scale))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

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
        pictures: [UUID: CGImage] = [:],
        annotations: [Annotation],
        skipping skippedID: UUID? = nil
    ) {
        drawBaseLayer(in: ctx, base: base, blurSources: blurSources,
                      annotations: annotations, skipping: skippedID)
        drawAnnotationLayer(in: ctx, base: base, blurSources: blurSources,
                            pictures: pictures,
                            annotations: annotations, skipping: skippedID)
    }

    /// The image plus its redactions — everything that is meaningless outside
    /// the picture's own bounds. Split from the annotation layer so a decorated
    /// canvas can clip this half to the rounded image rect while letting the
    /// other half reach the background.
    static func drawBaseLayer(
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
    }

    /// Everything the user draws on top: arrows, shapes, text, steps, loupes.
    /// These may legitimately sit on the decorated background, so they are
    /// never clipped to the image.
    static func drawAnnotationLayer(
        in ctx: CGContext,
        base: CGImage,
        blurSources: [BlurSource: CGImage],
        /// The user's own pictures, by the name the annotations call them —
        /// beside the annotations for the same reason the blurred copies are
        /// beside the blur ones: a value that crosses into the export task
        /// should not be carrying images.
        pictures: [UUID: CGImage] = [:],
        annotations: [Annotation],
        skipping skippedID: UUID? = nil,
        where include: (Annotation) -> Bool = { _ in true }
    ) {
        let annotations = annotations.filter(include)
        for annotation in annotations
            where annotation.id != skippedID && annotation.kind != .blur {
            switch annotation.kind {
            case .line:  drawLine(annotation, in: annotations, ctx: ctx)
            case .arrow: drawArrow(annotation, in: annotations, ctx: ctx)
            case .rect:  drawShape(annotation, isOval: false, ctx: ctx)
            case .oval:  drawShape(annotation, isOval: true, ctx: ctx)
            case .roundedRect, .polygon, .star, .bubble:
                drawPathShape(annotation, ctx: ctx)
            case .text:  drawText(annotation, ctx: ctx)
            case .freehand: drawFreehand(annotation, ctx: ctx)
            case .step:  drawStep(annotation, ctx: ctx)
            case .loupe: drawLoupe(annotation, base: base, blurSources: blurSources,
                                   annotations: annotations, ctx: ctx)
            case .picture:
                drawPicture(annotation, pictures: pictures, ctx: ctx)
            case .blur:  break  // handled in the first pass
            }
        }
    }

    /// A picture placed on the page: drawn to fill the rectangle it was given,
    /// which is the rectangle the user dragged it to.
    ///
    /// Nothing is drawn when the document does not have the pixels — a name
    /// without an image is a picture that was never loaded, and an outline
    /// standing in for it would be a second thing to explain.
    private static func drawPicture(_ a: Annotation, pictures: [UUID: CGImage],
                                    ctx: CGContext) {
        guard let id = a.pictureID, let picture = pictures[id] else { return }
        let rect = a.rect
        let radius = min(max(0, a.pictureCornerRadius) * min(rect.width, rect.height),
                         min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

        // The lights first, cast by the picture's own shape and drawn the way
        // the page casts the screenshot's: an opaque stand-in inside a
        // transparency layer, then cut away, because Core Graphics scales a
        // shadow by the source alpha. The glow underneath the shadow, so a dark
        // shadow reads over the halo rather than being washed out by it — the
        // same order the page uses.
        let short = min(rect.width, rect.height)
        if a.pictureGlow > 0 {
            castLight(under: path, blur: short * 0.09 * min(1, a.pictureGlow),
                      offset: .zero,
                      color: CGColor(srgbRed: a.pictureGlowColor.red,
                                     green: a.pictureGlowColor.green,
                                     blue: a.pictureGlowColor.blue,
                                     alpha: min(1, a.pictureGlow)),
                      ctx: ctx)
        }
        if a.pictureShadow > 0 {
            let strength = min(1, a.pictureShadow)
            castLight(under: path, blur: short * 0.06 * strength,
                      offset: CGSize(width: 0, height: -short * 0.02 * strength),
                      color: CGColor(srgbRed: a.pictureShadowColor.red,
                                     green: a.pictureShadowColor.green,
                                     blue: a.pictureShadowColor.blue,
                                     alpha: 0.55 * strength), ctx: ctx)
        }

        ctx.saveGState()
        ctx.interpolationQuality = .high
        if radius > 0 {
            ctx.addPath(path)
            ctx.clip()
        }
        // The picture's own effects are pixel work on the picture alone, so
        // they are baked into it before it is drawn — the same arrangement the
        // background uses, and cached the same way.
        //
        // At the size it is drawn, taken from the context itself, exactly as
        // the background and the page layer take theirs: the canvas asks in
        // screen pixels and the export in the file's, so both get the same
        // picture rather than the same numbers read at two resolutions. Baking
        // at the picture's own size instead cost 897 ms a frame for fluted
        // glass on a 4096-pixel photograph.
        let drawn = ctx.convertToDeviceSpace(rect).size
        let treated = EffectBaker.object(a.pictureEffects, over: picture, named: id,
                                         drawnAt: drawn) ?? picture
        drawImageInFlippedSpace(treated, in: rect, ctx: ctx)
        ctx.restoreGState()
    }

    /// A shadow or a glow cast by a shape, with the shape itself cut back out
    /// of it — Core Graphics scales a shadow by the source alpha, so the caster
    /// has to be opaque and then removed.
    private static func castLight(under path: CGPath, blur: CGFloat, offset: CGSize,
                                  color: CGColor, ctx: CGContext) {
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(offset: offset, blur: blur, color: color)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
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

    /// `CGContext.draw` renders images bottom-up; under our flipped (top-left)
    /// transform that would mirror them. Un-flip locally around the full
    /// canvas: correct everywhere, including inside clip regions (the clip
    /// stays fixed in device space).
    /// Not private: `PresentationRenderer` draws its baked background through
    /// this same helper, so a bitmap and the picture land in the flipped space
    /// by one rule rather than two.
    static func drawImageInFlippedSpace(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func drawLine(_ a: Annotation, in annotations: [Annotation],
                                 ctx: CGContext) {
        let start = a.resolvedStart(in: annotations)
        let end = a.resolvedEnd(in: annotations)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if a.lineStyle == .dashed {
            let dash = max(6, a.lineWidth * 2.4)
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
        }
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
    }

    /// Smooth midpoint-quadratic path shared by pen and marker. Rendering is
    /// kept in this common export routine so the live preview and saved bitmap
    /// are pixel-for-pixel consistent.
    private static func drawFreehand(_ a: Annotation, ctx: CGContext) {
        guard let first = a.freehandPoints.first else { return }
        let color = a.color.multipliedAlpha(a.freehandStyle.opacity)
        // A square marker nib lays flat stroke caps (chisel-highlighter);
        // joins stay round so the smoothed path doesn't grow corners.
        let squareTip = a.freehandStyle == .marker && a.markerTip == .square

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(squareTip ? .square : .round)
        ctx.setLineJoin(.round)

        if a.freehandPoints.count == 1 {
            let radius = a.lineWidth / 2
            let dot = CGRect(x: first.x - radius, y: first.y - radius,
                             width: a.lineWidth, height: a.lineWidth)
            if squareTip { ctx.fill(dot) } else { ctx.fillEllipse(in: dot) }
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

    private static func drawArrow(_ a: Annotation, in annotations: [Annotation],
                                  ctx: CGContext) {
        // Bound endpoints resolve to their target's outline; a free endpoint
        // resolves to its raw point, so unbound arrows are unaffected.
        let start = a.resolvedStart(in: annotations)
        let end = a.resolvedEnd(in: annotations)
        let width = a.lineWidth
        // Pull a headed shaft end back by half the stroke so its round cap
        // lands at the tip rather than poking past the open arrowhead. A tail
        // without a head keeps its endpoint (and round cap) as is.
        let capInset = width / 2

        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Elbow: an axis-aligned route with rounded corners; heads point along
        // the first/last leg.
        if a.isElbowed {
            let route = a.elbowRoute(in: annotations)
            guard route.count >= 2 else { return }
            let headStart = a.arrowHeadPlacement.includesStart
                ? Self.insetAlong(route[0], toward: route[1], by: capInset) : route[0]
            let headEnd = a.arrowHeadPlacement.includesEnd
                ? Self.insetAlong(route[route.count - 1],
                                  toward: route[route.count - 2], by: capInset)
                : route[route.count - 1]
            var trimmed = route
            trimmed[0] = headStart
            trimmed[trimmed.count - 1] = headEnd
            ctx.addPath(Self.roundedPolyline(trimmed, radius: max(6, width * 2)))
            ctx.strokePath()

            if a.arrowHeadPlacement.includesStart {
                drawChevron(from: route[1], tip: route[0], scale: a.arrowHeadScale,
                            lineWidth: width, ctx: ctx)
            }
            if a.arrowHeadPlacement.includesEnd {
                drawChevron(from: route[route.count - 2], tip: route[route.count - 1],
                            scale: a.arrowHeadScale, lineWidth: width, ctx: ctx)
            }
            return
        }

        // Curved shaft: stroke the Bézier, then the open chevron heads over
        // its ends (pulled back along the tangent by the cap inset). The
        // control follows the resolved chord so a bound arrow's bend doesn't
        // drift. The head tangent anchors on the control (or the opposite end
        // when the control sits on top of the tip).
        if let control = a.resolvedControl(in: annotations) {
            let curveStart = a.arrowHeadPlacement.includesStart
                ? Self.insetTowardControl(start, control: control, by: capInset)
                : start
            let curveEnd = a.arrowHeadPlacement.includesEnd
                ? Self.insetTowardControl(end, control: control, by: capInset)
                : end
            if a.arrowStyle == .dashed {
                let dash = max(6, width * 2.4)
                ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
            }
            ctx.move(to: curveStart)
            ctx.addQuadCurve(to: curveEnd, control: control)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            if a.arrowHeadPlacement.includesStart {
                let anchor = hypot(control.x - start.x, control.y - start.y) >= 1
                    ? control : end
                drawChevron(from: anchor, tip: start, scale: a.arrowHeadScale,
                            lineWidth: width, ctx: ctx)
            }
            if a.arrowHeadPlacement.includesEnd {
                let anchor = hypot(control.x - end.x, control.y - end.y) >= 1
                    ? control : start
                drawChevron(from: anchor, tip: end, scale: a.arrowHeadScale,
                            lineWidth: width, ctx: ctx)
            }
            return
        }

        let angle = atan2(end.y - start.y, end.x - start.x)
        let shaftStart = a.arrowHeadPlacement.includesStart
            ? CGPoint(x: start.x + capInset * cos(angle),
                      y: start.y + capInset * sin(angle))
            : start
        let shaftEnd = a.arrowHeadPlacement.includesEnd
            ? CGPoint(x: end.x - capInset * cos(angle),
                      y: end.y - capInset * sin(angle))
            : end

        if a.arrowStyle == .dashed {
            let dash = max(6, width * 2.4)
            ctx.setLineDash(phase: 0, lengths: [dash, dash * 0.8])
        }
        ctx.move(to: shaftStart)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Open chevron heads point outwards at their respective endpoints.
        if a.arrowHeadPlacement.includesStart {
            drawChevron(from: end, tip: start, scale: a.arrowHeadScale,
                        lineWidth: width, ctx: ctx)
        }
        if a.arrowHeadPlacement.includesEnd {
            drawChevron(from: start, tip: end, scale: a.arrowHeadScale,
                        lineWidth: width, ctx: ctx)
        }
    }

    /// Moves a curved arrow's endpoint back toward its control point by up to
    /// `distance`, along the end tangent (control→endpoint). Capped so it
    /// never passes the control on a short curve. Keeps the drawn shaft short
    /// of the real tip so the round cap tucks under the arrowhead.
    private static func insetTowardControl(_ endpoint: CGPoint, control: CGPoint,
                                           by distance: CGFloat) -> CGPoint {
        let dx = endpoint.x - control.x, dy = endpoint.y - control.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return endpoint }
        let d = min(distance, length * 0.9)
        return CGPoint(x: endpoint.x - dx / length * d,
                       y: endpoint.y - dy / length * d)
    }

    /// Moves `point` toward `other` by up to `distance` (capped at 90% of the
    /// gap) — pulls a headed route end back so its cap tucks under the head.
    private static func insetAlong(_ point: CGPoint, toward other: CGPoint,
                                   by distance: CGFloat) -> CGPoint {
        let dx = other.x - point.x, dy = other.y - point.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return point }
        let d = min(distance, length * 0.9)
        return CGPoint(x: point.x + dx / length * d, y: point.y + dy / length * d)
    }

    /// A polyline with its corners rounded by arcs — the elbow connector's
    /// look. Each radius is capped to half of the shorter adjacent leg so tight
    /// corners stay clean.
    private static func roundedPolyline(_ points: [CGPoint],
                                        radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1], corner = points[index]
            let next = points[index + 1]
            let inLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outLength = hypot(next.x - corner.x, next.y - corner.y)
            let r = min(radius, inLength / 2, outLength / 2)
            if r < 0.5 {
                path.addLine(to: corner)
            } else {
                path.addArc(tangent1End: corner, tangent2End: next, radius: r)
            }
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// An open "chevron" arrowhead — two strokes meeting at the tip
    /// (Figma-style), drawn in the shaft's own weight instead of a filled
    /// triangle. Round caps and join keep the point clean.
    private static func drawChevron(from: CGPoint, tip: CGPoint, scale: CGFloat = 1,
                                    lineWidth: CGFloat, ctx: CGContext) {
        let (b1, b2) = Annotation.arrowheadBarbs(from: from, tip: tip,
                                                 lineWidth: lineWidth, scale: scale)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: b1)
        ctx.addLine(to: tip)
        ctx.addLine(to: b2)
        ctx.strokePath()
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

    /// Renders the document at the presentation's output canvas size. With no
    /// presentation, the identity value resolves to the image's native size,
    /// so existing callers retain their old dimensions and coordinate space.
    nonisolated static func renderBitmap(
        base: CGImage,
        blurSources: [BlurSource: CGImage] = [:],
        pictures: [UUID: CGImage] = [:],
        annotations: [Annotation],
        presentation: Presentation? = nil
    ) -> NSBitmapImageRep? {
        // `nil` means "nobody decorated this", and that has to stay lossless.
        // The identity's geometry is exactly the image, but its background is
        // a white page: painting it would fill the transparent halo of a
        // window shot taken with its shadow, turning an untouched document
        // opaque on save. The live canvas draws no background there either.
        var resolvedPresentation = presentation ?? .identity
        if presentation == nil { resolvedPresentation.background = .none }
        let layout = PresentationLayout.resolve(
            imagePixelSize: CGSize(width: base.width, height: base.height),
            resolvedPresentation
        )
        let W = max(1, Int(layout.canvasSize.width.rounded()))
        let H = max(1, Int(layout.canvasSize.height.rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        // 1pt == 1px in the output canvas; PresentationRenderer installs the
        // imageRect transform before handing the image space to AnnotationRenderer.
        rep.size = NSSize(width: W, height: H)

        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let ctx = gc.cgContext
        // Bitmap contexts are bottom-left native; flip into the renderer's
        // top-left pixel-space contract.
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        PresentationRenderer.draw(in: ctx,
                                  base: base,
                                  blurSources: blurSources,
                                  pictures: pictures,
                                  annotations: annotations,
                                  presentation: resolvedPresentation,
                                  layout: layout)
        ctx.flush()
        return rep
    }

    /// Worker-facing export. The bitmap representation never crosses the
    /// actor boundary; only encoded bytes do.
    nonisolated static func renderEncoded(
        snapshot: EditorRenderSnapshot
    ) -> RenderedArtifact? {
        guard let rep = renderBitmap(
            base: snapshot.baseImage,
            blurSources: snapshot.blurSources,
            pictures: snapshot.pictures,
            annotations: snapshot.annotations,
            presentation: snapshot.presentation
        ) else { return nil }
        let (fileType, properties) = ScreenshotFileStore.encoding(for: snapshot.format)
        guard let data = rep.representation(using: fileType, properties: properties)
        else { return nil }
        return RenderedArtifact(data: data, format: snapshot.format, revision: snapshot.revision)
    }
}
