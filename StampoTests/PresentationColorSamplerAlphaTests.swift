import CoreGraphics
import Testing
@testable import Stampo

/// A screenshot of a window carries its shadow: a transparent margin with
/// translucent black in it. The page colour is taken from the sampler, so that
/// margin must not tint it — a transparent pixel has no colour to contribute,
/// and a shadow pixel only as much as its alpha says.
@Suite struct PresentationColorSamplerAlphaTests {

    // MARK: - The averaging itself, on bytes

    /// Premultiplied RGBA8, one row.
    private func average(_ row: [[UInt8]]) -> Presentation.Color? {
        let bytes = row.flatMap { $0 }
        return bytes.withUnsafeBytes {
            PresentationColorSampler.averageColor(in: $0, bytesPerRow: bytes.count,
                                                  xRange: 0..<row.count, yRange: 0..<1)
        }
    }

    private let window: [UInt8] = [200, 80, 60, 255]
    private let clear: [UInt8] = [0, 0, 0, 0]
    /// Black at alpha 0.1, as stored premultiplied.
    private let faintShadow: [UInt8] = [0, 0, 0, 26]

    @Test func transparentPixelsDoNotChangeTheColour() throws {
        let solid = try #require(average([window, window]))
        let withMargin = try #require(average([clear, window, clear, clear, window, clear]))
        #expect(abs(withMargin.red - solid.red) < 1e-9)
        #expect(abs(withMargin.green - solid.green) < 1e-9)
        #expect(abs(withMargin.blue - solid.blue) < 1e-9)
        #expect(abs(solid.red - 200.0 / 255) < 1e-9)
        // The margin shows up in the alpha, where it belongs.
        #expect(abs(solid.alpha - 1) < 1e-9)
        #expect(abs(withMargin.alpha - 2.0 / 6) < 1e-9)
    }

    @Test func aShadowDarkensOnlyInProportionToItsAlpha() throws {
        // Equal numbers of window and faint-shadow pixels. Dividing by the
        // number of pixels would give half the window's red; weighting by alpha
        // gives 1 / 1.1 of it.
        let mixed = try #require(average([window, faintShadow, window, faintShadow]))
        let expected = (200.0 / 255) * (255.0 / (255 + 26))
        #expect(abs(mixed.red - expected) < 1e-9)
    }

    @Test func aBlockWithNothingInItHasNoColourAndNoAlpha() throws {
        let nothing = try #require(average([clear, clear, clear]))
        #expect(nothing == .clear)
    }

    // MARK: - The whole pipeline, on a window with its shadow

    /// A window card on a transparent canvas with a soft black shadow, drawn the
    /// way the system draws one.
    private func windowWithShadow(card: CGColor) throws -> CGImage {
        let width = 1320, height = 920, margin = 60
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let rect = CGRect(x: margin, y: margin, width: width - 2 * margin, height: height - 2 * margin)
        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5))
        context.setFillColor(card)
        context.addPath(path)
        context.fillPath()
        return try #require(context.makeImage())
    }

    /// The same card with no margin at all: what a shot of the window without
    /// its shadow would sample.
    private func opaqueWindow(card: CGColor) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(card)
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        return try #require(context.makeImage())
    }

    private func srgb(_ red: Int, _ green: Int, _ blue: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }

    @Test func aWindowWithAShadowGivesThePageTheWindowsColour() throws {
        // A saturated card, so the page keeps the card's own colour.
        let image = try windowWithShadow(card: srgb(60, 120, 220))
        let page = PageColor.defaultColor(from: PresentationColorSampler.colors(from: image))

        // Each quarter is mostly card, a little shadow, a little nothing. The
        // card is 60/120/220; the shadow may pull it a little toward black
        // (it is real black at partial alpha), the nothing must not. Measured:
        // 60/119/219 now, 48/96/176 with the per-pixel division.
        #expect(abs(page.red * 255 - 60) < 3)
        #expect(abs(page.green * 255 - 120) < 3)
        #expect(abs(page.blue * 255 - 220) < 3)
        #expect(page.alpha == 1)
    }

    /// Whatever the window looks like, its shadow must not change what the page
    /// becomes: the shot with the margin and the shot without it agree. This is
    /// also what covers the light windows, whose old, accidentally darkened
    /// colour passed the visibility test that the real one does not.
    @Test func theShadowDoesNotChangeThePageTheWindowGets() throws {
        let cards = [srgb(60, 120, 220), srgb(222, 233, 250), srgb(237, 237, 237),
                     srgb(252, 236, 150), srgb(40, 40, 44)]
        for card in cards {
            let withShadow = PageColor.defaultColor(
                from: PresentationColorSampler.colors(from: try windowWithShadow(card: card)))
            let without = PageColor.defaultColor(
                from: PresentationColorSampler.colors(from: try opaqueWindow(card: card)))
            // 1/255 for the thumbnail's 8-bit rounding, a little more for the
            // shadow's own faint weight.
            let tolerance: CGFloat = 4.0 / 255
            #expect(abs(withShadow.red - without.red) < tolerance)
            #expect(abs(withShadow.green - without.green) < tolerance)
            #expect(abs(withShadow.blue - without.blue) < tolerance)
        }
    }
}
