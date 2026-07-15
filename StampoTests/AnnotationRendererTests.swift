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

    @Test func penAndTranslucentMarkerRenderWithDifferentOpacity() {
        let base = TestImages.make(width: 48, height: 48)
        var pen = Annotation(kind: .freehand, start: CGPoint(x: 4, y: 12),
                             end: CGPoint(x: 44, y: 12), color: .black, lineWidth: 6)
        pen.freehandPoints = [pen.start, pen.end]
        pen.freehandStyle = .pen
        var marker = Annotation(kind: .freehand, start: CGPoint(x: 4, y: 34),
                                end: CGPoint(x: 44, y: 34), color: .black, lineWidth: 12)
        marker.freehandPoints = [marker.start, marker.end]
        marker.freehandStyle = .marker

        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [pen, marker])!
        let penBrightness = rep.colorAt(x: 24, y: 12)?.brightnessComponent ?? 1
        let markerBrightness = rep.colorAt(x: 24, y: 34)?.brightnessComponent ?? 1
        #expect(penBrightness < 0.2)
        #expect(markerBrightness > penBrightness)
        #expect(markerBrightness < 0.9)
    }

    @Test func curvedArrowPaintsCurveNotChord() {
        let base = TestImages.make(width: 100, height: 60)  // all white
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 4, y: 4),
                               end: CGPoint(x: 96, y: 4), color: .black, lineWidth: 4)
        arrow.curveControl = CGPoint(x: 50, y: 52)          // apex at y = 28
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [arrow])!
        let apex = rep.colorAt(x: 50, y: 28)?.brightnessComponent ?? 1
        let chordMid = rep.colorAt(x: 50, y: 4)?.brightnessComponent ?? 1
        #expect(apex < 0.5)          // ink on the curve
        #expect(chordMid > 0.9)      // straight chord midpoint stays white
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

    // MARK: loupe

    /// Solid-color image for deterministic loupe/blur source tests.
    private func solidImage(width: Int, height: Int,
                            red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ctx.makeImage()!
    }

    /// 60×60 base: left half (x < 30) black, right half white.
    private func halfToneBase() -> CGImage {
        let ctx = CGContext(
            data: nil, width: 60, height: 60,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 60))
        return ctx.makeImage()!
    }

    @Test func loupeMagnifiesPixelsUnderIt() {
        // Loupe center (36, 30) sits right of the black/white boundary at
        // x = 30. At ×2, an output pixel samples base at 36 + (x − 36) / 2,
        // so everything inside the circle is white — including (27, 30),
        // which is black without the loupe.
        var loupe = Annotation(kind: .loupe, start: CGPoint(x: 26, y: 20),
                               end: CGPoint(x: 46, y: 40), color: .red, lineWidth: 2)
        loupe.loupeScale = 2
        let rep = AnnotationRenderer.renderBitmap(base: halfToneBase(),
                                                  annotations: [loupe])!
        let inside = rep.colorAt(x: 30, y: 30)?.brightnessComponent ?? 0
        #expect(inside > 0.9)                            // magnified white
        let outside = rep.colorAt(x: 10, y: 30)?.brightnessComponent ?? 1
        #expect(outside < 0.1)                           // untouched black
        let farRight = rep.colorAt(x: 55, y: 30)?.brightnessComponent ?? 0
        #expect(farRight > 0.9)                          // untouched white
    }

    @Test func loupeStrokesRingInAnnotationColor() {
        var loupe = Annotation(kind: .loupe, start: CGPoint(x: 20, y: 20),
                               end: CGPoint(x: 40, y: 40), color: .red, lineWidth: 3)
        loupe.loupeScale = 2
        let rep = AnnotationRenderer.renderBitmap(
            base: TestImages.make(width: 60, height: 60), annotations: [loupe])!
        // Rightmost point of the ring.
        let ring = rep.colorAt(x: 40, y: 30)
        #expect((ring?.redComponent ?? 0) > 0.7)
        #expect((ring?.greenComponent ?? 1) < 0.5)
    }

    @Test func loupeRespectsBlurRedactionUnlessOptedOut() {
        // A fake solid-green "blur source" makes the assertion deterministic
        // (no CoreImage filter math): wherever the blur pass shows, we see
        // green; wherever the original shows, we see white.
        let base = TestImages.make(width: 60, height: 60)       // all white
        let greenSource = solidImage(width: 60, height: 60, red: 0, green: 1, blue: 0)
        var blur = Annotation(kind: .blur, start: .zero,
                              end: CGPoint(x: 60, y: 60), color: .red, lineWidth: 2)
        blur.blurStyle = .pixelate
        blur.blurLevel = 3
        let sources = [BlurSource(style: .pixelate, level: 3): greenSource]

        var loupe = Annotation(kind: .loupe, start: CGPoint(x: 20, y: 20),
                               end: CGPoint(x: 40, y: 40), color: .red, lineWidth: 2)
        loupe.loupeScale = 2

        // Default: redaction is replayed inside the loupe → green.
        let redacted = AnnotationRenderer.renderBitmap(
            base: base, blurSources: sources, annotations: [blur, loupe])!
        let redactedInside = redacted.colorAt(x: 30, y: 30)
        #expect((redactedInside?.greenComponent ?? 0) > 0.7)
        #expect((redactedInside?.redComponent ?? 1) < 0.3)

        // Opt-in: the loupe reveals the raw base → white.
        loupe.loupeRevealsOriginal = true
        let revealed = AnnotationRenderer.renderBitmap(
            base: base, blurSources: sources, annotations: [blur, loupe])!
        let revealedInside = revealed.colorAt(x: 30, y: 30)
        #expect((revealedInside?.brightnessComponent ?? 0) > 0.9)
        // Outside the loupe the redaction still applies in both modes.
        let outsideLoupe = revealed.colorAt(x: 50, y: 10)
        #expect((outsideLoupe?.greenComponent ?? 0) > 0.7)
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

    @Test func fontPresetsAreInstalledAndCoverLatinAndCyrillic() {
        #expect(AnnotationFontPreset.allCases.count == 6)
        let required = CharacterSet(charactersIn: "AaБбЯяЁё0123")
        for preset in AnnotationFontPreset.allCases {
            let font = preset.nsFont(ofSize: 18)
            #expect(font.coveredCharacterSet.isSuperset(of: required),
                    "\(preset.displayName) must support Latin and Cyrillic")
        }
    }

    @Test func rendererUsesAnnotationFontForTextAndNumbering() {
        var text = Annotation(kind: .text, start: .zero, end: .zero,
                              color: .red, lineWidth: 4)
        text.fontSize = 24
        text.fontPreset = .georgia
        #expect(AnnotationRenderer.textFont(for: text).familyName == "Georgia")

        var numbering = Annotation(kind: .step, start: .zero, end: .zero,
                                   color: .red, lineWidth: 4)
        numbering.fontPreset = .courierNew
        #expect(AnnotationRenderer.stepFont(for: numbering).familyName == "Courier New")
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
