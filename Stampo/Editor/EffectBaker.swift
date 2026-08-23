import CoreGraphics
import CoreImage
import CoreText
import CoreImage.CIFilterBuiltins
import Foundation

/// Bakes a background with its effects into a bitmap.
///
/// Effects are pixel work, and the renderer is a `CGContext` routine — so the
/// two meet the way blur and pixelate already meet the annotations: the pixels
/// are computed *ahead* into a `CGImage`, and the drawing routine merely draws
/// it (see `AnnotationRenderer.makeBlurred`). Nothing about the preview/export
/// contract changes, because both ask for the same picture at the size they
/// each need.
///
/// **Resolution comes from the caller**, and every size inside is a fraction of
/// the short side, so the same stack read at 900 screen pixels and at 3000 file
/// pixels is the same picture rather than the same numbers.
///
/// The result is cached, because the background is the one layer that does not
/// change while the picture is being dragged around on top of it. That is also
/// why effects over the *whole page* are a separate job: there the picture
/// moves, so there is nothing to keep.
nonisolated enum EffectBaker {

    /// The finished page with its own effects laid over it — the picture, its
    /// annotations and all.
    ///
    /// Nothing is cached here, and that is the difference between the two
    /// layers rather than an omission: the background holds still while the
    /// picture is dragged about, so its bake is worth keeping, while a page
    /// that moves with every sample has nothing to keep. Each frame pays.
    static func page(_ effects: [Presentation.Effect], over rendered: CGImage) -> CGImage? {
        let active = EffectStack.page(effects)
        guard !active.isEmpty else { return nil }
        let width = rendered.width, height = rendered.height
        guard width > 0, height > 0,
              width <= maximumSide, height <= maximumSide else { return nil }

        counter.value += 1
        let extent = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let source = CIImage(cgImage: rendered)
        var image = source
        let shortSide = CGFloat(min(width, height))
        for recipe in active.map(Recipe.init) {
            image = apply(recipe, to: image, extent: extent, shortSide: shortSide)
        }
        image = keepingTheShapeOf(source, in: image, extent: extent)
        return ciContext.createCGImage(image.cropped(to: extent), from: extent)
    }

    /// The baked background, or nil when there is nothing to bake — no active
    /// effects, no background, or a degenerate size. A nil answer means "draw
    /// it the old way", which is what keeps an undecorated document on exactly
    /// the path it was on before effects existed.
    static func image(background: Presentation.Background,
                      effects: [Presentation.Effect],
                      pixelSize: CGSize) -> CGImage? {
        // Only what belongs to this layer. The panel keeps one list, and which
        // pass an effect lands in is the effect's own business.
        let active = EffectStack.background(effects)
        guard !active.isEmpty, background != .none else { return nil }
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())
        guard width > 0, height > 0,
              width <= maximumSide, height <= maximumSide else { return nil }

        let key = Key(background: background, effects: active.map(Recipe.init),
                      width: width, height: height)
        if let cached = cache.value(for: key) { return cached }
        guard let baked = bake(key) else { return nil }
        cache.store(baked, for: key)
        return baked
    }

    /// Guards against a pathological canvas asking for a bitmap nobody can
    /// hold. Above this the effect is simply not applied — a slow, swapping
    /// export is worse than a plain background.
    static let maximumSide = 12_000

    /// How many times the pixels were actually computed. The one honest way to
    /// prove in a test that an untouched document never reaches this file, and
    /// that a second identical request is served from the cache.
    static var bakeCount: Int { counter.value }

    static func resetBakeCount() { counter.value = 0 }

    // MARK: Baking

    private static func bake(_ key: Key) -> CGImage? {
        counter.value += 1
        guard let flat = paint(key) else { return nil }
        var image = CIImage(cgImage: flat)
        let extent = image.extent
        let shortSide = CGFloat(min(key.width, key.height))
        let source = image
        for recipe in key.effects {
            image = apply(recipe, to: image, extent: extent, shortSide: shortSide)
        }
        image = keepingTheShapeOf(source, in: image, extent: extent)
        return ciContext.createCGImage(image.cropped(to: extent), from: extent)
    }

    /// The background itself, drawn by the very routine that draws it on the
    /// canvas — a baked background that took its own path to the pixels could
    /// differ from the plain one for reasons nobody could see.
    ///
    /// The context is flipped into the renderer's top-left space first, exactly
    /// as the export bitmap is, so what comes back is oriented like everything
    /// else the renderer produces.
    private static func paint(_ key: Key) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: key.width, height: key.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(key.height))
        ctx.scaleBy(x: 1, y: -1)
        PresentationRenderer.drawBackground(
            key.background,
            in: CGRect(x: 0, y: 0, width: CGFloat(key.width), height: CGFloat(key.height)),
            ctx: ctx
        )
        return ctx.makeImage()
    }

    private static func apply(_ effect: Recipe, to image: CIImage,
                              extent: CGRect, shortSide: CGFloat) -> CIImage {
        switch effect.kind {
        case .grain:
            return grain(effect, over: image, extent: extent, shortSide: shortSide)
        case .dots, .grid, .stripes:
            return pattern(effect, over: image, extent: extent, shortSide: shortSide)
        case .vignette:
            return vignette(effect, over: image, extent: extent, shortSide: shortSide)
        case .pixelate:
            return pixelate(effect, over: image, extent: extent, shortSide: shortSide)
        case .dither:
            return dither(effect, over: image, extent: extent, shortSide: shortSide)
        case .halftone:
            return halftone(effect, over: image, extent: extent, shortSide: shortSide)
        case .fluted:
            return fluted(effect, over: image, extent: extent, shortSide: shortSide)
        case .glass:
            return glass(effect, over: image, extent: extent, shortSide: shortSide)
        case .lens:
            return lens(effect, over: image, extent: extent, shortSide: shortSide)
        case .ascii:
            return ascii(effect, over: image, extent: extent, shortSide: shortSide)
        }
    }

    /// Film grain: signed noise, added to the picture as light and taken away
    /// as shadow.
    ///
    /// The obvious spelling — grey noise in overlay blend — was shipped first
    /// and is wrong on light pages. Overlay preserves highlights by
    /// construction, so on a near-white background it has nothing to move:
    /// measured at a fifth of its strength there against a dark page, which
    /// reads as an effect that does not work.
    ///
    /// What lands instead is spelled out rather than delegated to a blend
    /// mode: the picture is darkened by the amplitude and twice the amplitude
    /// of noise is added back, so every pixel moves by `±swing` around where it
    /// was. Blend modes were tried first and each brought its own opinion about
    /// where the light should go — `linearLight` turned a dark page from 0.12
    /// to a mean of 0.35, which is a fog, not a grain.
    private static func grain(_ effect: Recipe, over image: CIImage,
                              extent: CGRect, shortSide: CGFloat) -> CIImage {
        // One noise pixel is `scale` of the short side, so the grain is the
        // same grain at any resolution.
        let pixel = max(1, (effect.scale * shortSide).rounded())
        // The seed moves the noise rather than reseeding it: CIRandomGenerator
        // takes no seed, and an unmoved noise would give every grain effect in
        // the app the same speckle in the same place.
        let offsetX = CGFloat(effect.seed % 4096)
        let offsetY = CGFloat((effect.seed / 4096) % 4096)
        // `samplingNearest` before the scaling, not after: it decides how the
        // *next* sampling reads the image, so asking afterwards leaves the
        // enlargement itself bilinear. That was measurable — grain at 800px
        // came out 28% weaker than the same grain at 200px, which is exactly
        // the smearing this prevents.
        let noise = CIFilter.randomGenerator().outputImage?
            .samplingNearest()
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .transformed(by: CGAffineTransform(scaleX: pixel, y: pixel))
            // The generator's alpha is random too, and colour is stored
            // premultiplied — so a speckle asked for a tenth of the range came
            // out at a third, and the picture washed out instead of grained.
            // Flattening the alpha first makes the numbers mean what they say.
            .settingAlphaOne(in: extent)
        guard let noise else { return image }

        // A sixth of the range either side at full strength: grain is a
        // disturbance of the light, and noise reaching the whole way is static,
        // not film.
        return light(noise, amplitude: effect.amount / 3, over: image, extent: extent)
    }

    /// The page's own silhouette, put back over whatever the effects did to it.
    ///
    /// An effect may change the colours of a page; it may not change its shape.
    /// Several of them would: everything built on `light` ends by forcing alpha
    /// to one, and the ASCII pass lays a veil over the whole rectangle — so on
    /// a transparent page (`Background.none`, whose whole promise is that PNG
    /// export carries the transparency through) a grain switched to the page
    /// layer came back with an opaque rectangle where the margins had been.
    /// Measured: corner alpha 0.00 on the background layer, 1.00 on the page.
    /// The mask is the page as it was drawn: `blendWithAlphaMask` reads only
    /// its alpha, which is precisely the shape being restored.
    private static func keepingTheShapeOf(_ source: CIImage, in image: CIImage,
                                          extent: CGRect) -> CIImage {
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty().cropped(to: extent)
        blend.maskImage = source
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// A field of light laid over the picture: the field's red channel is read
    /// as a level where ½ leaves the picture alone, 1 brightens it by
    /// `amplitude` and 0 darkens it by as much.
    ///
    /// Spelled out rather than delegated to a blend mode, because each blend
    /// mode brings its own opinion about where the light should go: `overlay`
    /// preserves highlights and so cannot be seen on a light page at all, and
    /// `linearLight` turned a dark page from 0.12 to a mean of 0.35 — a fog,
    /// not a grain.
    private static func light(_ field: CIImage, amplitude: CGFloat,
                              over image: CIImage, extent: CGRect) -> CIImage {
        guard amplitude > 0 else { return image }
        let levelled = CIFilter.colorMatrix()
        levelled.inputImage = field
        // Every channel reads the same one, so a coloured field becomes grey —
        // colour speckle reads as a broken screen, not as film.
        levelled.rVector = CIVector(x: amplitude * 2, y: 0, z: 0, w: 0)
        levelled.gVector = CIVector(x: amplitude * 2, y: 0, z: 0, w: 0)
        levelled.bVector = CIVector(x: amplitude * 2, y: 0, z: 0, w: 0)
        levelled.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        // Opaque, and that is the trap in this filter: colours are stored
        // premultiplied, so an image with zero alpha carries no colour either —
        // a "transparent" speckle contributes exactly nothing, and it took a
        // measurement reading 0.0000 on both a light and a dark page to see it.
        // What keeps the light gentle is its amplitude, not its opacity.
        levelled.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let added = levelled.outputImage?.cropped(to: extent) else { return image }

        let darkened = CIFilter.colorMatrix()
        darkened.inputImage = image
        darkened.biasVector = CIVector(x: -amplitude, y: -amplitude, z: -amplitude, w: 0)
        guard let base = darkened.outputImage?.cropped(to: extent) else { return image }

        let add = CIFilter.additionCompositing()
        add.inputImage = added
        add.backgroundImage = base
        // Alpha is put back to one, and this is not housekeeping: adding two
        // opaque images leaves an alpha of *two* inside the pipeline. It renders
        // the same, so nothing looks wrong — until a later filter rewrites the
        // alpha, at which point the premultiplied colour is divided by the two
        // it was stored against and every channel comes out at half. That is
        // exactly what happened to the lens: its aberration pass turned the
        // whole page grey.
        return add.outputImage?.cropped(to: extent).settingAlphaOne(in: extent) ?? image
    }

    /// A regular pattern — dots, a grid or stripes — laid over the background.
    ///
    /// Drawn with Core Graphics rather than assembled from generators: this is
    /// the one family that is *not* a filter, and a checkerboard generator bent
    /// into a dot grid would be harder to read than the four lines that draw
    /// the dots. It goes through the same chain as the rest so that an effect
    /// added after it still sees it.
    private static func pattern(_ effect: Recipe, over image: CIImage,
                                extent: CGRect, shortSide: CGFloat) -> CIImage {
        let step = max(2, (effect.scale * shortSide).rounded())
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        let ink = CGColor(red: effect.color.red, green: effect.color.green,
                          blue: effect.color.blue, alpha: effect.color.alpha * effect.amount)
        ctx.setFillColor(ink)
        ctx.setStrokeColor(ink)
        // The pattern turns around the middle, so the angle reads as a rotation
        // of the picture rather than as a slide across it.
        ctx.translateBy(x: extent.midX, y: extent.midY)
        ctx.rotate(by: effect.radians)
        // Long enough to still cover the corners once turned.
        let reach = hypot(extent.width, extent.height)
        let from = -reach / 2, to = reach / 2

        switch effect.kind {
        case .dots:
            let radius = max(0.5, step / 6)
            var y = from
            while y <= to {
                var x = from
                while x <= to {
                    ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
        case .grid, .stripes:
            ctx.setLineWidth(max(0.5, step / 12))
            var offset = from
            while offset <= to {
                ctx.move(to: CGPoint(x: from, y: offset))
                ctx.addLine(to: CGPoint(x: to, y: offset))
                if effect.kind == .grid {
                    ctx.move(to: CGPoint(x: offset, y: from))
                    ctx.addLine(to: CGPoint(x: offset, y: to))
                }
                offset += step
            }
            ctx.strokePath()
        default:
            return image
        }

        guard let drawn = ctx.makeImage() else { return image }
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = CIImage(cgImage: drawn)
        over.backgroundImage = image
        return over.outputImage ?? image
    }

    /// Darkening towards the edges. The radius is a fraction of the short side,
    /// like every other size here, so the same vignette closes in the same
    /// place at any resolution.
    private static func vignette(_ effect: Recipe, over image: CIImage,
                                 extent: CGRect, shortSide: CGFloat) -> CIImage {
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image.clampedToExtent()
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        // The whole fraction, not half of it. Every size in this file is a
        // fraction of the short side, and the panel prints it as pixels on that
        // basis — a quiet halving here made the field say 960 where the drawing
        // used 480, the same class of lie the angle told in radians.
        filter.radius = Float(effect.scale * shortSide)
        filter.intensity = Float(effect.amount)
        filter.falloff = 0.5
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// Square cells, big enough to be cells.
    ///
    /// Averaging alone is invisible on a gradient by construction: the mean of a
    /// smooth ramp over a cell is very nearly the ramp itself. So the cells are
    /// large by default — a twentieth of the short side, where the first version
    /// used a fiftieth — and the number of colours is a dial of its own rather
    /// than a hidden fudge. Fewer colours is what makes the grid show: whole
    /// cells land in the same band, and the edges between bands run along the
    /// cell boundaries.
    private static func pixelate(_ effect: Recipe, over image: CIImage,
                                 extent: CGRect, shortSide: CGFloat) -> CIImage {
        let filter = CIFilter.pixellate()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(max(2, effect.scale * shortSide))
        // From a corner, not from the middle: cells anchored at the centre
        // leave a half cell against two edges, which reads as a mistake.
        filter.center = .zero
        guard let blocks = filter.outputImage?.cropped(to: extent) else { return image }

        let levels = effect.detail.rounded()
        // The top of the range means "leave the colours alone" — a count high
        // enough that quantizing to it is invisible, which is a kinder way to
        // switch something off than a checkbox next to a slider.
        guard levels >= 2, levels < 32 else { return blocks }
        let posterize = CIFilter.colorPosterize()
        posterize.inputImage = blocks
        posterize.levels = Float(levels)
        return posterize.outputImage?.cropped(to: extent) ?? blocks
    }

    /// Ordered dithering: fewer colours, with a woven threshold pattern
    /// deciding which pixel rounds up and which rounds down.
    ///
    /// The first version used white noise and it was the wrong effect. A random
    /// threshold gives soft, cloudy banding; what people mean by "dither" is the
    /// *ordered* kind — a Bayer matrix repeating across the page, which is why
    /// the result has a weave to it and holds an edge. It is also the only kind
    /// that survives being scaled up: the pattern is a pattern, not a mist.
    private static func dither(_ effect: Recipe, over image: CIImage,
                               extent: CGRect, shortSide: CGFloat) -> CIImage {
        let levels = max(2, effect.detail.rounded())
        let cell = max(1, (effect.scale * shortSide).rounded())
        guard let matrix = bayerTile(cell: cell, extent: extent) else { return image }

        // Half a step either side: exactly enough for a pixel to be carried
        // across the nearest boundary, and no further — more would be noise on
        // top of the pattern rather than the pattern itself.
        let threshold = light(matrix, amplitude: 0.5 / levels, over: image, extent: extent)

        let posterize = CIFilter.colorPosterize()
        posterize.inputImage = threshold
        posterize.levels = Float(levels)
        guard let quantized = posterize.outputImage?.cropped(to: extent) else { return image }
        guard effect.amount < 1 else { return quantized }

        // Strength is a mix with the page as it was, so the dial goes all the
        // way down to nothing rather than to "eight colours instead of four".
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = quantized
        mix.time = Float(effect.amount)
        return mix.outputImage?.cropped(to: extent) ?? quantized
    }

    /// The 8×8 Bayer matrix, drawn once as a tiny image and tiled across the
    /// page with each cell blown up to `cell` pixels.
    ///
    /// Tiled rather than generated per pixel because Core Image has no ordered
    /// noise of its own and this file has no shader: an 8×8 image and an affine
    /// tile is the whole of it.
    private static func bayerTile(cell: CGFloat, extent: CGRect) -> CIImage? {
        guard let base = bayerImage else { return nil }
        let tile = CIImage(cgImage: base)
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
        return tile
            .applyingFilter("CIAffineTile", parameters: [
                kCIInputTransformKey: CGAffineTransform.identity
            ])
            .cropped(to: extent)
    }

    /// The classic 8×8 ordered-dither threshold map, as grey levels.
    private static let bayerImage: CGImage? = {
        let side = 8
        // Each entry is its position in the recursive Bayer ordering; dividing
        // by 64 turns the ordering into thresholds spread evenly over 0…1.
        let order: [Int] = [
             0, 32,  8, 40,  2, 34, 10, 42,
            48, 16, 56, 24, 50, 18, 58, 26,
            12, 44,  4, 36, 14, 46,  6, 38,
            60, 28, 52, 20, 62, 30, 54, 22,
             3, 35, 11, 43,  1, 33,  9, 41,
            51, 19, 59, 27, 49, 17, 57, 25,
            15, 47,  7, 39, 13, 45,  5, 37,
            63, 31, 55, 23, 61, 29, 53, 21
        ]
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0..<(side * side) {
            let value = UInt8((Double(order[index]) + 0.5) / 64 * 255)
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = 255
        }
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }()

    /// Print-style colour separation. Dramatic by nature, which is why its dot
    /// is the parameter people reach for first.
    ///
    /// The page is pulled down a little first, and that is not a flourish: a
    /// halftone prints ink where there is tone, so on a near-white page it
    /// prints almost nothing — measured at a seventh of its strength there,
    /// which on screen is a blank tile. Ink needs something to be made of.
    private static func halftone(_ effect: Recipe, over image: CIImage,
                                 extent: CGRect, shortSide: CGFloat) -> CIImage {
        let inked = CIFilter.colorMatrix()
        inked.inputImage = image
        let level = 1 - 0.35 * effect.amount
        inked.rVector = CIVector(x: level, y: 0, z: 0, w: 0)
        inked.gVector = CIVector(x: 0, y: level, z: 0, w: 0)
        inked.bVector = CIVector(x: 0, y: 0, z: level, w: 0)

        let filter = CIFilter.cmykHalftone()
        filter.inputImage = (inked.outputImage ?? image).clampedToExtent()
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.width = Float(max(2, effect.scale * shortSide))
        filter.angle = Float(effect.radians)
        filter.sharpness = Float(effect.amount)
        filter.grayComponentReplacement = 1
        filter.underColorRemoval = 0.5
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// Fluted glass: the page seen through vertical ribs, each one bending
    /// what is behind it.
    ///
    /// This is the glass people mean — the ribbed panel in a door — and it is a
    /// different effect from the frosted one below, not a stronger setting of
    /// it. Each rib shows a *stretched* slice of the page, so a smooth gradient
    /// breaks into bands that step at every rib: the effect that most needed
    /// texture underneath now makes its own.
    ///
    /// Drawn with Core Graphics because a rib is a piece of geometry, and
    /// geometry is what a drawing context is for: clip to the rib, draw the
    /// page magnified about the rib's middle, move on.
    private static func fluted(_ effect: Recipe, over image: CIImage,
                               extent: CGRect, shortSide: CGFloat) -> CIImage {
        let width = Int(extent.width), height = Int(extent.height)
        // The source reaches past the page by the amount a turned rib can see.
        // Ribs are clipped in a rotated frame, so at any angle but zero the
        // strips at the corners cover ground the page does not — and drawing
        // only the page there left the corners empty, as if the canvas ran out.
        let overhang = hypot(extent.width, extent.height) / 2 - min(extent.width, extent.height) / 2
        let reachRect = extent.insetBy(dx: -overhang, dy: -overhang)
        guard width > 0, height > 0,
              let source = ciContext.createCGImage(image.clampedToExtent(), from: reachRect),
              let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        let rib = max(2, (effect.scale * shortSide).rounded())
        // Long enough to still cover the corners once the ribs are turned.
        let reach = hypot(extent.width, extent.height)
        // How much of the page each rib gathers. At full strength a rib shows a
        // slice stretched to nearly three times its width, which is about what
        // a real flute does.
        let magnification = 1 + effect.amount * 2

        ctx.translateBy(x: extent.midX, y: extent.midY)
        ctx.rotate(by: effect.radians)
        ctx.interpolationQuality = .high

        var offset = -reach / 2
        while offset < reach / 2 {
            let centre = offset + rib / 2
            ctx.saveGState()
            ctx.clip(to: CGRect(x: offset, y: -reach / 2, width: rib, height: reach))
            ctx.saveGState()
            // The rib magnifies about its own middle, so what it shows is the
            // page immediately behind it — not a copy of the page's centre.
            ctx.translateBy(x: centre, y: 0)
            ctx.scaleBy(x: magnification, y: 1)
            ctx.translateBy(x: -centre, y: 0)
            // Back out of the rotation to draw the page the right way up.
            ctx.rotate(by: -effect.radians)
            ctx.translateBy(x: -extent.midX, y: -extent.midY)
            ctx.draw(source, in: reachRect)
            ctx.restoreGState()
            ctx.restoreGState()
            offset += rib
        }

        ctx.resetClip()
        // The relief: a dark seam where two ribs meet and a highlight just off
        // the middle, which is where a rib gathers the light. Without them the
        // ribs read as a cut-up picture rather than as glass.
        if effect.detail > 0, let seam = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(gray: 0, alpha: effect.detail * 0.55),
                     CGColor(gray: 1, alpha: effect.detail * 0.35),
                     CGColor(gray: 1, alpha: 0),
                     CGColor(gray: 0, alpha: effect.detail * 0.55)] as CFArray,
            locations: [0, 0.22, 0.6, 1]
        ) {
            var offset = -reach / 2
            while offset < reach / 2 {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: offset, y: -reach / 2, width: rib, height: reach))
                ctx.drawLinearGradient(
                    seam,
                    start: CGPoint(x: offset, y: 0),
                    end: CGPoint(x: offset + rib, y: 0),
                    options: []
                )
                ctx.restoreGState()
                offset += rib
            }
        }

        guard let drawn = ctx.makeImage() else { return image }
        return CIImage(cgImage: drawn)
    }

    /// Refraction through textured glass. `CIGlassDistortion` needs a texture
    /// to refract through, and blurred noise is the classic one: its blobs are
    /// what become the ripples, so the texture's coarseness *is* the size of
    /// the distortion.
    private static func glass(_ effect: Recipe, over image: CIImage,
                              extent: CGRect, shortSide: CGFloat) -> CIImage {
        let blobs = max(1, effect.scale * shortSide)
        // The noise is enlarged *before* it is blurred, and that is the whole
        // recipe: blurring one-pixel noise by the blob size averages it into a
        // flat grey, a texture with no slopes — and a glass with no slopes
        // refracts nothing. Measured: the first version ran the filter and
        // returned the picture untouched.
        guard let noise = CIFilter.randomGenerator().outputImage?
            .samplingNearest()
            .transformed(by: CGAffineTransform(translationX: CGFloat(effect.seed % 4096),
                                               y: CGFloat((effect.seed / 4096) % 4096)))
            .transformed(by: CGAffineTransform(scaleX: blobs, y: blobs))
            .settingAlphaOne(in: extent)
        else { return image }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = noise.cropped(to: extent).clampedToExtent()
        // Bumpiness is how sharply the glass was poured: a wide blur leaves a
        // fog with no slopes to refract through, a narrow one leaves facets.
        blur.radius = Float(max(1, blobs * (0.7 - 0.5 * effect.detail)))
        // Cropped, and that is not tidiness: an infinite texture asks Core
        // Image for an infinite render, which it answers with "memory
        // requirement of -1 too big" and a tile that never appears.
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }
        // Blurring flattens the field's contrast as well as its edges, and a
        // flat field refracts nothing — so the contrast is put back, the more
        // the bumpier.
        let sharpen = CIFilter.colorControls()
        sharpen.inputImage = blurred
        sharpen.contrast = Float(1 + effect.detail * 3)
        sharpen.brightness = 0
        sharpen.saturation = 0
        guard let texture = sharpen.outputImage?.cropped(to: extent) else { return image }

        // Displacement is a fraction of the page, not of the texture — tied to
        // the blob size it came out under two pixels at any sane setting. The
        // multiplier is large because this filter's `scale` is not a distance
        // in pixels: measured on a 400px tile, 24 moved the picture by about
        // half a byte per channel and 200 was the first setting anyone could
        // see.
        let displacement = effect.amount * shortSide * 0.5
        let filter = CIFilter.glassDistortion()
        filter.inputImage = image.clampedToExtent()
        filter.textureImage = texture
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.scale = Float(displacement)
        let refracted = filter.outputImage?.cropped(to: extent) ?? image

        let lit = light(texture, amplitude: effect.amount * 0.18,
                        over: refracted, extent: extent)
        // Thick glass splits the spectrum, and unlike the lens this pane has no
        // circle to keep the fringe in — the whole page is glass, so the
        // channels are simply slid apart. Refracting each channel separately
        // through the same texture was tried first and measured at half a byte
        // of difference at full strength: this filter's displacement barely
        // responds to a change in its scale, so three passes cost three times
        // the work for nothing anyone could see.
        return dispersed(lit, by: effect.aberration, extent: extent, shortSide: shortSide)
    }

    /// A lens over the middle of the page: positive bulges, negative pinches.
    /// One dial for both, because inward is the same gesture read backwards.
    private static func lens(_ effect: Recipe, over image: CIImage,
                             extent: CGRect, shortSide: CGFloat) -> CIImage {
        let radius = effect.scale * shortSide
        let filter = CIFilter.bumpDistortion()
        filter.inputImage = image.clampedToExtent()
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(radius)
        filter.scale = Float(effect.amount)
        let bulged = filter.outputImage?.cropped(to: extent) ?? image

        // A lens is not only a bend, it is a gathering of light — and on a
        // smooth page the bend has nothing to show, so the light is all there
        // is. Bright in the middle where it bulges, dark where it pinches.
        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: extent.midX, y: extent.midY)
        gradient.radius0 = 0
        gradient.radius1 = Float(radius)
        let bright = effect.amount >= 0
        gradient.color0 = CIColor(red: bright ? 1 : 0, green: bright ? 1 : 0,
                                  blue: bright ? 1 : 0)
        // Neutral outside the lens, so nothing beyond its edge is touched.
        gradient.color1 = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        guard let field = gradient.outputImage?.cropped(to: extent) else { return bulged }
        let lit = light(field, amplitude: abs(effect.amount) * 0.22,
                        over: bulged, extent: extent)

        // The colour fringe belongs to the lens, not to the page: spread across
        // the whole picture it puts a yellow rim along the frame, where the
        // channels run out of image to borrow. Masked to the lens it is what it
        // should be — colour spreading where the glass is.
        guard effect.aberration > 0,
              let spread = aberrated(lit, by: effect.aberration, extent: extent) as CIImage?,
              let mask = radialMask(centre: CGPoint(x: extent.midX, y: extent.midY),
                                    radius: radius, extent: extent)
        else { return lit }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = spread
        blend.backgroundImage = lit
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? lit
    }

    /// Chromatic dispersion by sliding the channels apart — red one way, blue
    /// the other, green where it was.
    ///
    /// A fraction of the page rather than a count of pixels, like every other
    /// size here, so the fringe is the same fringe in the preview and in the
    /// file.
    private static func dispersed(_ image: CIImage, by amount: CGFloat,
                                  extent: CGRect, shortSide: CGFloat) -> CIImage {
        guard amount > 0 else { return image }
        // Up to a sixtieth of the page at full strength: measured, a smaller
        // shift is a dial nobody can see moving, and a larger one stops being
        // glass and becomes a printing fault.
        let shift = amount * shortSide * 0.016

        func slid(_ dx: CGFloat, keeping vector: (CGFloat, CGFloat, CGFloat)) -> CIImage? {
            let moved = image
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                .clampedToExtent()
                .cropped(to: extent)
            return channel(moved, keeping: vector, extent: extent)
        }

        guard let red = slid(shift, keeping: (1, 0, 0)),
              let green = slid(0, keeping: (0, 1, 0)),
              let blue = slid(-shift, keeping: (0, 0, 1))
        else { return image }
        let first = CIFilter.maximumCompositing()
        first.inputImage = green
        first.backgroundImage = red
        let second = CIFilter.maximumCompositing()
        second.inputImage = blue
        second.backgroundImage = first.outputImage ?? red
        return second.outputImage?.cropped(to: extent) ?? image
    }

    /// One channel of an image, with the other two blanked — the piece a
    /// dispersion is assembled from.
    ///
    /// Opaque, always. Colour is stored premultiplied, so a channel image left
    /// transparent carries no colour at all and a composite keeps only the
    /// first of them — which turned a whole page red the first time this ran.
    private static func channel(_ image: CIImage,
                                keeping vector: (CGFloat, CGFloat, CGFloat),
                                extent: CGRect) -> CIImage? {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: vector.0, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: vector.1, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: vector.2, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return filter.outputImage?.cropped(to: extent)
    }

    /// White where the lens is, black beyond it — the shape of anything that
    /// should happen inside a circle and nowhere else.
    private static func radialMask(centre: CGPoint, radius: CGFloat,
                                   extent: CGRect) -> CIImage? {
        let gradient = CIFilter.radialGradient()
        gradient.center = centre
        gradient.radius0 = Float(radius * 0.2)
        gradient.radius1 = Float(radius)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0)
        return gradient.outputImage?.cropped(to: extent)
    }

    /// Chromatic aberration: the red and blue channels take slightly different
    /// paths through the lens, exactly as they do through glass.
    ///
    /// This is what Pryzm files under Optics, and it is what makes a lens read
    /// as a lens: a bulge on a smooth page moves colours nobody can tell apart,
    /// while a colour fringe is visible on any page at all — it *is* colour,
    /// not displacement.
    private static func aberrated(_ image: CIImage, by amount: CGFloat,
                                  extent: CGRect) -> CIImage {
        guard amount > 0 else { return image }
        // A few per cent of the page at most: beyond that it stops looking like
        // a lens and starts looking like a printing fault.
        let spread = amount * 0.02

        func scaled(_ scale: CGFloat) -> CIImage {
            image
                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -extent.midX, y: -extent.midY))
                .clampedToExtent()
                .cropped(to: extent)
        }

        // Red spreads outward, blue falls inward, green stays where it is —
        // the ordering of the spectrum through a simple lens.
        guard let red = channel(scaled(1 + spread), keeping: (1, 0, 0), extent: extent),
              let green = channel(scaled(1), keeping: (0, 1, 0), extent: extent),
              let blue = channel(scaled(1 - spread), keeping: (0, 0, 1), extent: extent)
        else { return image }

        // Maximum, not addition. Each of the three carries one channel and
        // zeros elsewhere, so taking the larger value per channel reassembles
        // the colour exactly — while adding them halved every channel, because
        // compositing does its arithmetic on premultiplied colour and then
        // divides by an alpha that summed past one.
        let first = CIFilter.maximumCompositing()
        first.inputImage = green
        first.backgroundImage = red
        let second = CIFilter.maximumCompositing()
        second.inputImage = blue
        second.backgroundImage = first.outputImage ?? red
        return second.outputImage?.cropped(to: extent) ?? image
    }

    /// The page read as characters: one letter per cell, chosen by how bright
    /// that cell is and painted in that cell's own colour.
    ///
    /// Drawn with Core Text rather than computed by a shader, and that was a
    /// finding rather than a preference. The Metal-kernel route (a `CIKernel`
    /// in Metal Shading Language) needs a Metal toolchain this machine does not
    /// have — `cannot execute tool 'metal' due to missing Metal Toolchain` —
    /// and adding that dependency for one effect would put the same
    /// requirement on CI. Letters drawn as letters also spares the shader a
    /// font atlas, which is the only honest way for a kernel to draw text.
    ///
    /// Two things learned from Pryzm's own ASCII pass, which offers "Color:
    /// Luma / RGB" and a separate cell height. Letters in **one flat colour**
    /// throw the page's colours away, and what makes terminal art read as a
    /// picture is that each glyph keeps the colour of what it stands for. And
    /// square cells squash that picture, because characters are half again as
    /// tall as they are wide.
    ///
    /// The cell's colour comes from a copy of the picture scaled down to one
    /// pixel per cell, which is the same averaging a shader would do by
    /// sampling, done once instead of per pixel.
    private static func ascii(_ effect: Recipe, over image: CIImage,
                              extent: CGRect, shortSide: CGFloat) -> CIImage {
        let cellWidth = max(3, (effect.scale * shortSide).rounded())
        let cellHeight = max(4, (cellWidth * max(0.5, effect.detail)).rounded())
        let columns = max(1, Int(extent.width / cellWidth))
        let rows = max(1, Int(extent.height / cellHeight))
        guard let cells = cellColors(of: image, extent: extent,
                                     columns: columns, rows: rows),
              let ctx = CGContext(
                data: nil, width: Int(extent.width), height: Int(extent.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        // Darkening first, and by how much is now a dial rather than a
        // constant: characters on a picture that still shows through read as a
        // caption over it, not as a picture made of characters — but a page
        // blacked out at a fixed 85% could never be the gentle version.
        ctx.setFillColor(CGColor(gray: 0, alpha: effect.amount * 0.9))
        ctx.fill(CGRect(origin: .zero, size: extent.size))

        // The point size is worked back from the font's *measured* advance, so
        // one glyph is exactly one cell wide. Guessing it (six tenths of the
        // point size) was close enough for letters and wrong for blocks, whose
        // ink is a full line box — 1.7 times the advance — and they ran into
        // each other.
        let font = CTFontCreateWithName("Menlo" as CFString,
                                        cellWidth / max(0.1, advanceRatio), nil)
        // Where the line sits inside the cell: the ink of a capital, centred,
        // with the baseline pushed down by the descender it stands on.
        let inkHeight = CTFontGetCapHeight(font)
        let descender = CTFontGetDescent(font) * 0.25
        for row in 0..<rows {
            for column in 0..<columns {
                let cell = cells[row * columns + column]
                let ramp = effect.glyphs.characters
                let character = ramp[min(ramp.count - 1,
                                         Int(cell.level * CGFloat(ramp.count)))]
                guard character != " " else { continue }
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: cell.ink
                ]
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
                    nil, String(character) as CFString, attributes as CFDictionary
                ))
                // Row 0 is the top of the picture, and this context counts from
                // the bottom — the same flip the baked background goes through.
                let box = CGRect(x: CGFloat(column) * cellWidth,
                                 y: extent.height - CGFloat(row + 1) * cellHeight,
                                 width: cellWidth, height: cellHeight)
                ctx.saveGState()
                // Clipped to its own cell, always. A block glyph is taller than
                // the cell it belongs to by design, and without this it spills
                // into the rows above and below — which is how a page of
                // characters turned into porridge.
                ctx.clip(to: box)
                ctx.textPosition = CGPoint(x: box.minX,
                                           y: box.minY + (cellHeight - inkHeight) / 2
                                              + descender)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        guard let drawn = ctx.makeImage() else { return image }
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = CIImage(cgImage: drawn)
        over.backgroundImage = image
        return over.outputImage ?? image
    }

    /// How wide one character is against its point size, measured once from
    /// the font itself rather than assumed. Monospaced by definition, so any
    /// glyph answers for all of them.
    static let advanceRatio: CGFloat = {
        let font = CTFontCreateWithName("Menlo" as CFString, 100, nil)
        var utf16 = Array("0".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        guard CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, 1) else { return 0.6 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
        return advance.width > 0 ? advance.width / 100 : 0.6
    }()

    /// One brightness *and one colour* per cell, from a copy of the picture
    /// scaled to exactly that many pixels. Lanczos rather than a plain draw: it
    /// averages the whole cell instead of taking whatever pixel lands under the
    /// sample.
    private static func cellColors(of image: CIImage, extent: CGRect,
                                   columns: Int, rows: Int)
        -> [(level: CGFloat, ink: CGColor)]? {
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = Float(CGFloat(rows) / extent.height)
        scale.aspectRatio = Float((CGFloat(columns) / extent.width)
                                  / (CGFloat(rows) / extent.height))
        guard let small = scale.outputImage,
              let cg = ciContext.createCGImage(
                small, from: CGRect(x: 0, y: 0, width: columns, height: rows))
        else { return nil }

        var raw = [UInt8](repeating: 0, count: columns * rows * 4)
        raw.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: columns, height: rows,
                                bitsPerComponent: 8, bytesPerRow: columns * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }

        let colors = (0..<(columns * rows)).map { index -> (CGFloat, CGFloat, CGFloat, CGFloat) in
            let red = CGFloat(raw[index * 4]) / 255
            let green = CGFloat(raw[index * 4 + 1]) / 255
            let blue = CGFloat(raw[index * 4 + 2]) / 255
            return (red, green, blue, 0.299 * red + 0.587 * green + 0.114 * blue)
        }
        // Stretched to the range the picture actually uses. A gradient lives
        // between 0.4 and 0.6, and without this the ramp of ten characters is
        // spent on two of them — measured, and it looked like a grid of plus
        // signs.
        let levels = colors.map(\.3)
        let low = levels.min() ?? 0, high = levels.max() ?? 1
        let span = high - low

        return colors.map { red, green, blue, level in
            let stretched = span > 0.01 ? (level - low) / span : level
            // The letter keeps the cell's hue and is lifted to a brightness
            // that reads against the darkened page: colour alone would leave
            // half the picture in letters nobody can see.
            let lift = max(1, 0.9 / max(0.08, level))
            let ink = CGColor(red: min(1, red * lift), green: min(1, green * lift),
                              blue: min(1, blue * lift), alpha: 1)
            return (stretched, ink)
        }
    }

    // MARK: Plumbing

    /// An effect stripped to what changes pixels.
    ///
    /// Identity and the on/off switch are the list's business, not the
    /// picture's: two grains with the same numbers make the same bitmap, so
    /// keying the cache on the whole effect would bake it twice for no visible
    /// difference — which is what happened the first time this was measured.
    private struct Recipe: Hashable {
        let kind: Presentation.Effect.Kind
        let amount: CGFloat
        let scale: CGFloat
        let angleInDegrees: CGFloat
        let color: Presentation.Color
        let detail: CGFloat
        let aberration: CGFloat
        let glyphs: Presentation.Effect.GlyphSet
        let seed: UInt32

        /// What the drawing routines want, from what the panel shows.
        var radians: CGFloat { angleInDegrees * .pi / 180 }

        init(_ effect: Presentation.Effect) {
            kind = effect.kind
            amount = effect.amount
            scale = effect.scale
            angleInDegrees = effect.angleInDegrees
            color = effect.color
            detail = effect.detail
            aberration = effect.aberration
            glyphs = effect.glyphs
            seed = effect.seed
        }
    }

    private struct Key: Hashable {
        let background: Presentation.Background
        let effects: [Recipe]
        let width: Int
        let height: Int
    }

    /// Last-used-first, and measured in **pixels rather than entries**.
    ///
    /// Counting entries was wrong the moment the panel grew a grid: eight slots
    /// against twelve tiles meant opening the picker evicted the canvas's own
    /// full-size bake — the expensive one — while none of the tiles ever hit
    /// either. A budget in pixels keeps whole rooms of tiny tiles for the price
    /// of a corner of one canvas, and still refuses to hold a heap of
    /// full-resolution pages.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: Key, image: CGImage)] = []
        /// Sixteen megapixels, about sixty megabytes: room for a 4K page and a
        /// preview of it, or for hundreds of tiles.
        private let budget = 16_000_000

        func value(for key: Key) -> CGImage? {
            lock.lock(); defer { lock.unlock() }
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.image
        }

        func store(_ image: CGImage, for key: Key) {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll { $0.key == key }
            entries.append((key, image))
            // The newest entry always stays, however big it is: dropping the
            // thing just asked for would mean baking it again immediately.
            var total = entries.reduce(0) { $0 + $1.image.width * $1.image.height }
            while entries.count > 1, total > budget {
                total -= entries[0].image.width * entries[0].image.height
                entries.removeFirst()
            }
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            entries.removeAll()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            get { lock.lock(); defer { lock.unlock() }; return count }
            set { lock.lock(); defer { lock.unlock() }; count = newValue }
        }
    }

    private static let cache = Cache()
    private static let counter = Counter()

    /// Tests only: makes a cache miss reproducible.
    static func emptyCache() { cache.removeAll() }

    /// GPU-backed, and shared for the same reason `AnnotationRenderer` shares
    /// its own: a `CIContext` per call spends more time being built than the
    /// filter spends running.
    ///
    /// **Colour management off.** By default Core Image converts everything
    /// into linear light, where a fixed change is enormous near black and
    /// invisible near white — the same grain measured ten times stronger on a
    /// dark page than on a light one, and pattern ink five times. Effects are
    /// about how a page *looks*, so the filters work directly on the sRGB
    /// numbers that were painted, and what a filter says it does is what the
    /// pixels get. Every constant here is written for that space.
    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: NSNull()
    ])
}
