import CoreGraphics
import CoreImage
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
        }
    }

    /// Film grain: grey noise laid over the background in overlay blend.
    ///
    /// Overlay rather than a plain composite because grain is a *disturbance of
    /// the light*, not a layer of dots — it must darken and lighten around the
    /// midpoint, leaving the colour underneath recognisable. Mixing the noise
    /// toward mid-grey is what turns strength into a dial: at 0 the overlay is
    /// flat grey, which is the identity for this blend, so the background comes
    /// through untouched.
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
        guard let noise else { return image }

        let grey = CIFilter.colorMatrix()
        grey.inputImage = noise
        // Every channel reads the same one, so coloured noise becomes grey —
        // colour speckle reads as a broken screen, not as film.
        let weight = Float(effect.amount)
        let bias = Float(0.5 * (1 - effect.amount))
        grey.rVector = CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0)
        grey.gVector = CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0)
        grey.bVector = CIVector(x: CGFloat(weight), y: 0, z: 0, w: 0)
        grey.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        grey.biasVector = CIVector(x: CGFloat(bias), y: CGFloat(bias),
                                   z: CGFloat(bias), w: 1)
        guard let overlay = grey.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = overlay
        blend.backgroundImage = image
        return blend.outputImage ?? image
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
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
}
