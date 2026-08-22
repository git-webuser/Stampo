import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// The baked background: that it is only baked when it has to be, that the same
/// request is not baked twice, and — the one that matters most — that the same
/// stack is the same picture at the resolution of the preview and at the
/// resolution of the file.
///
/// Serialized because the cache and the bake counter are shared by the whole
/// app, which is exactly the property being tested.
@MainActor @Suite(.serialized) struct BackgroundBakerTests {

    private let grey = Presentation.Background.solid(
        Presentation.Color(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    )

    private func grain(amount: CGFloat = 0.6, scale: CGFloat = 0.004,
                       seed: UInt32 = 7) -> Presentation.Effect {
        var effect = EffectStack.make(.grain, seed: seed)
        effect.amount = amount
        effect.scale = scale
        return effect
    }

    private func fresh() {
        BackgroundBaker.emptyCache()
        BackgroundBaker.resetBakeCount()
    }

    /// Nothing to apply means nothing is computed — the old path, untouched.
    /// This is the regression guard for every document that never opens the
    /// effects section.
    @Test func anEmptyStackNeverBakes() {
        fresh()
        var off = grain()
        off.isEnabled = false
        #expect(BackgroundBaker.image(background: grey, effects: [],
                                      pixelSize: CGSize(width: 40, height: 40)) == nil)
        #expect(BackgroundBaker.image(background: grey, effects: [off],
                                      pixelSize: CGSize(width: 40, height: 40)) == nil)
        // A transparent page has no pixels to disturb.
        #expect(BackgroundBaker.image(background: .none, effects: [grain()],
                                      pixelSize: CGSize(width: 40, height: 40)) == nil)
        #expect(BackgroundBaker.bakeCount == 0)
    }

    @Test func theSameRequestIsBakedOnceAndThenRemembered() {
        fresh()
        let size = CGSize(width: 80, height: 60)
        let first = BackgroundBaker.image(background: grey, effects: [grain()], pixelSize: size)
        let second = BackgroundBaker.image(background: grey, effects: [grain()], pixelSize: size)
        #expect(first != nil)
        #expect(BackgroundBaker.bakeCount == 1)
        #expect(first === second)
    }

    @Test func changingAnythingMissesTheCache() {
        fresh()
        let size = CGSize(width: 80, height: 60)
        _ = BackgroundBaker.image(background: grey, effects: [grain()], pixelSize: size)
        _ = BackgroundBaker.image(background: grey, effects: [grain(amount: 0.2)], pixelSize: size)
        _ = BackgroundBaker.image(background: grey, effects: [grain(scale: 0.008)], pixelSize: size)
        _ = BackgroundBaker.image(background: .solid(.white), effects: [grain()], pixelSize: size)
        _ = BackgroundBaker.image(background: grey, effects: [grain()],
                                  pixelSize: CGSize(width: 81, height: 60))
        #expect(BackgroundBaker.bakeCount == 5)
    }

    @Test func grainDisturbsTheBackgroundAndStrengthDecidesHowMuch() {
        fresh()
        let size = CGSize(width: 120, height: 120)
        let weak = BackgroundBaker.image(background: grey, effects: [grain(amount: 0.1)],
                                         pixelSize: size)
        let strong = BackgroundBaker.image(background: grey, effects: [grain(amount: 0.9)],
                                           pixelSize: size)
        #expect(spread(of: weak) > 0.001)                 // it is doing something
        #expect(spread(of: strong) > spread(of: weak) * 2) // and the dial means something
    }

    /// The seed is what makes the noise in the preview and the noise in the
    /// exported file the same noise. Without it the two would shimmer apart and
    /// nobody could tell which one the file had.
    @Test func theSeedFixesTheNoise() {
        fresh()
        let size = CGSize(width: 60, height: 60)
        let once = BackgroundBaker.image(background: grey, effects: [grain(seed: 3)],
                                         pixelSize: size)
        BackgroundBaker.emptyCache()
        let again = BackgroundBaker.image(background: grey, effects: [grain(seed: 3)],
                                          pixelSize: size)
        let other = BackgroundBaker.image(background: grey, effects: [grain(seed: 4)],
                                          pixelSize: size)
        #expect(bytes(of: once) == bytes(of: again))
        #expect(bytes(of: once) != bytes(of: other))
    }

    /// The whole point of measuring sizes in fractions of the short side: the
    /// canvas bakes at screen pixels and the export at the file's, and the
    /// grain has to read the same in both. Coarse grain at 200px and at 800px
    /// carries the same amount of disturbance — it would not if the size were
    /// in pixels, where four times the resolution is four times finer.
    @Test func theSameStackIsTheSameGrainAtAnyResolution() {
        fresh()
        let small = BackgroundBaker.image(background: grey, effects: [grain()],
                                          pixelSize: CGSize(width: 200, height: 200))
        let large = BackgroundBaker.image(background: grey, effects: [grain()],
                                          pixelSize: CGSize(width: 800, height: 800))
        let ratio = spread(of: large) / max(spread(of: small), 0.0001)
        #expect(ratio > 0.75 && ratio < 1.35,
                "grain energy moved by \(ratio)× between 200px and 800px")
    }

    /// A canvas nobody can hold is drawn plainly rather than slowly.
    @Test func anImpossibleSizeIsRefusedRatherThanAttempted() {
        fresh()
        #expect(BackgroundBaker.image(background: grey, effects: [grain()],
                                      pixelSize: CGSize(width: 0, height: 100)) == nil)
        #expect(BackgroundBaker.image(
            background: grey, effects: [grain()],
            pixelSize: CGSize(width: CGFloat(BackgroundBaker.maximumSide + 1), height: 100)
        ) == nil)
        #expect(BackgroundBaker.bakeCount == 0)
    }

    /// Every kind has to be visible at its own default, and this is the test
    /// that would have caught three that were not: glass refracted by half a
    /// byte, dither posterized without a speckle, and a grain that lost a
    /// quarter of its strength at high resolution.
    ///
    /// The ones that *bend* the picture are measured over a texture, because a
    /// smooth gradient has nothing to bend — that is a property of distortion,
    /// not a shortcoming of the effect.
    @Test func everyKindChangesThePictureAtItsDefault() {
        for kind in Presentation.Effect.Kind.allCases {
            let needsTexture = ![Presentation.Effect.Kind.dots, .grid, .stripes].contains(kind)
            let under: [Presentation.Effect] = needsTexture
                ? [EffectStack.make(.dots, seed: 5)] : []
            let size = CGSize(width: 300, height: 300)
            BackgroundBaker.emptyCache()
            let before = under.isEmpty
                ? plainPixels(size)
                : bytes(of: BackgroundBaker.image(background: ramp, effects: under, pixelSize: size))
            let after = bytes(of: BackgroundBaker.image(background: ramp,
                                                       effects: under + [EffectStack.make(kind, seed: 5)],
                                                       pixelSize: size))
            #expect(distance(before, after) > 0.75,
                    "\(kind) at its default barely changes anything")
        }
    }

    // MARK: Through the renderer

    /// The size is never passed in: it is read from the context, so the canvas
    /// asks for screen pixels and the export for the file's without either
    /// knowing which it is. Here a context scaled by ½ — what the live canvas
    /// installs — is handed a 200pt rect and must bake 100 pixels.
    @Test func theResolutionComesFromTheContext() {
        fresh()
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 0.5, y: 0.5)
        PresentationRenderer.drawBackground(grey, effects: [grain()],
                                            in: CGRect(x: 0, y: 0, width: 200, height: 200),
                                            ctx: ctx)
        #expect(BackgroundBaker.bakeCount == 1)
        #expect(spread(of: ctx.makeImage()) > 0.001)

        // And the same background at the same device size is not baked again,
        // which is what keeps a dragged picture smooth.
        PresentationRenderer.drawBackground(grey, effects: [grain()],
                                            in: CGRect(x: 0, y: 0, width: 200, height: 200),
                                            ctx: ctx)
        #expect(BackgroundBaker.bakeCount == 1)
    }

    /// The export path, end to end: what the panel promises has to reach the
    /// file, and the file is rendered by the same routine the canvas draws
    /// with.
    @Test func theEffectReachesTheExportedFile() {
        fresh()
        let source = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 20, height: 20))

        var presentation = Presentation.identity
        presentation.canvas = .auto(margins: Presentation.Margins(top: 60, leading: 60,
                                                                  bottom: 60, trailing: 60),
                                    scale: 1)
        presentation.background = grey
        presentation.effects = [grain()]

        let rep = AnnotationRenderer.renderBitmap(base: source.makeImage()!,
                                                  annotations: [],
                                                  presentation: presentation)
        #expect(rep != nil)
        #expect(BackgroundBaker.bakeCount == 1)
        // A margin pixel, well away from the picture in the middle: flat grey
        // would have no spread at all, so any wandering here is the grain.
        let margin = (0..<40).map { offset -> Double in
            Double(rep?.colorAt(x: 5 + offset, y: 5)?.redComponent ?? 0.5)
        }
        let mean = margin.reduce(0, +) / Double(margin.count)
        let deviation = margin.reduce(0) { $0 + abs($1 - mean) } / Double(margin.count)
        #expect(deviation > 0.005, "the exported margin is flat: \(margin.prefix(8))")
    }

    // MARK: Reading pixels

    private let ramp = Presentation.Background.linearGradient(
        stops: Presentation.Stop.spread([
            Presentation.Color(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
            Presentation.Color(red: 0.9, green: 0.3, blue: 0.5, alpha: 1)
        ]), angle: 0.7)

    /// The background with no effects at all, drawn the plain way.
    private func plainPixels(_ size: CGSize) -> [UInt8] {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        PresentationRenderer.drawBackground(ramp, in: CGRect(origin: .zero, size: size), ctx: ctx)
        return bytes(of: ctx.makeImage())
    }

    /// Mean absolute difference per byte, 0…255.
    private func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }

    private func bytes(of image: CGImage?) -> [UInt8] {
        guard let image else { return [] }
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    /// How far the pixels wander from their own average — the amount of visible
    /// disturbance, which is what "grain" means when the background under it is
    /// flat.
    private func spread(of image: CGImage?) -> Double {
        let raw = bytes(of: image)
        guard !raw.isEmpty else { return 0 }
        var values: [Double] = []
        values.reserveCapacity(raw.count / 4)
        for index in stride(from: 0, to: raw.count, by: 4) {
            values.append(Double(raw[index]) / 255)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}
