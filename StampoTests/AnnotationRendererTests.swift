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

    /// A window shot taken with its shadow carries a transparent halo, and an
    /// untouched document must hand that halo back untouched. The identity
    /// presentation stands in for `nil` only to supply geometry — its white
    /// page must never be painted, or every undecorated save came out opaque.
    @Test func exportWithoutAPresentationKeepsTheImagesTransparency() {
        let ctx = CGContext(
            data: nil, width: 20, height: 20,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Opaque red centre, transparent everywhere else.
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 5, y: 5, width: 10, height: 10))
        let base = ctx.makeImage()!

        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [])

        #expect(rep?.pixelsWide == 20)
        #expect((rep?.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.01)
        #expect((rep?.colorAt(x: 10, y: 10)?.alphaComponent ?? 0) > 0.99)
        #expect((rep?.colorAt(x: 10, y: 10)?.redComponent ?? 0) > 0.9)
    }

    @Test func presentationControlsExportCanvasSizeAndBackground() {
        let base = solidImage(width: 20, height: 10, red: 1, green: 0, blue: 0)
        let blue = Presentation.Color(red: 0, green: 0, blue: 1, alpha: 1)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 40, height: 30)),
            background: .solid(blue)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        #expect(rep?.pixelsWide == 40)
        #expect(rep?.pixelsHigh == 30)
        #expect((rep?.colorAt(x: 20, y: 15)?.redComponent ?? 0) > 0.9)
        #expect((rep?.colorAt(x: 0, y: 0)?.blueComponent ?? 0) > 0.9)
    }

    @Test func presentationRoundsImageCornersWithoutClippingBackground() {
        let base = solidImage(width: 24, height: 24, red: 1, green: 0, blue: 0)
        let blue = Presentation.Color(red: 0, green: 0, blue: 1, alpha: 1)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 24, height: 24)),
            background: .solid(blue),
            cornerRadius: 0.25
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        #expect((rep?.colorAt(x: 12, y: 12)?.redComponent ?? 0) > 0.9)
        #expect((rep?.colorAt(x: 0, y: 0)?.blueComponent ?? 0) > 0.9)
    }

    @Test func presentationShadowProducesPixelsOutsideImage() {
        let base = solidImage(width: 100, height: 100, red: 1, green: 1, blue: 1)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 300, height: 300)),
            background: .solid(.white),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 1.0 / 3.0),
            shadow: Presentation.Shadow(radius: 0.06, offset: .zero, opacity: 0.9)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        let outside = rep?.colorAt(x: 150, y: 90)?.brightnessComponent ?? 1
        #expect(outside < 0.95)
    }

    @Test func presentationShadowHonorsZeroOpacityAndRadius() {
        let base = solidImage(width: 100, height: 100, red: 1, green: 1, blue: 1)
        let shadows = [
            Presentation.Shadow(radius: 0, offset: .zero, opacity: 0.9),
            Presentation.Shadow(radius: 0.06, offset: .zero, opacity: 0)
        ]

        for shadow in shadows {
            let presentation = Presentation(
                canvas: .preset(pixelSize: CGSize(width: 300, height: 300)),
                background: .solid(.white),
                image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 1.0 / 3.0),
                shadow: shadow
            )
            let rep = AnnotationRenderer.renderBitmap(
                base: base, annotations: [], presentation: presentation)
            let outside = rep?.colorAt(x: 150, y: 90)?.brightnessComponent ?? 0
            #expect(outside > 0.99)
        }
    }

    @Test func presentationShadowOffsetMovesDarknessDownward() {
        let base = solidImage(width: 100, height: 100, red: 1, green: 1, blue: 1)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 300, height: 300)),
            background: .solid(.white),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 1.0 / 3.0),
            shadow: Presentation.Shadow(
                radius: 0.06, offset: CGPoint(x: 0, y: 0.12), opacity: 0.9
            )
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)
        let above = rep?.colorAt(x: 150, y: 80)?.brightnessComponent ?? 1
        let below = rep?.colorAt(x: 150, y: 220)?.brightnessComponent ?? 1
        #expect(below < above)
    }

    @Test func presentationShadowDoesNotPaintTransparentImageCornersBlack() {
        let base = roundedTransparentImage(width: 100, height: 100, radius: 24)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 300, height: 300)),
            background: .solid(.white),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 1.0 / 3.0),
            shadow: Presentation.Shadow(radius: 0.06, offset: .zero, opacity: 0.9)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        let transparentCorner = rep?.colorAt(x: 101, y: 101)?.brightnessComponent ?? 0
        #expect(transparentCorner > 0.95)
    }

    @Test func meshBackgroundIsContinuousAcrossTheCanvas() {
        let base = solidImage(width: 10, height: 10, red: 1, green: 1, blue: 1)
        let black = Presentation.Color.black
        let white = Presentation.Color.white
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 1600, height: 900)),
            background: .mesh(colors: [black, white, black, white]),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.1)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)
        let levels = (0..<1600).map { x in
            Int(((rep?.colorAt(x: x, y: 100)?.redComponent ?? 0) * 255).rounded())
        }
        let maximumJump = zip(levels, levels.dropFirst())
            .map { abs($0.0 - $0.1) }
            .max() ?? 255

        #expect(maximumJump <= 2)
        #expect((rep?.colorAt(x: 0, y: 100)?.redComponent ?? 1) < 0.05)
        #expect((rep?.colorAt(x: 1599, y: 100)?.redComponent ?? 0) > 0.95)
    }

    @Test func meshBackgroundRepeatsShortPalettes() {
        let base = solidImage(width: 8, height: 8, red: 1, green: 1, blue: 1)
        let red = Presentation.Color(red: 1, green: 0, blue: 0, alpha: 1)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 80, height: 80)),
            background: .mesh(colors: [red]),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.1)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)
        let corner = rep?.colorAt(x: 0, y: 0)
        #expect((corner?.redComponent ?? 0) > 0.9)
        #expect((corner?.greenComponent ?? 1) < 0.1)
        #expect((corner?.blueComponent ?? 1) < 0.1)
    }

    @Test func noBackgroundLeavesTheCanvasTransparent() {
        let base = solidImage(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 80, height: 80)),
            background: .none,
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.4)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        // Corner is canvas, centre is the image: one must be see-through and
        // the other must not, or "no background" is indistinguishable from
        // white on export.
        #expect((rep?.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
        #expect((rep?.colorAt(x: 40, y: 40)?.alphaComponent ?? 0) > 0.99)
    }

    @Test func radialGradientPutsTheFirstStopInTheMiddle() {
        let base = solidImage(width: 4, height: 4, red: 1, green: 1, blue: 1)
        let inner = Presentation.Color(red: 1, green: 0, blue: 0, alpha: 1)
        let outer = Presentation.Color(red: 0, green: 0, blue: 1, alpha: 1)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 100, height: 100)),
            background: .radialGradient(stops: Presentation.Stop.spread([inner, outer])),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.04)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        #expect((rep?.colorAt(x: 2, y: 2)?.blueComponent ?? 0) > 0.8)   // corner: outer
        #expect((rep?.colorAt(x: 2, y: 2)?.redComponent ?? 1) < 0.2)
        // Just outside the tiny image, still near the centre: inner stop.
        #expect((rep?.colorAt(x: 50, y: 44)?.redComponent ?? 0) > 0.6)
    }

    @Test func aThirdGradientStopChangesTheMiddleOfTheCanvas() {
        let base = solidImage(width: 4, height: 4, red: 1, green: 1, blue: 1)
        let black = Presentation.Color(red: 0, green: 0, blue: 0, alpha: 1)
        let green = Presentation.Color(red: 0, green: 1, blue: 0, alpha: 1)
        let canvas = CGSize(width: 100, height: 100)
        func middleGreen(_ stops: [Presentation.Stop]) -> CGFloat {
            let presentation = Presentation(
                canvas: .preset(pixelSize: canvas),
                // Horizontal sweep so the vertical middle is a pure stop.
                background: .linearGradient(stops: stops, angle: 0),
                image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.04)
            )
            let rep = AnnotationRenderer.renderBitmap(
                base: base, annotations: [], presentation: presentation)
            return rep?.colorAt(x: 50, y: 8)?.greenComponent ?? 0
        }

        #expect(middleGreen(Presentation.Stop.spread([black, black])) < 0.1)
        #expect(middleGreen(Presentation.Stop.spread([black, green, black])) > 0.8)
    }

    /// A stop paints where its position says, not where its turn in the list
    /// would have put it. This is the whole point of giving stops positions —
    /// and it is checked in pixels, because the model can be right about
    /// numbers the renderer never passes on.
    @Test func aStopPaintsWhereItsPositionSays() {
        let base = solidImage(width: 4, height: 4, red: 1, green: 1, blue: 1)
        let black = Presentation.Color(red: 0, green: 0, blue: 0, alpha: 1)
        let green = Presentation.Color(red: 0, green: 1, blue: 0, alpha: 1)
        let canvas = CGSize(width: 100, height: 100)

        func greenAt(_ x: Int, _ stops: [Presentation.Stop]) -> CGFloat {
            let presentation = Presentation(
                canvas: .preset(pixelSize: canvas),
                background: .linearGradient(stops: stops, angle: 0),
                image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.04)
            )
            let rep = AnnotationRenderer.renderBitmap(
                base: base, annotations: [], presentation: presentation)
            return rep?.colorAt(x: x, y: 8)?.greenComponent ?? 0
        }

        // The ramp runs corner to corner, so it is wider than the canvas: it
        // spans hypot(100, 100) ≈ 141 centred on 50, and a stop at 0.25 lands
        // at 50 − 141/4 ≈ 15.
        let quarter = [Presentation.Stop(black, at: 0),
                       Presentation.Stop(green, at: 0.25),
                       Presentation.Stop(black, at: 1)]
        // The same three colours spread evenly put the green in the middle
        // instead — which is all the old model could say.
        let evenly = Presentation.Stop.spread([black, green, black])

        // Where the green *peaks* is the claim; the ramp is 141 wide, so it
        // falls away gently and an absolute threshold on the far side would
        // only be testing the slope.
        #expect(greenAt(15, quarter) > 0.8)
        #expect(greenAt(50, evenly) > 0.8)
        #expect(greenAt(15, quarter) > greenAt(50, quarter))
        #expect(greenAt(50, evenly) > greenAt(15, evenly))
    }

    /// The reported bug: `drawLinearGradient` paints the whole clip region, not
    /// the rect it is given, so in the live preview a gradient flooded well past
    /// the canvas it belonged to.
    @Test func aGradientStaysInsideTheRectItIsGiven() {
        let ctx = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))

        PresentationRenderer.drawBackground(
            .linearGradient(stops: Presentation.Stop.spread([.black, .black]), angle: 0),
            in: CGRect(x: 30, y: 30, width: 40, height: 40),
            ctx: ctx
        )

        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        #expect((rep.colorAt(x: 50, y: 50)?.redComponent ?? 1) < 0.1)   // inside: painted
        #expect((rep.colorAt(x: 5, y: 5)?.redComponent ?? 0) > 0.9)     // outside: untouched
        #expect((rep.colorAt(x: 95, y: 95)?.redComponent ?? 0) > 0.9)
    }

    /// Commentary is measured in canvas pixels, so it can sit on the decorated
    /// background — and it stays put no matter what happens to the picture
    /// inside the canvas.
    @Test func commentaryIsPlacedAndKeptInCanvasPixels() {
        let base = solidImage(width: 100, height: 100, red: 1, green: 1, blue: 1)
        let green = Presentation.Color(red: 0, green: 1, blue: 0, alpha: 1)
        // Canvas 200×200 with the image fitted at (50,50,100,100).
        func render(scale: CGFloat, canvas: CGSize) -> NSBitmapImageRep? {
            let line = Annotation(kind: .line, start: CGPoint(x: 10, y: 25),
                                  end: CGPoint(x: 40, y: 25), color: .red, lineWidth: 10)
            return AnnotationRenderer.renderBitmap(
                base: base, annotations: [line],
                presentation: Presentation(
                    canvas: .preset(pixelSize: canvas),
                    background: .solid(green),
                    image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: scale)
                )
            )
        }

        // On the background, in canvas coordinates.
        let plain = render(scale: 0.5, canvas: CGSize(width: 200, height: 200))
        #expect((plain?.colorAt(x: 25, y: 25)?.redComponent ?? 0) > 0.5)
        #expect((plain?.colorAt(x: 25, y: 25)?.greenComponent ?? 1) < 0.5)

        // Shrinking the picture inside the canvas must not move it.
        let scaled = render(scale: 0.3, canvas: CGSize(width: 200, height: 200))
        #expect((scaled?.colorAt(x: 25, y: 25)?.redComponent ?? 0) > 0.5)

        // Nor must a taller canvas: the same canvas pixels are still its home.
        let taller = render(scale: 0.5, canvas: CGSize(width: 200, height: 300))
        #expect((taller?.colorAt(x: 25, y: 25)?.redComponent ?? 0) > 0.5)
    }

    /// The redaction is measured in image pixels, so it travels with what it
    /// hides. If it did not, scaling the picture would slide the blur off the
    /// thing the user covered up.
    @Test func aRedactionTravelsWithThePictureItHides() {
        // Left half black, right half white: the blur has something to smear.
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let base = ctx.makeImage()!

        // A blur covering the image's own top-left quarter.
        var blur = Annotation(kind: .blur, start: CGPoint(x: 0, y: 0),
                              end: CGPoint(x: 50, y: 50), color: .red, lineWidth: 1)
        blur.blurStyle = .pixelate
        let source = AnnotationRenderer.makePixelated(base: base)!

        func imageRect(_ scale: CGFloat) -> CGRect {
            PresentationLayout.resolve(
                imagePixelSize: CGSize(width: 100, height: 100),
                Presentation(canvas: .preset(pixelSize: CGSize(width: 200, height: 200)),
                             image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: scale))
            ).imageRect
        }

        // Whatever the picture's scale, the blur's canvas position is derived
        // from the image rect — that is what "travels with it" means.
        let full = imageRect(0.5)
        let half = imageRect(0.3)
        #expect(full != half)
        #expect(blur.livesInImageSpace)
        #expect(Annotation(kind: .arrow, start: .zero, end: .zero,
                           color: .red, lineWidth: 1).livesInImageSpace == false)
        _ = source
    }

    /// …but the picture itself is still confined to its rounded frame, so a
    /// redaction cannot leak onto the background.
    @Test func theImageItselfStaysInsideItsFrame() {
        let base = solidImage(width: 100, height: 100, red: 1, green: 0, blue: 0)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 200, height: 200)),
            background: .solid(Presentation.Color(red: 0, green: 1, blue: 0, alpha: 1)),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.5)
        )

        let rep = AnnotationRenderer.renderBitmap(
            base: base, annotations: [], presentation: presentation)

        #expect((rep?.colorAt(x: 25, y: 25)?.greenComponent ?? 0) > 0.9)
        #expect((rep?.colorAt(x: 100, y: 100)?.redComponent ?? 0) > 0.9)
    }

    @Test func shadowUsesItsOwnColorAndBothOffsets() {
        let base = solidImage(width: 40, height: 40, red: 1, green: 1, blue: 1)
        func render(offset: CGPoint, color: Presentation.Color) -> NSBitmapImageRep? {
            AnnotationRenderer.renderBitmap(
                base: base, annotations: [],
                presentation: Presentation(
                    canvas: .preset(pixelSize: CGSize(width: 200, height: 200)),
                    background: .solid(.white),
                    image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.4),
                    shadow: Presentation.Shadow(radius: 0.05, offset: offset,
                                                opacity: 0.9, color: color)
                )
            )
        }
        let blue = Presentation.Color(red: 0, green: 0, blue: 1, alpha: 1)

        // A blue shadow must read as blue, not as grey.
        let tinted = render(offset: CGPoint(x: 0, y: 0.03), color: blue)
        let below = tinted?.colorAt(x: 100, y: 148)
        #expect((below?.blueComponent ?? 0) - (below?.redComponent ?? 1) > 0.2)

        // Horizontal offset must move darkness sideways, which the old
        // single-axis control could not express at all.
        let sideways = render(offset: CGPoint(x: 0.05, y: 0), color: .black)
        let right = sideways?.colorAt(x: 148, y: 100)?.redComponent ?? 1
        let left = sideways?.colorAt(x: 52, y: 100)?.redComponent ?? 0
        #expect(right < left)
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

    @Test func curvedArrowCapDoesNotPokePastTip() {
        // The round shaft cap must tuck under the arrowhead: no ink should
        // sit ahead of the tip along the approach direction.
        let base = TestImages.make(width: 80, height: 60)  // all white
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 50),
                               end: CGPoint(x: 60, y: 30), color: .black, lineWidth: 6)
        arrow.curveControl = CGPoint(x: 30, y: 20)   // bows upward
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [arrow])!

        // A few px beyond the tip (continuing the control→tip direction) must
        // stay white — the old round cap left a nub here.
        let dx = arrow.end.x - arrow.curveControl!.x
        let dy = arrow.end.y - arrow.curveControl!.y
        let length = hypot(dx, dy)
        for ahead in stride(from: CGFloat(5), through: 9, by: 1) {
            let x = Int((arrow.end.x + dx / length * ahead).rounded())
            let y = Int((arrow.end.y + dy / length * ahead).rounded())
            #expect((rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) > 0.9)
        }
        // Sanity: the arrowhead itself is inked (scan its body, just behind
        // the tip, rather than the razor-thin apex pixel).
        let headInked = (48...58).contains { x in
            (26...36).contains { y in
                (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5
            }
        }
        #expect(headInked)
    }

    @Test func arrowheadIsAnOpenChevronNotAFilledTriangle() {
        // Head at (110,40); barbs run to ~(93.8, 47.8)/(93.8, 32.2). The two
        // strokes and the shaft are inked, but the triangle's interior between
        // the shaft and a barb stays white — a filled head would fill it.
        let base = TestImages.make(width: 120, height: 80)   // all white
        let arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 40),
                               end: CGPoint(x: 110, y: 40), color: .black, lineWidth: 3)
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [arrow])!
        #expect((rep.colorAt(x: 60, y: 40)?.brightnessComponent ?? 1) < 0.5)  // shaft
        #expect((rep.colorAt(x: 94, y: 47)?.brightnessComponent ?? 1) < 0.6)  // lower barb
        // Interior gap between shaft and lower barb — white for an open head.
        #expect((rep.colorAt(x: 95, y: 44)?.brightnessComponent ?? 0) > 0.9)
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

    // MARK: arrow binding (rendered from resolved endpoints)

    @Test func boundArrowStopsAtShapeOutlineWithHeadOnBoundary() {
        // Circle target r20 centered (60,60). The arrow comes straight down
        // from above with its tip bound to the circle; it must stop at the
        // top of the circle (y≈40), not run through to its raw end (60,110).
        let base = TestImages.make(width: 120, height: 120)   // all white
        let oval = Annotation(kind: .oval, start: CGPoint(x: 40, y: 40),
                              end: CGPoint(x: 80, y: 80), color: .black, lineWidth: 2)
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 60, y: 10),
                               end: CGPoint(x: 60, y: 110), color: .black, lineWidth: 4)
        arrow.endBinding = EndpointBinding(
            targetID: oval.id, anchor: .fixed(unit: CGPoint(x: 0.5, y: 0)),
            fallback: .zero)
        let rep = AnnotationRenderer.renderBitmap(base: base,
                                                  annotations: [oval, arrow])!
        // Shaft inked above the shape.
        #expect((rep.colorAt(x: 60, y: 25)?.brightnessComponent ?? 1) < 0.5)
        // Circle interior stays clear — the arrow ended at the boundary rather
        // than crossing to its stale raw end deep below.
        #expect((rep.colorAt(x: 60, y: 60)?.brightnessComponent ?? 0) > 0.9)
        #expect((rep.colorAt(x: 60, y: 72)?.brightnessComponent ?? 0) > 0.9)
        // Arrowhead sits on the boundary: its barbs flank the tip off the
        // 4px-wide shaft column.
        #expect((rep.colorAt(x: 57, y: 30)?.brightnessComponent ?? 1) < 0.5)
        #expect((rep.colorAt(x: 63, y: 30)?.brightnessComponent ?? 1) < 0.5)
    }

    @Test func boundArrowFallsBackToStoredPointWhenTargetMissing() {
        // No target with this id exists, so the bound end degrades to its
        // fallback (50,40): the arrow draws from (10,40) to there, and the
        // region past the fallback toward the raw end stays white.
        let base = TestImages.make(width: 100, height: 80)    // all white
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 40),
                               end: CGPoint(x: 90, y: 40), color: .black, lineWidth: 4)
        arrow.endBinding = EndpointBinding(
            targetID: UUID(), anchor: .fixed(unit: CGPoint(x: 0, y: 0.5)),
            fallback: CGPoint(x: 50, y: 40))
        let rep = AnnotationRenderer.renderBitmap(base: base, annotations: [arrow])!
        #expect((rep.colorAt(x: 30, y: 40)?.brightnessComponent ?? 1) < 0.5)  // shaft
        #expect((rep.colorAt(x: 75, y: 40)?.brightnessComponent ?? 0) > 0.9)  // past fallback
    }

    @Test func movingTargetMovesBoundArrowTip() {
        // The tip follows the target with no stored state: rendering the same
        // arrow against a moved circle inks a different region.
        let base = TestImages.make(width: 160, height: 80)    // all white
        var oval = Annotation(kind: .oval, start: CGPoint(x: 40, y: 20),
                              end: CGPoint(x: 80, y: 60), color: .black, lineWidth: 2)
        var arrow = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 40),
                               end: CGPoint(x: 150, y: 40), color: .black, lineWidth: 4)
        arrow.endBinding = EndpointBinding(
            targetID: oval.id, anchor: .fixed(unit: CGPoint(x: 0, y: 0.5)),
            fallback: .zero)
        // Circle left edge at x=40 → tip stops near there; x=90 stays white.
        let before = AnnotationRenderer.renderBitmap(base: base,
                                                     annotations: [oval, arrow])!
        #expect((before.colorAt(x: 90, y: 40)?.brightnessComponent ?? 0) > 0.9)
        // Move the circle right by 60; its left edge is now x=100, so the
        // shaft reaches x=90 where it was white before.
        oval.move(by: CGPoint(x: 60, y: 0))
        let after = AnnotationRenderer.renderBitmap(base: base,
                                                    annotations: [oval, arrow])!
        #expect((after.colorAt(x: 90, y: 40)?.brightnessComponent ?? 1) < 0.5)
    }

    // MARK: loupe

    /// Solid-color image for deterministic loupe/blur source tests.
    /// A picture dragged clean off the page is the one object the user cannot
    /// get back by any other means — it is what they grab to drag it. Drawn
    /// only inside the canvas, it left the editor showing a bare background.
    @Test func thePictureStaysVisibleAfterItLeavesTheCanvas() {
        let base = solidImage(width: 100, height: 100, red: 1, green: 0, blue: 0)
        // A 100×100 page with the picture sitting entirely to its left.
        let layout = PresentationLayout.Resolved(
            canvasSize: CGSize(width: 100, height: 100),
            imageRect: CGRect(x: -120, y: 0, width: 100, height: 100)
        )
        // Room around the page for the ghost to land in: the page occupies
        // (150, 150)…(250, 250) of a 400×400 sheet.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let gc = NSGraphicsContext(bitmapImageRep: rep)!
        let ctx = gc.cgContext
        ctx.translateBy(x: 150, y: 150)

        PresentationRenderer.drawGhostOutsideCanvas(
            in: ctx, base: base, blurSources: [:], annotations: [], layout: layout
        )
        ctx.flush()

        // Centre of where the picture went: 150 + (-120 + 50) = 80.
        let ghost = rep.colorAt(x: 80, y: 200)
        #expect((ghost?.alphaComponent ?? 0) > 0.1)
        #expect((ghost?.redComponent ?? 0) > 0.5)
        // The page itself is left alone — the ghost is an outside-only pass.
        #expect((rep.colorAt(x: 200, y: 200)?.alphaComponent ?? 1) < 0.01)
    }

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

    private func roundedTransparentImage(width: Int, height: Int,
                                        radius: CGFloat) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        ctx.fillPath()
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

    @Test func calloutLoupeMagnifiesSourceRegionAndDrawsConnector() {
        // Display over the black half, source aimed at the white half: the
        // magnifier must show the source's pixels, not what's beneath it.
        var loupe = Annotation(kind: .loupe, start: CGPoint(x: 5, y: 5),
                               end: CGPoint(x: 25, y: 25), color: .red, lineWidth: 3)
        loupe.loupeScale = 2
        loupe.loupeSource = CGPoint(x: 45, y: 30)
        loupe.loupeSourceSize = CGSize(width: 10, height: 10)
        let rep = AnnotationRenderer.renderBitmap(base: halfToneBase(),
                                                  annotations: [loupe])!
        let inside = rep.colorAt(x: 15, y: 15)?.brightnessComponent ?? 0
        #expect(inside > 0.9)
        // The connector runs between the bodies in the annotation color.
        if let (from, to) = loupe.loupeConnectorPoints() {
            let mid = rep.colorAt(x: Int(((from.x + to.x) / 2).rounded()),
                                  y: Int(((from.y + to.y) / 2).rounded()))
            #expect((mid?.redComponent ?? 0) > 0.7)
            #expect((mid?.greenComponent ?? 1) < 0.5)
        } else {
            Issue.record("connector expected for separated bodies")
        }
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
        #expect(AnnotationFontPreset.allCases.count == 10)
        let latin = CharacterSet(charactersIn: "Aa0123")
        let cyrillic = CharacterSet(charactersIn: "БбЯяЁё")
        for preset in AnnotationFontPreset.allCases {
            let font = preset.nsFont(ofSize: 18)
            #expect(font.coveredCharacterSet.isSuperset(of: latin),
                    "\(preset.displayName) must support Latin")
            // Papyrus is the one curated preset without Cyrillic; those
            // glyphs render through the system-font fallback.
            guard preset != .papyrus else { continue }
            #expect(font.coveredCharacterSet.isSuperset(of: cyrillic),
                    "\(preset.displayName) must support Cyrillic")
        }
    }

    @Test func textAttributesCarryParagraphAlignment() {
        var a = Annotation(kind: .text, start: .zero, end: .zero,
                           color: .red, lineWidth: 4)
        a.textAlignment = .center
        let paragraph = AnnotationRenderer.textAttributes(for: a)[.paragraphStyle]
            as? NSParagraphStyle
        #expect(paragraph?.alignment == .center)
    }

    @Test func stepLabelSizeShrinksButNeverExceedsFit() {
        var a = Annotation(kind: .step, start: .zero, end: .zero,
                           color: .red, lineWidth: 4)
        a.stepDiameter = 40
        let fitted = AnnotationRenderer.stepFont(for: a).pointSize
        a.stepLabelSize = 10
        #expect(AnnotationRenderer.stepFont(for: a).pointSize == 10)
        a.stepLabelSize = 500   // caps at the fitted size — never spills out
        #expect(AnnotationRenderer.stepFont(for: a).pointSize == fitted)
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

    /// The share export names its temp file from this, so it has to fall back
    /// to png exactly where `encoding(for:)` does — otherwise a shared file
    /// would carry an extension its bytes don't match.
    @Test(arguments: [
        ("png", "png"), ("jpg", "jpg"), ("tiff", "tiff"),
        ("webp", "png"), ("", "png"),
    ])
    func extensionMapping(format: String, expected: String) {
        #expect(ScreenshotFileStore.fileExtension(for: format) == expected)
    }
}
