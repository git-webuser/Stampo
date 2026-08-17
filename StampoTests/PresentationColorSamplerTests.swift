import AppKit
import CoreGraphics
import Testing
@testable import Stampo

@Suite struct PresentationColorSamplerTests {
    @Test func samplesTheInteriorOfEachQuarterInsteadOfOnlyTheCorners() {
        let image = borderedQuadrants()
        let colors = PresentationColorSampler.colors(from: image)

        #expect(colors.count == 4)
        #expect(colors.contains { $0.red > 0.35 && $0.green < 0.25 && $0.blue < 0.25 })
        #expect(colors.contains { $0.red < 0.25 && $0.green > 0.35 && $0.blue < 0.25 })
        #expect(colors.contains { $0.red < 0.25 && $0.green < 0.25 && $0.blue > 0.35 })
        #expect(colors.contains { $0.red > 0.35 && $0.green > 0.35 && $0.blue < 0.25 })
    }

    private func borderedQuadrants() -> CGImage {
        let width = 80
        let height = 80
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 80))

        let inset: CGFloat = 2
        let half: CGFloat = 38
        let colors = [
            CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
            CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        ]
        let rects = [
            CGRect(x: inset, y: inset + half, width: half, height: half),
            CGRect(x: inset + half, y: inset + half, width: half, height: half),
            CGRect(x: inset, y: inset, width: half, height: half),
            CGRect(x: inset + half, y: inset, width: half, height: half)
        ]
        for (color, rect) in zip(colors, rects) {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }
}
