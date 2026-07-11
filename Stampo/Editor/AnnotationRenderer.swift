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

    // MARK: Blur source preparation (once per document)

    /// Full-size gaussian-blurred copy of the base. Blur annotations clip to
    /// their rect and draw this image — no per-region CI math, no CI
    /// coordinate flips, no edge bleed (clamp + crop handles the borders).
    static func makeBlurred(base: CGImage) -> CGImage? {
        let input = CIImage(cgImage: base)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(max(8, min(base.width, base.height) / 80))
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    /// Full-size pixelated copy of the base for the pixelate style.
    static func makePixelated(base: CGImage) -> CGImage? {
        let input = CIImage(cgImage: base)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(8, min(base.width, base.height) / 50))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: Drawing

    /// Draws base image + annotations into a top-left-oriented pixel-space
    /// context. `skipping` omits one annotation (the one being text-edited —
    /// the live TextField overlay renders it instead).
    static func draw(
        in ctx: CGContext,
        base: CGImage,
        blurred: CGImage?,
        pixelated: CGImage?,
        annotations: [Annotation],
        skipping skippedID: UUID? = nil
    ) {
        let W = CGFloat(base.width), H = CGFloat(base.height)
        let fullRect = CGRect(x: 0, y: 0, width: W, height: H)

        drawImageInFlippedSpace(base, in: fullRect, ctx: ctx)

        for annotation in annotations where annotation.id != skippedID {
            switch annotation.kind {
            case .arrow:
                drawArrow(annotation, ctx: ctx)
            case .rect:
                ctx.setStrokeColor(annotation.color.cgColor)
                ctx.setLineWidth(annotation.lineWidth)
                ctx.setLineJoin(.miter)
                ctx.stroke(annotation.rect)
            case .oval:
                ctx.setStrokeColor(annotation.color.cgColor)
                ctx.setLineWidth(annotation.lineWidth)
                ctx.strokeEllipse(in: annotation.rect)
            case .blur:
                let source = annotation.blurStyle == .pixelate ? pixelated : blurred
                guard let source else { break }
                ctx.saveGState()
                ctx.clip(to: annotation.rect)
                drawImageInFlippedSpace(source, in: fullRect, ctx: ctx)
                ctx.restoreGState()
            case .text:
                drawText(annotation, ctx: ctx)
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
        let (b1, b2) = Annotation.arrowheadBarbs(from: a.start, tip: a.end, lineWidth: a.lineWidth)
        // Shorten the shaft slightly so it doesn't poke through the head tip.
        let angle = atan2(a.end.y - a.start.y, a.end.x - a.start.x)
        let headLength = max(10, a.lineWidth * 3.5)
        let shaftEnd = CGPoint(x: a.end.x - headLength * 0.6 * cos(angle),
                               y: a.end.y - headLength * 0.6 * sin(angle))

        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)

        ctx.move(to: a.start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        ctx.move(to: a.end)
        ctx.addLine(to: b1)
        ctx.addLine(to: b2)
        ctx.closePath()
        ctx.fillPath()
    }

    static func textAttributes(for a: Annotation) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = a.fontSize / 9
        shadow.shadowOffset = .zero
        return [
            .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
            .foregroundColor: a.color.nsColor,
            .shadow: shadow,
        ]
    }

    /// Measured pixel size of the annotation's text at its font size.
    static func measureText(_ a: Annotation) -> CGSize {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        let bounds = NSAttributedString(string: a.text, attributes: textAttributes(for: a))
            .boundingRect(with: unbounded, options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private static func drawText(_ a: Annotation, ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        // Bridge to AppKit string drawing in the already-flipped context.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: a.text, attributes: textAttributes(for: a))
            .draw(with: CGRect(origin: CGPoint(x: min(a.start.x, a.end.x),
                                               y: min(a.start.y, a.end.y)),
                               size: a.rect.size),
                  options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current = previous
    }

    // MARK: Export

    /// Renders the document at the base image's native pixel size.
    /// The output rep's pixel dimensions always equal the source's.
    static func renderBitmap(
        base: CGImage,
        blurred: CGImage?,
        pixelated: CGImage?,
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
        draw(in: ctx, base: base, blurred: blurred, pixelated: pixelated,
             annotations: annotations)
        ctx.flush()
        return rep
    }
}
