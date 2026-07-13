import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// Shared tiny-image factory for renderer/document tests.
enum TestImages {
    static func make(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()!
    }
}

@Suite struct AnnotationRendererTests {

    @Test func exportPreservesPixelDimensions() {
        // Odd, non-square size on purpose — catches any scale/flip slip.
        let base = TestImages.make(width: 37, height: 23)
        let rect = Annotation(kind: .rect, start: CGPoint(x: 2, y: 2),
                              end: CGPoint(x: 30, y: 18), color: .red, lineWidth: 3)
        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [rect])
        #expect(rep != nil)
        #expect(rep?.pixelsWide == 37)
        #expect(rep?.pixelsHigh == 23)
    }

    @Test func annotationActuallyDrawsPixels() {
        let base = TestImages.make(width: 40, height: 40)  // all white
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 4, y: 20),
                               end: CGPoint(x: 36, y: 20), color: .red, lineWidth: 4)
        arrow.color = .black
        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [arrow])!
        // A pixel on the shaft must no longer be white.
        let mid = rep.colorAt(x: 20, y: 20)
        #expect(mid != nil)
        #expect((mid?.brightnessComponent ?? 1.0) < 0.5)
    }

    @Test(arguments: ArrowStyle.allCases)
    func everyArrowStyleDrawsPixels(arrowStyle: ArrowStyle) {
        let base = TestImages.make(width: 60, height: 20)  // all white
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 4, y: 10),
                               end: CGPoint(x: 56, y: 10), color: .black, lineWidth: 4)
        arrow.arrowStyle = arrowStyle
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [arrow])!
        // Somewhere along the shaft must be non-white for every style.
        let onShaft = (10...40).contains { x in
            (rep.colorAt(x: x, y: 10)?.brightnessComponent ?? 1) < 0.5
        }
        #expect(onShaft)
    }

    @Test(arguments: ArrowHeadPlacement.allCases, ArrowStyle.allCases)
    func arrowHeadsRenderAtConfiguredEndpoints(placement: ArrowHeadPlacement,
                                               style: ArrowStyle) {
        let base = TestImages.make(width: 120, height: 40)
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 20, y: 20),
                               end: CGPoint(x: 100, y: 20), color: .black, lineWidth: 4)
        arrow.arrowHeadPlacement = placement
        arrow.arrowStyle = style
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [arrow])!

        func hasOffAxisInk(xRange: ClosedRange<Int>) -> Bool {
            xRange.contains { x in
                (12...15).contains { y in
                    (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.7
                }
            }
        }

        #expect(hasOffAxisInk(xRange: 22...35) == placement.includesStart)
        #expect(hasOffAxisInk(xRange: 85...98) == placement.includesEnd)
    }

    @Test(arguments: LineStyle.allCases)
    func everyLineStyleDrawsPixels(lineStyle: LineStyle) {
        let base = TestImages.make(width: 120, height: 20)
        var line = Annotation(kind: .line, start: CGPoint(x: 4, y: 10),
                              end: CGPoint(x: 116, y: 10), color: .black, lineWidth: 2)
        line.lineStyle = lineStyle
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [line])!
        let darkPixels = (6...114).filter { x in
            (rep.colorAt(x: x, y: 10)?.brightnessComponent ?? 1) < 0.5
        }
        #expect(!darkPixels.isEmpty)
        if lineStyle == .solid {
            #expect(darkPixels.count > 100)
        } else {
            #expect(darkPixels.count < 90)
        }
    }

    @Test func stepFontIsProportionalAcrossDigitCounts() {
        let d: CGFloat = 40
        let one = AnnotationRenderer.stepFontSize(label: "1", diameter: d)
        let ten = AnnotationRenderer.stepFontSize(label: "10", diameter: d)
        #expect(one > 0 && ten > 0)
        // The old logic shrank two digits to a fraction of one; they should
        // now stay close in size.
        #expect(ten >= one * 0.8)
        // And the label scales up with a larger marker.
        #expect(AnnotationRenderer.stepFontSize(label: "1", diameter: 80) > one)
    }

    @Test func measureTextGrowsWithContent() {
        var a = Annotation(kind: .text, start: .zero, end: .zero, color: .red, lineWidth: 4)
        a.fontSize = 24
        a.text = "Проверка"
        let short = AnnotationRenderer.measureText(a)
        #expect(short.width > 0 && short.height > 0)
        a.text = "Проверка и ещё немного текста"
        let long = AnnotationRenderer.measureText(a)
        #expect(long.width > short.width)
    }

    @Test(arguments: Array(BlurIntensity.range))
    func blurSourcesKeepBaseDimensions(level: Int) {
        let base = TestImages.make(width: 64, height: 48)
        let blurred = AnnotationRenderer.makeBlurred(base: base, level: level)
        let pixelated = AnnotationRenderer.makePixelated(base: base, level: level)
        #expect(blurred?.width == 64 && blurred?.height == 48)
        #expect(pixelated?.width == 64 && pixelated?.height == 48)
    }

    @Test func blurAnnotationUsesItsOwnLevelSource() {
        let base = TestImages.make(width: 64, height: 48)
        var blur = Annotation(kind: .blur, start: CGPoint(x: 8, y: 8),
                              end: CGPoint(x: 40, y: 40), color: .red, lineWidth: 0)
        blur.blurStyle = .pixelate
        blur.blurLevel = 5
        // Only the matching (style, level) source lets the annotation draw;
        // a mismatched cache must leave the image untouched rather than crash.
        let mismatched = [BlurSource(style: .pixelate, level: 1):
                          AnnotationRenderer.makePixelated(base: base, level: 1)!]
        let rep = AnnotationRenderer.renderBitmap(
            base: base, blurSources: mismatched, annotations: [blur])
        #expect(rep != nil)
    }

    @Test func fillAndStepDrawInsideTheirBounds() {
        let base = TestImages.make(width: 80, height: 80)
        var rect = Annotation(kind: .rect, start: CGPoint(x: 5, y: 5),
                              end: CGPoint(x: 35, y: 35), color: .red, lineWidth: 2)
        rect.fillOpacity = 0.2
        var step = Annotation(kind: .step, start: CGPoint(x: 60, y: 60),
                              end: CGPoint(x: 60, y: 60), color: .black, lineWidth: 0)
        step.stepLabel = "2"
        step.stepDiameter = 24
        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [rect, step])!
        #expect(rep.colorAt(x: 20, y: 20)?.redComponent ?? 1 < 1)
        // Sample beside the white number at the marker center.
        #expect(rep.colorAt(x: 52, y: 60)?.brightnessComponent ?? 1 < 0.5)
    }
}

@Suite struct FileStoreEncodingTests {

    @Test(arguments: [
        ("png", NSBitmapImageRep.FileType.png),
        ("jpg", .jpeg),
        ("tiff", .tiff),
        ("webp", .png),   // unknown formats fall back to png
        ("", .png),
    ])
    func formatMapping(format: String, expected: NSBitmapImageRep.FileType) {
        let (fileType, _) = ScreenshotFileStore.encoding(for: format)
        #expect(fileType == expected)
    }

    @Test func jpegGetsCompressionFactor() {
        let (_, properties) = ScreenshotFileStore.encoding(for: "jpg")
        #expect(properties[.compressionFactor] as? Double != nil)
    }
}
