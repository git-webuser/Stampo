import AppKit
import CoreGraphics
import CoreText
import Testing
@testable import Stampo

/// The baked background: that it is only baked when it has to be, that the same
/// request is not baked twice, and — the one that matters most — that the same
/// stack is the same picture at the resolution of the preview and at the
/// resolution of the file.
///
/// Serialized because the cache and the bake counter are shared by the whole
/// app, which is exactly the property being tested.
@MainActor @Suite(.serialized) struct EffectBakerTests {

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
        EffectBaker.emptyCache()
        EffectBaker.resetBakeCount()
    }

    /// Nothing to apply means nothing is computed — the old path, untouched.
    /// This is the regression guard for every document that never opens the
    /// effects section.
    @Test func anEmptyStackNeverBakes() {
        fresh()
        var off = grain()
        off.isEnabled = false
        #expect(EffectBaker.image(background: grey, effects: [],
                                      pixelSize: CGSize(width: 40, height: 40)) == nil)
        #expect(EffectBaker.image(background: grey, effects: [off],
                                      pixelSize: CGSize(width: 40, height: 40)) == nil)
        // A transparent page has no pixels to disturb.
        #expect(EffectBaker.image(background: .none, effects: [grain()],
                                      pixelSize: CGSize(width: 40, height: 40)) == nil)
        #expect(EffectBaker.bakeCount == 0)
    }

    @Test func theSameRequestIsBakedOnceAndThenRemembered() {
        fresh()
        let size = CGSize(width: 80, height: 60)
        let first = EffectBaker.image(background: grey, effects: [grain()], pixelSize: size)
        let second = EffectBaker.image(background: grey, effects: [grain()], pixelSize: size)
        #expect(first != nil)
        #expect(EffectBaker.bakeCount == 1)
        #expect(first === second)
    }

    @Test func changingAnythingMissesTheCache() {
        fresh()
        let size = CGSize(width: 80, height: 60)
        _ = EffectBaker.image(background: grey, effects: [grain()], pixelSize: size)
        _ = EffectBaker.image(background: grey, effects: [grain(amount: 0.2)], pixelSize: size)
        _ = EffectBaker.image(background: grey, effects: [grain(scale: 0.008)], pixelSize: size)
        _ = EffectBaker.image(background: .solid(.white), effects: [grain()], pixelSize: size)
        _ = EffectBaker.image(background: grey, effects: [grain()],
                                  pixelSize: CGSize(width: 81, height: 60))
        #expect(EffectBaker.bakeCount == 5)
    }

    @Test func grainDisturbsTheBackgroundAndStrengthDecidesHowMuch() {
        fresh()
        let size = CGSize(width: 120, height: 120)
        let weak = EffectBaker.image(background: grey, effects: [grain(amount: 0.1)],
                                         pixelSize: size)
        let strong = EffectBaker.image(background: grey, effects: [grain(amount: 0.9)],
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
        let once = EffectBaker.image(background: grey, effects: [grain(seed: 3)],
                                         pixelSize: size)
        EffectBaker.emptyCache()
        let again = EffectBaker.image(background: grey, effects: [grain(seed: 3)],
                                          pixelSize: size)
        let other = EffectBaker.image(background: grey, effects: [grain(seed: 4)],
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
        let small = EffectBaker.image(background: grey, effects: [grain()],
                                          pixelSize: CGSize(width: 200, height: 200))
        let large = EffectBaker.image(background: grey, effects: [grain()],
                                          pixelSize: CGSize(width: 800, height: 800))
        let ratio = spread(of: large) / max(spread(of: small), 0.0001)
        #expect(ratio > 0.75 && ratio < 1.35,
                "grain energy moved by \(ratio)× between 200px and 800px")
    }

    /// A canvas nobody can hold is drawn plainly rather than slowly.
    @Test func anImpossibleSizeIsRefusedRatherThanAttempted() {
        fresh()
        #expect(EffectBaker.image(background: grey, effects: [grain()],
                                      pixelSize: CGSize(width: 0, height: 100)) == nil)
        #expect(EffectBaker.image(
            background: grey, effects: [grain()],
            pixelSize: CGSize(width: CGFloat(EffectBaker.maximumSide + 1), height: 100)
        ) == nil)
        #expect(EffectBaker.bakeCount == 0)
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
            EffectBaker.emptyCache()
            let before = under.isEmpty
                ? plainPixels(size)
                : bytes(of: EffectBaker.image(background: ramp, effects: under, pixelSize: size))
            let after = bytes(of: EffectBaker.image(background: ramp,
                                                       effects: under + [EffectStack.make(kind, seed: 5)],
                                                       pixelSize: size))
            #expect(distance(before, after) > 0.75,
                    "\(kind) at its default barely changes anything")
        }
    }

    /// The reported bug, kept: white dots on a white page, and a grain that
    /// could not be seen either.
    ///
    /// Two causes, both now closed. Ink took its default from the background's
    /// brightness — before that, patterns measured a fortieth of their strength
    /// on a light page. And Core Image was working in linear light, where a
    /// fixed change is enormous near black and invisible near white; with
    /// colour management off, an effect is as strong as it says it is wherever
    /// it lands.
    ///
    /// Vignette and halftone are left out on purpose: darkening the edges and
    /// laying print dots are asymmetric by nature, not by accident.
    @Test func inkIsAsVisibleOnALightPageAsOnADarkOne() {
        let light = Presentation.Background.solid(
            Presentation.Color(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        let dark = Presentation.Background.solid(
            Presentation.Color(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))

        for kind in [Presentation.Effect.Kind.grain, .dots, .grid, .stripes, .ascii] {
            func spread(_ background: Presentation.Background) -> Double {
                EffectBaker.emptyCache()
                return self.spread(of: EffectBaker.image(
                    background: background,
                    effects: [EffectStack.make(kind, over: background, seed: 5)],
                    pixelSize: CGSize(width: 300, height: 300)))
            }
            let onLight = spread(light), onDark = spread(dark)
            #expect(onLight > 0.02, "\(kind) is invisible on a light page: \(onLight)")
            let ratio = onLight / max(onDark, 0.0001)
            #expect(ratio > 0.4 && ratio < 2.5,
                    "\(kind) is \(ratio)× as strong on a light page as on a dark one")
        }
    }

    /// Ink is chosen for the page it lands on, and only when the effect is
    /// made: a colour the user picked afterwards is theirs to keep.
    @Test func newInkIsChosenForTheBackgroundItLandsOn() {
        let light = Presentation.Background.solid(
            Presentation.Color(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
        let dark = Presentation.Background.solid(
            Presentation.Color(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        #expect(EffectStack.make(.dots, over: light).color == .black)
        #expect(EffectStack.make(.dots, over: dark).color == .white)
        // A gradient answers with its average, which is the only answer it has.
        let split = Presentation.Background.linearGradient(
            stops: Presentation.Stop.spread([.black, .black, .white]), angle: 0)
        #expect(EffectStack.make(.grid, over: split).color == .white)
    }

    /// A filter that rewrites alpha must not darken the page.
    ///
    /// Adding two opaque images leaves an alpha of *two* inside Core Image's
    /// pipeline. It renders the same, so nothing looks wrong — until a later
    /// filter rewrites the alpha, at which point the premultiplied colour is
    /// divided by the two it was stored against. The lens does exactly that
    /// (its colour fringe splits the channels apart), and the whole page came
    /// out at half brightness.
    @Test func anEffectThatSplitsChannelsKeepsThePageAsBrightAsItWas() {
        var plain = EffectStack.make(.lens, over: ramp, seed: 5)
        plain.detail = 0
        var fringed = plain
        fringed.detail = 0.45
        let size = CGSize(width: 200, height: 200)

        EffectBaker.emptyCache()
        let without = mean(of: EffectBaker.image(background: ramp, effects: [plain],
                                                     pixelSize: size))
        let with = mean(of: EffectBaker.image(background: ramp, effects: [fringed],
                                                  pixelSize: size))
        #expect(with > without * 0.9,
                "the colour fringe cost the page its brightness: \(without) → \(with)")
    }

    /// The frosted glass splits the spectrum too, and its dial has to move the
    /// picture. Refracting each channel separately through the same texture was
    /// tried first and measured at half a byte of difference at full strength —
    /// `CIGlassDistortion` barely responds to a change in its scale — so the
    /// channels are slid apart instead.
    @Test func theFrostedGlassSpreadsColourAndTheDialSaysHowFar() {
        func fringe(_ aberration: CGFloat) -> Double {
            var glass = EffectStack.make(.glass, over: ramp, seed: 5)
            glass.aberration = aberration
            EffectBaker.emptyCache()
            let raw = bytes(of: EffectBaker.image(background: ramp, effects: [glass],
                                                      pixelSize: CGSize(width: 300, height: 300)))
            guard !raw.isEmpty else { return 0 }
            // How far apart red and blue ended up, which is what a fringe is.
            var total = 0.0
            for index in stride(from: 0, to: raw.count, by: 4) {
                total += abs(Double(raw[index]) - Double(raw[index + 2]))
            }
            return total / Double(raw.count / 4)
        }
        let none = fringe(0), half = fringe(0.5), full = fringe(1)
        #expect(half > none + 1, "the aberration dial does nothing: \(none) → \(half)")
        #expect(full > half, "the dial stops meaning anything past halfway")
    }

    /// Each set of characters has to make its own picture — otherwise the menu
    /// offers four names for one look.
    @Test func everyGlyphSetDrawsItsOwnPicture() {
        var pictures: [[UInt8]] = []
        for set in Presentation.Effect.GlyphSet.allCases {
            var ascii = EffectStack.make(.ascii, over: ramp, seed: 5)
            ascii.glyphs = set
            EffectBaker.emptyCache()
            pictures.append(bytes(of: EffectBaker.image(
                background: ramp, effects: [ascii],
                pixelSize: CGSize(width: 240, height: 240))))
        }
        for (first, second) in zip(pictures, pictures.dropFirst()) {
            #expect(distance(first, second) > 1,
                    "two glyph sets drew the same page")
        }
    }

    /// Ribs are clipped in a turned frame, so at any angle but zero the strips
    /// at the corners cover ground the page does not. Drawing only the page
    /// there left those corners empty — the reported "as if the canvas ran
    /// out". The source now reaches past the page, and this is what says so.
    @Test func aTurnedRibStillHasSomethingToDraw() {
        for angle in [30, 45, 120] as [CGFloat] {
            var fluted = EffectStack.make(.fluted, over: ramp, seed: 5)
            fluted.angleInDegrees = angle
            EffectBaker.emptyCache()
            let raw = bytes(of: EffectBaker.image(background: ramp, effects: [fluted],
                                                      pixelSize: CGSize(width: 240, height: 240)))
            #expect(!raw.isEmpty)
            let plain = plainPixels(CGSize(width: 240, height: 240))
            // The four corners, a couple of pixels in from each edge.
            for (x, y) in [(3, 3), (236, 3), (3, 236), (236, 236)] {
                let index = (y * 240 + x) * 4
                #expect(raw[index + 3] == 255,
                        "corner (\(x), \(y)) at \(angle)° is transparent")
                let gap = abs(Int(raw[index]) - Int(plain[index]))
                    + abs(Int(raw[index + 1]) - Int(plain[index + 1]))
                    + abs(Int(raw[index + 2]) - Int(plain[index + 2]))
                #expect(gap < 210,
                        "corner (\(x), \(y)) at \(angle)° lost the page: \(gap)")
            }
        }
    }

    /// One character is one cell wide, because the point size is worked back
    /// from the font's measured advance. Guessing it — six tenths of the point
    /// size — was close enough for letters and wrong for blocks, whose ink is a
    /// full line box, and they ran into each other.
    @Test func oneCharacterIsExactlyOneCellWide() {
        let ratio = EffectBaker.advanceRatio
        #expect(ratio > 0.4 && ratio < 0.8, "an implausible advance: \(ratio)")
        for cellWidth in [8.0, 17.0, 40.0] as [CGFloat] {
            let font = CTFontCreateWithName("Menlo" as CFString, cellWidth / ratio, nil)
            var utf16 = Array("W".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: 1)
            #expect(CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, 1))
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
            #expect(abs(advance.width - cellWidth) < 0.5,
                    "a \(cellWidth)pt cell holds a \(advance.width)pt character")
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
        #expect(EffectBaker.bakeCount == 1)
        #expect(spread(of: ctx.makeImage()) > 0.001)

        // And the same background at the same device size is not baked again,
        // which is what keeps a dragged picture smooth.
        PresentationRenderer.drawBackground(grey, effects: [grain()],
                                            in: CGRect(x: 0, y: 0, width: 200, height: 200),
                                            ctx: ctx)
        #expect(EffectBaker.bakeCount == 1)
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
        #expect(EffectBaker.bakeCount == 1)
        // A margin pixel, well away from the picture in the middle: flat grey
        // would have no spread at all, so any wandering here is the grain.
        let margin = (0..<40).map { offset -> Double in
            Double(rep?.colorAt(x: 5 + offset, y: 5)?.redComponent ?? 0.5)
        }
        let mean = margin.reduce(0, +) / Double(margin.count)
        let deviation = margin.reduce(0) { $0 + abs($1 - mean) } / Double(margin.count)
        #expect(deviation > 0.005, "the exported margin is flat: \(margin.prefix(8))")
    }

    /// The glow is a second light, not a setting of the first: a dark shadow
    /// below for depth and a coloured halo all round are wanted together, and
    /// one value could only ever be one of them.
    @Test func theGlowAndTheShadowBothReachTheFile() {
        let source = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let base = source.makeImage()!

        func render(_ mutate: (inout Presentation) -> Void) -> NSBitmapImageRep? {
            var presentation = Presentation.identity
            presentation.canvas = .auto(margins: Presentation.Margins(top: 40, leading: 40,
                                                                      bottom: 40, trailing: 40),
                                        scale: 1)
            presentation.background = .solid(.white)
            mutate(&presentation)
            return AnnotationRenderer.renderBitmap(base: base, annotations: [],
                                                   presentation: presentation)
        }

        // Just outside the picture, where both lights land.
        func edge(_ rep: NSBitmapImageRep?) -> (r: Double, b: Double) {
            let color = rep?.colorAt(x: 35, y: 50)
            return (Double(color?.redComponent ?? 1), Double(color?.blueComponent ?? 1))
        }

        let plain = edge(render { _ in })
        let glowing = edge(render {
            $0.glow = Presentation.Glow(radius: 0.1, opacity: 0.9,
                                        color: Presentation.Color(red: 0, green: 0, blue: 1,
                                                                  alpha: 1))
        })
        let shadowed = edge(render {
            $0.shadow = Presentation.Shadow(radius: 0.1, offset: .zero, opacity: 0.9)
        })

        // The glow tints: red falls away while blue holds up.
        #expect(glowing.r < plain.r - 0.05)
        #expect(glowing.b > glowing.r + 0.1)
        // The shadow darkens everything alike.
        #expect(shadowed.b < plain.b - 0.05)
        #expect(abs(shadowed.b - shadowed.r) < 0.05)
    }

    /// The whole point of the layer switch: the same effect either stops at the
    /// picture or runs over it.
    @Test func theLayerDecidesWhetherThePictureIsTouched() {
        let source = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.setFillColor(CGColor(gray: 0.5, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let base = source.makeImage()!

        func render(_ effects: [Presentation.Effect]) -> NSBitmapImageRep? {
            var presentation = Presentation.identity
            presentation.canvas = .auto(margins: Presentation.Margins(top: 30, leading: 30,
                                                                      bottom: 30, trailing: 30),
                                        scale: 1)
            presentation.background = ramp
            presentation.effects = effects
            EffectBaker.emptyCache()
            return AnnotationRenderer.renderBitmap(base: base, annotations: [],
                                                   presentation: presentation)
        }
        // The middle of the canvas is the middle of the picture: 40 + 20.
        func middle(_ rep: NSBitmapImageRep?) -> (Double, Double, Double) {
            let color = rep?.colorAt(x: 50, y: 50)
            return (Double(color?.redComponent ?? 0), Double(color?.greenComponent ?? 0),
                    Double(color?.blueComponent ?? 0))
        }

        var behind = EffectStack.make(.dither, seed: 5)
        behind.layer = .background
        var over = behind
        over.layer = .page

        let plain = middle(render([]))
        let withBackground = middle(render([behind]))
        let withPage = middle(render([over]))

        func gap(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
        }
        #expect(gap(plain, withBackground) < 0.01,
                "a background effect reached the picture: \(plain) vs \(withBackground)")
        #expect(gap(plain, withPage) > 0.05,
                "a page effect left the picture alone: \(plain) vs \(withPage)")
    }

    /// The page pass is deliberately not cached, and that is the difference
    /// between the layers rather than an oversight: a page that moves with the
    /// picture has nothing worth keeping.
    @Test func thePagePassIsComputedEveryTime() {
        fresh()
        let rendered = CGContext(data: nil, width: 60, height: 60, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        rendered.setFillColor(CGColor(gray: 0.4, alpha: 1))
        rendered.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        let page = rendered.makeImage()!

        var effect = EffectStack.make(.halftone, seed: 5)
        effect.layer = .page
        #expect(EffectBaker.page([effect], over: page) != nil)
        #expect(EffectBaker.page([effect], over: page) != nil)
        #expect(EffectBaker.bakeCount == 2)

        // A stack with nothing on this layer does not reach the pass at all.
        var behind = effect
        behind.layer = .background
        #expect(EffectBaker.page([behind], over: page) == nil)
        #expect(EffectBaker.bakeCount == 2)
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

    /// Mean brightness, 0…1.
    private func mean(of image: CGImage?) -> Double {
        let raw = bytes(of: image)
        guard !raw.isEmpty else { return 0 }
        var total = 0.0
        for index in stride(from: 0, to: raw.count, by: 4) {
            total += (Double(raw[index]) + Double(raw[index + 1]) + Double(raw[index + 2])) / 3
        }
        return total / Double(raw.count / 4) / 255
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
