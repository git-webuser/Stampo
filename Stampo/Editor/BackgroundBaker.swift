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
nonisolated enum BackgroundBaker {

    /// The baked background, or nil when there is nothing to bake — no active
    /// effects, no background, or a degenerate size. A nil answer means "draw
    /// it the old way", which is what keeps an undecorated document on exactly
    /// the path it was on before effects existed.
    static func image(background: Presentation.Background,
                      effects: [Presentation.Effect],
                      pixelSize: CGSize) -> CGImage? {
        let active = EffectStack.active(effects)
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
        for recipe in key.effects {
            image = apply(recipe, to: image, extent: extent, shortSide: shortSide)
        }
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
        let swing = effect.amount / 3

        let grey = CIFilter.colorMatrix()
        grey.inputImage = noise
        // Every channel reads the same one, so coloured noise becomes grey —
        // colour speckle reads as a broken screen, not as film.
        grey.rVector = CIVector(x: swing * 2, y: 0, z: 0, w: 0)
        grey.gVector = CIVector(x: swing * 2, y: 0, z: 0, w: 0)
        grey.bVector = CIVector(x: swing * 2, y: 0, z: 0, w: 0)
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        // Opaque, and that is the trap in this filter: colours are stored
        // premultiplied, so an image with zero alpha carries no colour either —
        // a "transparent" speckle contributes exactly nothing, and it took a
        // measurement reading 0.0000 on both a light and a dark page to see it.
        // What keeps the noise gentle is its amplitude, not its opacity.
        grey.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let speckle = grey.outputImage?.cropped(to: extent) else { return image }

        let darkened = CIFilter.colorMatrix()
        darkened.inputImage = image
        darkened.biasVector = CIVector(x: -swing, y: -swing, z: -swing, w: 0)
        guard let base = darkened.outputImage?.cropped(to: extent) else { return image }

        let add = CIFilter.additionCompositing()
        add.inputImage = speckle
        add.backgroundImage = base
        return add.outputImage?.cropped(to: extent) ?? image
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
        ctx.rotate(by: effect.angle)
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
        filter.radius = Float(effect.scale * shortSide / 2)
        filter.intensity = Float(effect.amount)
        filter.falloff = 0.5
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    private static func pixelate(_ effect: Recipe, over image: CIImage,
                                 extent: CGRect, shortSide: CGFloat) -> CIImage {
        let filter = CIFilter.pixellate()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(max(2, effect.scale * shortSide))
        // From a corner, not from the middle: cells anchored at the centre
        // leave a half cell against two edges, which reads as a mistake.
        filter.center = .zero
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// Ordered noise, then fewer colours — which is what dithering looks like.
    ///
    /// `CIDither` alone was measured and rejected: it exists to *hide* banding,
    /// so at any setting it is nearly invisible on a gradient, and an effect
    /// nobody can see is an effect that looks broken. Posterizing after the
    /// noise gives the banded, speckled look the name promises, and strength
    /// decides how few colours are left.
    private static func dither(_ effect: Recipe, over image: CIImage,
                               extent: CGRect, shortSide: CGFloat) -> CIImage {
        let cell = max(1, (effect.scale * shortSide).rounded())
        let noise = CIFilter.randomGenerator().outputImage?
            .samplingNearest()
            .transformed(by: CGAffineTransform(translationX: CGFloat(effect.seed % 4096),
                                               y: CGFloat((effect.seed / 4096) % 4096)))
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .settingAlphaOne(in: extent)
        var speckled = image
        if let noise {
            let grey = CIFilter.colorMatrix()
            grey.inputImage = noise
            // A full step between levels, so the noise reaches across a band
            // boundary and breaks it. Half a step was measured first and left
            // the bands perfectly clean — posterizing, not dithering.
            let weight = CGFloat(1.2 / max(2, levels(effect.amount)))
            grey.rVector = CIVector(x: weight, y: 0, z: 0, w: 0)
            grey.gVector = CIVector(x: weight, y: 0, z: 0, w: 0)
            grey.bVector = CIVector(x: weight, y: 0, z: 0, w: 0)
            grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            // Alpha stays at zero: the noise is *light added* to the picture,
            // and an opaque noise added to an opaque background saturates every
            // channel at once — which turned a gradient into confetti the first
            // time this was rendered.
            grey.biasVector = CIVector(x: -weight / 2, y: -weight / 2, z: -weight / 2, w: 0)
            if let overlay = grey.outputImage?.cropped(to: extent) {
                let add = CIFilter.additionCompositing()
                add.inputImage = overlay
                add.backgroundImage = image
                speckled = add.outputImage ?? image
            }
        }
        let posterize = CIFilter.colorPosterize()
        posterize.inputImage = speckled
        posterize.levels = Float(levels(effect.amount))
        return posterize.outputImage?.cropped(to: extent) ?? speckled
    }

    /// Strength read backwards: the harder you push, the fewer colours are
    /// left. Sixteen levels is already a visible banding on a gradient; two is
    /// the extreme.
    private static func levels(_ amount: CGFloat) -> CGFloat {
        (16 - 14 * min(1, max(0, amount))).rounded()
    }

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
        filter.angle = Float(effect.angle)
        filter.sharpness = Float(effect.amount)
        filter.grayComponentReplacement = 1
        filter.underColorRemoval = 0.5
        return filter.outputImage?.cropped(to: extent) ?? image
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
        blur.radius = Float(max(1, blobs / 2))
        // Cropped, and that is not tidiness: an infinite texture asks Core
        // Image for an infinite render, which it answers with "memory
        // requirement of -1 too big" and a tile that never appears.
        guard let texture = blur.outputImage?.cropped(to: extent) else { return image }

        let filter = CIFilter.glassDistortion()
        filter.inputImage = image.clampedToExtent()
        filter.textureImage = texture
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        // Displacement is a fraction of the page, not of the texture — tied to
        // the blob size it came out under two pixels at any sane setting. The
        // multiplier is large because this filter's `scale` is not a distance
        // in pixels: measured on a 400px tile, 24 moved the picture by about
        // half a byte per channel and 200 was the first setting anyone could
        // see.
        filter.scale = Float(effect.amount * shortSide * 0.5)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// A lens over the middle of the page: positive bulges, negative pinches.
    /// One dial for both, because inward is the same gesture read backwards.
    private static func lens(_ effect: Recipe, over image: CIImage,
                             extent: CGRect, shortSide: CGFloat) -> CIImage {
        let filter = CIFilter.bumpDistortion()
        filter.inputImage = image.clampedToExtent()
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(effect.scale * shortSide / 2)
        filter.scale = Float(effect.amount)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// The page read as characters: one letter per cell, chosen by how bright
    /// that cell is.
    ///
    /// Drawn with Core Text rather than computed by a shader, and that was a
    /// finding rather than a preference. The Metal-kernel route (a `CIKernel`
    /// in Metal Shading Language) needs a Metal toolchain this machine does not
    /// have — `cannot execute tool 'metal' due to missing Metal Toolchain` —
    /// and adding that dependency for one effect would put the same
    /// requirement on CI. Letters drawn as letters also spares the shader a
    /// font atlas, which is the only honest way for a kernel to draw text.
    ///
    /// The cell's brightness comes from a copy of the picture scaled down to
    /// one pixel per cell, which is the same averaging a shader would do by
    /// sampling, done once instead of per pixel.
    private static func ascii(_ effect: Recipe, over image: CIImage,
                              extent: CGRect, shortSide: CGFloat) -> CIImage {
        let cell = max(4, (effect.scale * shortSide).rounded())
        let columns = max(1, Int(extent.width / cell))
        let rows = max(1, Int(extent.height / cell))
        guard let brightness = luminance(of: image, extent: extent,
                                         columns: columns, rows: rows),
              let ctx = CGContext(
                data: nil, width: Int(extent.width), height: Int(extent.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        // Darkening first: characters on a picture that still shows through
        // read as a caption over it, not as a picture made of characters.
        ctx.setFillColor(CGColor(gray: 0, alpha: effect.amount * 0.85))
        ctx.fill(CGRect(origin: .zero, size: extent.size))

        let font = CTFontCreateWithName("Menlo" as CFString, cell, nil)
        let ink = CGColor(red: effect.color.red, green: effect.color.green,
                          blue: effect.color.blue, alpha: effect.color.alpha)
        for row in 0..<rows {
            for column in 0..<columns {
                let level = brightness[row * columns + column]
                let character = ramp[min(ramp.count - 1, Int(level * CGFloat(ramp.count)))]
                guard character != " " else { continue }
                // CoreText's own attribute names, not AppKit's: this file draws
                // in a detached render and has no business importing AppKit.
                let attributes: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: ink
                ]
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
                    nil, String(character) as CFString, attributes as CFDictionary
                ))
                // Row 0 is the top of the picture, and this context counts from
                // the bottom — the same flip the baked background goes through.
                ctx.textPosition = CGPoint(x: CGFloat(column) * cell + cell * 0.1,
                                           y: extent.height - CGFloat(row + 1) * cell + cell * 0.2)
                CTLineDraw(line, ctx)
            }
        }

        guard let drawn = ctx.makeImage() else { return image }
        let over = CIFilter.sourceOverCompositing()
        over.inputImage = CIImage(cgImage: drawn)
        over.backgroundImage = image
        return over.outputImage ?? image
    }

    /// Darkest character first, so a cell's brightness is an index into it.
    /// The blank at the end is what gives the picture its highlights: an ASCII
    /// picture with no empty cells is a solid block of ink.
    private static let ramp: [Character] = Array("@%#*+=-:. ")

    /// One brightness per cell, from a copy of the picture scaled to exactly
    /// that many pixels. Lanczos rather than a plain draw: it averages the
    /// whole cell instead of taking whatever pixel lands under the sample.
    private static func luminance(of image: CIImage, extent: CGRect,
                                  columns: Int, rows: Int) -> [CGFloat]? {
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
        let levels = (0..<(columns * rows)).map { index -> CGFloat in
            let red = CGFloat(raw[index * 4]) / 255
            let green = CGFloat(raw[index * 4 + 1]) / 255
            let blue = CGFloat(raw[index * 4 + 2]) / 255
            return 0.299 * red + 0.587 * green + 0.114 * blue
        }
        // Stretched to the range the picture actually uses. A gradient spends
        // its whole life between 0.4 and 0.6, so without this the ramp of ten
        // characters is spent on two of them — measured, and it looked like a
        // grid of plus signs.
        let low = levels.min() ?? 0, high = levels.max() ?? 1
        guard high - low > 0.01 else { return levels }
        return levels.map { ($0 - low) / (high - low) }
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
        let angle: CGFloat
        let color: Presentation.Color
        let seed: UInt32

        init(_ effect: Presentation.Effect) {
            kind = effect.kind
            amount = effect.amount
            scale = effect.scale
            angle = effect.angle
            color = effect.color
            seed = effect.seed
        }
    }

    private struct Key: Hashable {
        let background: Presentation.Background
        let effects: [Recipe]
        let width: Int
        let height: Int
    }

    /// Small and last-used-first. Eight is enough for the canvas, the export
    /// and a screenful of preview tiles at once; more would keep whole
    /// backgrounds alive for a panel nobody is looking at any more.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(key: Key, image: CGImage)] = []
        private let limit = 8

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
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
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
