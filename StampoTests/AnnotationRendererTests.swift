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
            base: base, blurred: nil, pixelated: nil, annotations: [rect])
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
            base: base, blurred: nil, pixelated: nil, annotations: [arrow])!
        // A pixel on the shaft must no longer be white.
        let mid = rep.colorAt(x: 20, y: 20)
        #expect(mid != nil)
        #expect((mid?.brightnessComponent ?? 1.0) < 0.5)
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

    @Test func blurSourcesKeepBaseDimensions() {
        let base = TestImages.make(width: 64, height: 48)
        let blurred = AnnotationRenderer.makeBlurred(base: base)
        let pixelated = AnnotationRenderer.makePixelated(base: base)
        #expect(blurred?.width == 64 && blurred?.height == 48)
        #expect(pixelated?.width == 64 && pixelated?.height == 48)
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
