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

    @Test func solidSRGBColoursKeepTheirExactComponents() throws {
        let samples = [(30, 30, 30), (64, 64, 64), (128, 128, 128),
                       (181, 182, 184), (199, 212, 224), (237, 237, 237),
                       (200, 80, 60), (255, 255, 255), (0, 0, 0)]
        for (red, green, blue) in samples {
            let input = Presentation.Color(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                           blue: CGFloat(blue) / 255, alpha: 1)
            let colors = PresentationColorSampler.colors(from: try solidImage(input))
            #expect(colors.count == 4)
            #expect(colors.allSatisfy { $0 == colors.first })
            for color in colors { expect(color, matches: input) }
        }
    }

    @Test func translucentSamplesReturnStraightComponents() throws {
        let input = Presentation.Color(red: 200 / 255, green: 80 / 255, blue: 60 / 255, alpha: 0.5)
        let colors = PresentationColorSampler.colors(from: try solidImage(input))
        #expect(colors.count == 4)
        for color in colors {
            expect(color, matches: input)
        }
        let clear = Presentation.Color.clear
        #expect(PresentationColorSampler.colors(from: try solidImage(clear)) == Array(repeating: clear, count: 4))
    }

    @Test func quartersKeepTheirOriginalOrder() {
        let colors = PresentationColorSampler.colors(from: borderedQuadrants())
        #expect(colors.count == 4)
        // The existing image has red/green above blue/yellow, with a black rim.
        #expect(colors[0].red > 0.35 && colors[0].green < 0.25 && colors[0].blue < 0.25)
        #expect(colors[1].red < 0.25 && colors[1].green > 0.35 && colors[1].blue < 0.25)
        #expect(colors[2].red < 0.25 && colors[2].green < 0.25 && colors[2].blue > 0.35)
        #expect(colors[3].red > 0.35 && colors[3].green > 0.35 && colors[3].blue < 0.25)
    }

    private func expect(_ color: Presentation.Color, matches input: Presentation.Color) {
        let tolerance: CGFloat = 1 / 255
        #expect(abs(color.red - input.red) <= tolerance)
        #expect(abs(color.green - input.green) <= tolerance)
        #expect(abs(color.blue - input.blue) <= tolerance)
        #expect(abs(color.alpha - input.alpha) <= tolerance)
    }

    private func solidImage(_ color: Presentation.Color) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return try #require(context.makeImage())
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
