import CoreGraphics
import Testing
@testable import Stampo

/// A format used to be a pixel size, so choosing one resampled the picture.
/// Now it is a shape and the page is derived — which only works if the
/// derivation is stable under repetition, so most of this suite is about
/// pressing the chips more than once.
@Suite struct CanvasRatioTests {

    /// A 2400×1400 shot on an auto page with 168px margins — the ordinary case.
    private func wideLayout(margin: CGFloat = 168) -> (CGSize, Presentation) {
        let image = CGSize(width: 2400, height: 1400)
        return (image, Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                                    background: .solid(.white)))
    }

    private func resolved(_ image: CGSize, _ presentation: Presentation) -> PresentationLayout.Resolved {
        PresentationLayout.resolve(imagePixelSize: image, presentation)
    }

    private let fourFive = CanvasRatio(width: 4, height: 5, titleKey: "Instagram 4:5")
    private let sixteenNine = CanvasRatio(width: 16, height: 9, titleKey: "Twitter / X")

    /// The picture keeps every one of its pixels: the page grows around it
    /// instead of the picture shrinking into the page.
    @Test func aFormatAddsAirRatherThanResamplingThePicture() {
        let (image, presentation) = wideLayout()
        let page = CanvasRatio.page(for: fourFive, in: resolved(image, presentation))

        #expect(page == CGSize(width: 2736, height: 3420))
        #expect(page.width >= image.width)
        #expect(fourFive.matches(page))
    }

    /// The whole reason the derivation takes the *tightest* gap: air added for
    /// one ratio must not count as content for the next one.
    @Test func switchingBetweenFormatsAndBackLandsWhereItStarted() {
        let (image, presentation) = wideLayout()

        var page = CanvasRatio.page(for: fourFive, in: resolved(image, presentation))
        var current = presentation
        current.canvas = .preset(pixelSize: page)
        current.image = CanvasRatio.placement(keepingDrawnSizeOf: resolved(image, presentation),
                                              from: presentation.image,
                                              imagePixelSize: image, on: page)
        let first = page

        page = CanvasRatio.page(for: sixteenNine, in: resolved(image, current))
        current.image = CanvasRatio.placement(keepingDrawnSizeOf: resolved(image, current),
                                              from: current.image,
                                              imagePixelSize: image, on: page)
        current.canvas = .preset(pixelSize: page)
        #expect(page == CGSize(width: 3086, height: 1736))

        page = CanvasRatio.page(for: fourFive, in: resolved(image, current))
        #expect(page == first)
    }

    @Test func theSameFormatTwiceChangesNothing() {
        let (image, presentation) = wideLayout()
        let page = CanvasRatio.page(for: fourFive, in: resolved(image, presentation))
        var current = presentation
        current.canvas = .preset(pixelSize: page)
        current.image = CanvasRatio.placement(keepingDrawnSizeOf: resolved(image, presentation),
                                              from: presentation.image,
                                              imagePixelSize: image, on: page)

        #expect(CanvasRatio.page(for: fourFive, in: resolved(image, current)) == page)
    }

    /// Swapping is its own operation, not a rotation of the picture: the page
    /// turns and the picture stays the size it was drawn at.
    @Test func swappingSidesTwiceReturnsTheSameShape() {
        #expect(sixteenNine.swapped == CanvasRatio(width: 9, height: 16, titleKey: "Twitter / X"))
        #expect(sixteenNine.swapped.swapped == sixteenNine)
    }

    /// A picture the user shrank stays shrunk — the page is built around what
    /// is drawn, not around the file's own pixels.
    @Test func aScaledDownPictureKeepsItsSize() {
        let image = CGSize(width: 2400, height: 1400)
        let presentation = Presentation(canvas: .preset(pixelSize: CGSize(width: 2400, height: 1400)),
                                        background: .solid(.white),
                                        image: Presentation.ImagePlacement(
                                            center: CGPoint(x: 0.5, y: 0.5), scale: 0.5))
        let layout = resolved(image, presentation)
        let page = CanvasRatio.page(for: fourFive, in: layout)
        let placement = CanvasRatio.placement(keepingDrawnSizeOf: layout,
                                              from: presentation.image,
                                              imagePixelSize: image, on: page)
        var moved = presentation
        moved.canvas = .preset(pixelSize: page)
        moved.image = placement

        let drawn = resolved(image, moved).imageRect.width
        #expect(abs(drawn - layout.imageRect.width) < 1)
    }

    /// Three shapes of shot, to catch a rule that only works on one of them.
    @Test func everyShapeOfShotGetsAPageOfTheRatioAsked() {
        let cases: [(CGSize, CGFloat)] = [
            (CGSize(width: 2400, height: 1400), 168),   // window
            (CGSize(width: 1200, height: 2000), 144),   // phone
            (CGSize(width: 600, height: 400), 48)       // small crop
        ]
        for (image, margin) in cases {
            let presentation = Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                                            background: .solid(.white))
            for ratio in CanvasRatio.presets {
                let page = CanvasRatio.page(for: ratio, in: resolved(image, presentation))
                #expect(ratio.matches(page), "\(image) at \(ratio.width):\(ratio.height) → \(page)")
                #expect(page.width >= image.width, "\(image) lost width at \(page)")
                #expect(page.height >= image.height, "\(image) lost height at \(page)")
            }
        }
    }

    /// The chip is lit by the page's *shape*, not by a remembered pick — so a
    /// size typed into the inspector lights the matching chip, and a shape of
    /// nobody's lights none.
    @Test func theSelectedChipIsReadOffThePage() {
        #expect(CanvasRatio.preset(matching: CGSize(width: 1000, height: 1000))?.titleKey == "Square")
        #expect(CanvasRatio.preset(matching: CGSize(width: 2736, height: 3420))?.titleKey == "Instagram 4:5")
        // Portrait counts as the same format turned.
        #expect(CanvasRatio.preset(matching: CGSize(width: 900, height: 1600))?.titleKey == "Twitter / X")
        #expect(CanvasRatio.preset(matching: CGSize(width: 1237, height: 641)) == nil)
    }

    /// After a swap the lit chip has to say 5:4, and the rest have to go on
    /// saying what they say. A derived page is what makes this a rule rather
    /// than a formatting detail: 5:4 comes out as 2736×2189, which reduces to
    /// nothing at all and would print as "1.25:1".
    @Test func onlyTheChipThatMatchesFollowsThePage() {
        let landscape = CGSize(width: 2736, height: 2189)   // 4:5, swapped
        let portrait = CGSize(width: 2736, height: 3420)    // 4:5, as written

        #expect(CanvasRatio.shown(fourFive, matching: landscape) == fourFive.swapped)
        #expect(CanvasRatio.shown(fourFive, matching: portrait) == fourFive)
        // A format the page is not in is left alone either way round.
        #expect(CanvasRatio.shown(sixteenNine, matching: landscape) == sixteenNine)
        #expect(CanvasRatio.shown(sixteenNine, matching: portrait) == sixteenNine)
    }

    @Test func aRatioReadsAsPeopleWriteIt() {
        #expect(CanvasRatio.label(for: CGSize(width: 1600, height: 900)) == "16:9")
        #expect(CanvasRatio.label(for: CGSize(width: 2736, height: 3420)) == "4:5")
        #expect(CanvasRatio.label(for: CGSize(width: 1200, height: 630)) == "1.90:1")
        #expect(CanvasRatio.label(for: CGSize(width: 1237, height: 641)) == "1.93:1")
        #expect(CanvasRatio.label(for: CGSize(width: 0, height: 10)) == "—")
    }

    /// The chips' labels come out of the same reduction — whole numbers while
    /// it stays small, a decimal against 1 when it does not.
    @Test func aRatioReducesTheWayTheChipsPrintIt() {
        let sixteenToNine = CanvasRatio.parts(for: CGSize(width: 1600, height: 900))
        #expect(sixteenToNine == (16, 9))

        let awkward = CanvasRatio.parts(for: CGSize(width: 1237, height: 641))
        #expect(awkward.0 == 1.93)
        #expect(awkward.1 == 1)

        let tall = CanvasRatio.parts(for: CGSize(width: 641, height: 1237))
        #expect(tall.0 == 1)
        #expect(tall.1 == 1.93)
    }

    @Test func nonsenseIsNoRatioAtAll() {
        #expect(CanvasRatio.typed(width: 0, height: 5) == nil)
        #expect(CanvasRatio.typed(width: 4, height: -1) == nil)
        #expect(CanvasRatio.typed(width: .infinity, height: 1) == nil)
        #expect(CanvasRatio.typed(width: 4, height: 5)?.value == 0.8)
    }
}
