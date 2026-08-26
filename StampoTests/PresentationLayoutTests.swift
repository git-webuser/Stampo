import CoreGraphics
import Foundation
import Testing
@testable import Stampo

@MainActor
@Suite struct PresentationLayoutTests {
    private func makeDocument() -> EditorDocument {
        EditorDocument(baseImage: TestImages.make(width: 8, height: 8),
                       sourceURL: URL(fileURLWithPath: "/tmp/presentation.png"))
    }

    private func expectClose(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.0001) {
        #expect(abs(lhs - rhs) < tolerance)
    }

    @Test func nilPresentationDoesNotChangeRevisionOrDirtyState() {
        let document = makeDocument()
        let revision = document.revision

        document.presentation = nil

        #expect(document.presentation == nil)
        #expect(document.revision == revision)
        #expect(!document.isDirty)
    }

    @Test func presentationChangeIsDirtyAndUndoableAsOneStep() {
        let document = makeDocument()
        let initial = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 1600, height: 900)),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.84)
        )
        document.presentation = initial
        document.markSaved()

        let changed = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 1080, height: 1350)),
            image: .init(center: CGPoint(x: 0.5, y: 0.55), scale: 0.76)
        )
        document.beginChange()
        document.presentation = changed
        document.commitChange()

        #expect(document.isDirty)
        #expect(document.undoStack.count == 1)
        document.undo()
        #expect(document.presentation == initial)
        #expect(!document.canUndo)
    }

    @Test func nilResolverPreservesNativeImageGeometry() {
        let imageSize = CGSize(width: 1200, height: 800)
        let resolved = PresentationLayout.resolve(imagePixelSize: imageSize, nil)

        #expect(resolved.canvasSize == imageSize)
        #expect(resolved.imageRect == CGRect(origin: .zero, size: imageSize))
    }

    @Test func canvasAspectRatioIsDerivedFromPixelSize() {
        let canvas = Presentation.Canvas.preset(pixelSize: CGSize(width: 1600, height: 900))

        #expect(abs(canvas.aspectRatio - 16.0 / 9.0) < 0.0001)
    }

    @Test func nilPresentationKeepsLegacyViewportMath() {
        let viewport = CGSize(width: 900, height: 700)
        let imageSize = CGSize(width: 1200, height: 800)
        let pan = CGSize(width: 7, height: -11)
        let resolved = EditorCanvasGeometry.resolve(
            viewport: viewport,
            imagePixelSize: imageSize,
            presentation: nil,
            zoom: 1.5,
            pan: pan
        )

        // The old formula: 24pt inset, no upscaling at zoom 1, then zoom and
        // pan around the viewport center.
        let baseFitScale: CGFloat = min((900.0 - 48) / 1200,
                                        (700.0 - 48) / 800)
        let oldBaseDrawSize = CGSize(width: 1200.0 * baseFitScale,
                                     height: 800.0 * baseFitScale)
        let oldFitScale = baseFitScale * 1.5
        let oldDrawSize = CGSize(width: oldBaseDrawSize.width * 1.5,
                                 height: oldBaseDrawSize.height * 1.5)
        let oldOffset = CGPoint(
            x: (viewport.width - oldDrawSize.width) / 2 + pan.width,
            y: (viewport.height - oldDrawSize.height) / 2 + pan.height
        )

        expectClose(resolved.imageFitScale, oldFitScale)
        expectClose(resolved.canvasBaseDrawSize.width, oldBaseDrawSize.width)
        expectClose(resolved.canvasBaseDrawSize.height, oldBaseDrawSize.height)
        expectClose(resolved.imageDrawSize.width, oldDrawSize.width)
        expectClose(resolved.imageDrawSize.height, oldDrawSize.height)
        expectClose(resolved.imageOffset.x, oldOffset.x)
        expectClose(resolved.imageOffset.y, oldOffset.y)
    }

    @Test func paddingAndFitProduceExpectedImageRect() {
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 1000, height: 800)),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.8)
        )
        let resolved = PresentationLayout.resolve(
            imagePixelSize: CGSize(width: 400, height: 200), presentation
        )

        #expect(resolved.canvasSize == CGSize(width: 1000, height: 800))
        expectClose(resolved.imageRect.minX, 100)
        expectClose(resolved.imageRect.minY, 200)
        expectClose(resolved.imageRect.width, 800)
        expectClose(resolved.imageRect.height, 400)
    }

    /// Negative padding is the picture reaching past the canvas — the job the
    /// old separate scale slider did, expressed by the one control that stayed.
    @Test func negativePaddingOverflowsTheCanvasWithoutClamping() {
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 1000, height: 1000)),
            image: .init(center: CGPoint(x: 0.6, y: 0.3), scale: 1.5)
        )
        let resolved = PresentationLayout.resolve(
            imagePixelSize: CGSize(width: 400, height: 200), presentation
        )

        expectClose(resolved.imageRect.width, 1500)
        expectClose(resolved.imageRect.height, 750)
        expectClose(resolved.imageRect.minX, -150)
        expectClose(resolved.imageRect.minY, 125 - 200)
    }

    @Test func oppositeAspectRatiosKeepTheImageCentered() {
        let horizontal = PresentationLayout.resolve(
            imagePixelSize: CGSize(width: 1200, height: 600),
            Presentation(canvas: .preset(pixelSize: CGSize(width: 600, height: 900)))
        )
        expectClose(horizontal.imageRect.width, 600)
        expectClose(horizontal.imageRect.height, 300)
        expectClose(horizontal.imageRect.minY, 300)

        let vertical = PresentationLayout.resolve(
            imagePixelSize: CGSize(width: 600, height: 1200),
            Presentation(canvas: .preset(pixelSize: CGSize(width: 900, height: 600)))
        )
        expectClose(vertical.imageRect.width, 300)
        expectClose(vertical.imageRect.height, 600)
        expectClose(vertical.imageRect.minX, 300)
    }

    @Test func zeroImageSizeDoesNotDivideByZero() {
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 400, height: 400)),
            image: .init(center: CGPoint(x: 0.7, y: 0.4), scale: 1.5)
        )
        let resolved = PresentationLayout.resolve(imagePixelSize: .zero, presentation)

        #expect(resolved.canvasSize == CGSize(width: 400, height: 400))
        #expect(resolved.imageRect.size == .zero)
        #expect(resolved.imageRect.origin.x.isFinite)
        #expect(resolved.imageRect.origin.y.isFinite)
    }

    // MARK: Annotation bounds

    @Test func withoutPresentationAnnotationsAreBoundedByTheImage() {
        let size = CGSize(width: 120, height: 80)
        let resolved = PresentationLayout.resolve(imagePixelSize: size, nil)
        let bounds = PresentationLayout.annotationBounds(imagePixelSize: size, resolved)
        #expect(bounds == CGRect(origin: .zero, size: size))
    }

    @Test func aPaddedCanvasLetsAnnotationsReachTheBackground() {
        let size = CGSize(width: 100, height: 100)
        let presentation = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 200, height: 200)),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.5)
        )
        let resolved = PresentationLayout.resolve(imagePixelSize: size, presentation)
        let bounds = PresentationLayout.annotationBounds(imagePixelSize: size, resolved)

        // Image sits at (50,50,100,100) on a 200pt canvas, so in image
        // coordinates the canvas starts 50 above and left of the picture.
        #expect(abs(bounds.minX - -50) < 0.001)
        #expect(abs(bounds.minY - -50) < 0.001)
        #expect(abs(bounds.width - 200) < 0.001)
        #expect(abs(bounds.height - 200) < 0.001)
    }

    // MARK: Fitting content that left the canvas

    @Test func fitFramesTheCanvasWhenNothingHasLeftIt() {
        let canvas = CGSize(width: 1600, height: 900)
        let zoom = EditorViewportGeometry.fitAll(
            canvasSize: canvas,
            content: CGRect(origin: .zero, size: canvas)
        )
        #expect(zoom == 1)
    }

    /// The canvas stays centred, so it is the *far* side of the content that
    /// decides — half the reach is the half-canvas the zoom is measured
    /// against. Re-centring instead was computed and then clamped away.
    @Test func fitZoomsOutForContentOutsideTheCanvas() {
        let canvas = CGSize(width: 1000, height: 1000)
        // Content spans the canvas and 1000 more to its right, so its far edge
        // is 1500 from the centre against the half-canvas's 500. The other axis
        // is exactly the canvas and does not bind.
        let zoom = EditorViewportGeometry.fitAll(
            canvasSize: canvas,
            content: CGRect(x: 0, y: 0, width: 2000, height: 1000)
        )
        #expect(abs(zoom - 500.0 / 1500.0) < 0.0001)
    }

    /// The picture dragged clean off the left of the page — the case that had
    /// the editor showing a bare background with nothing to grab.
    @Test func fitReachesAPictureDraggedOffThePage() {
        let canvas = CGSize(width: 1000, height: 1000)
        let picture = CGRect(x: -1200, y: 100, width: 800, height: 800)
        let zoom = EditorViewportGeometry.fitAll(
            canvasSize: canvas,
            content: CGRect(origin: .zero, size: canvas).union(picture)
        )
        // Furthest reach from the canvas centre is 1200 + 500 = 1700.
        #expect(abs(zoom - 500 / 1700) < 0.0001)
        // Whatever fit can show, a gesture must be able to reach: at this zoom
        // the viewport spans well under the two canvases of pointer reach.
        #expect(zoom > EditorViewportGeometry.clampedZoom(0))
    }

    @Test func fitSurvivesDegenerateInput() {
        let zoom = EditorViewportGeometry.fitAll(
            canvasSize: .zero,
            content: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        #expect(zoom == 1)
    }

    @Test func ratioLabelsReduceWhenAPersonWouldSayThem() {
        #expect(CanvasRatio.label(for: CGSize(width: 1600, height: 900)) == "16:9")
        #expect(CanvasRatio.label(for: CGSize(width: 1080, height: 1350)) == "4:5")
        #expect(CanvasRatio.label(for: CGSize(width: 1080, height: 1920)) == "9:16")
        // 1200×630 reduces only to 40:21, which nobody says out loud, so the
        // decimal form wins — this is the cutoff the 32-per-side cap draws.
        #expect(CanvasRatio.label(for: CGSize(width: 1200, height: 630)) == "1.90:1")
        // A screenshot size that reduces to nothing useful falls back to decimals.
        #expect(CanvasRatio.label(for: CGSize(width: 1237, height: 641)) == "1.93:1")
        #expect(CanvasRatio.label(for: CGSize(width: 0, height: 10)) == "—")
    }

    // MARK: Gaps are measured, never stored

    /// The old encoding kept four paddings *and* an offset, so the panel's
    /// "padding" number described one stored value rather than the result:
    /// with a 5% padding and a 10% offset it read 45 px while the real gaps
    /// were 240 and −80. Gaps are now a subtraction, so they cannot disagree.
    @Test func gapsAlwaysDescribeWhereThePictureActuallyIs() {
        let image = CGSize(width: 1237, height: 641)
        let canvas = CGSize(width: 1600, height: 900)
        let presentation = Presentation(
            canvas: .preset(pixelSize: canvas),
            image: .init(center: CGPoint(x: 0.6, y: 0.5), scale: 0.9)
        )
        let resolved = PresentationLayout.resolve(imagePixelSize: image, presentation)
        let gaps = PresentationLayout.gaps(resolved)

        expectClose(gaps.leading, resolved.imageRect.minX)
        expectClose(gaps.top, resolved.imageRect.minY)
        expectClose(gaps.trailing, canvas.width - resolved.imageRect.maxX)
        expectClose(gaps.bottom, canvas.height - resolved.imageRect.maxY)
        // Off centre: the two horizontal gaps differ, and their sum plus the
        // picture is exactly the canvas.
        #expect(gaps.leading != gaps.trailing)
        expectClose(gaps.leading + resolved.imageRect.width + gaps.trailing, canvas.width)
    }

    @Test func anOverflowingPictureReportsNegativeGaps() {
        let resolved = PresentationLayout.resolve(
            imagePixelSize: CGSize(width: 100, height: 100),
            Presentation(canvas: .preset(pixelSize: CGSize(width: 200, height: 200)),
                         image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 1.5))
        )
        let gaps = PresentationLayout.gaps(resolved)
        #expect(gaps.leading < 0 && gaps.trailing < 0)
        #expect(gaps.top < 0 && gaps.bottom < 0)
    }

    /// Typing a margin keeps the *opposite* edge and resizes. Moving instead
    /// would make the two ends of an axis fight — setting the top to 100 would
    /// drag the bottom to −100 — and a symmetric frame would be unreachable.
    @Test func typingAMarginResizesAgainstTheOppositeEdge() {
        let image = CGSize(width: 400, height: 200)
        let canvas = CGSize(width: 1000, height: 800)
        var presentation = Presentation(
            canvas: .preset(pixelSize: canvas),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.8)
        )
        let before = PresentationLayout.resolve(imagePixelSize: image, presentation).imageRect

        let beforeRight = canvas.width - before.maxX
        presentation.image = PresentationLayout.placement(
            presentation.image, settingGap: .leading, to: 40,
            imagePixelSize: image, canvasSize: canvas, in: presentation
        )
        let after = PresentationLayout.resolve(imagePixelSize: image, presentation).imageRect

        expectClose(after.minX, 40)
        // The opposite edge stayed, so the picture resized to suit.
        expectClose(canvas.width - after.maxX, beforeRight)
        #expect(after.width != before.width)

        // Both ends of an axis can now be set, which is the whole point.
        for _ in 0..<2 {
            presentation.image = PresentationLayout.placement(
                presentation.image, settingGap: .top, to: 100,
                imagePixelSize: image, canvasSize: canvas, in: presentation
            )
            presentation.image = PresentationLayout.placement(
                presentation.image, settingGap: .bottom, to: 100,
                imagePixelSize: image, canvasSize: canvas, in: presentation
            )
        }
        let framed = PresentationLayout.resolve(imagePixelSize: image, presentation).imageRect
        expectClose(framed.minY, 100)
        expectClose(canvas.height - framed.maxY, 100)
    }

    // MARK: The picture as an object

    @Test func draggingThePictureMovesItAndTheMarginsFollow() {
        let document = makeDocument()          // 8×8 image
        let canvas = CGSize(width: 400, height: 400)
        document.presentation = Presentation(
            canvas: .preset(pixelSize: canvas),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.5)
        )
        document.markSaved()
        let before = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                       document.presentation)
        )

        // A drag is many events, not one: the gesture opens the change and the
        // move itself must not, or ⌘Z would rewind a single pointer sample.
        document.beginChange()
        for _ in 0..<8 {
            document.moveImage(by: CGPoint(x: 5, y: 0), canvasSize: canvas)
        }
        document.commitChange()

        let after = PresentationLayout.gaps(
            PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                       document.presentation)
        )
        expectClose(after.leading, before.leading + 40)
        expectClose(after.trailing, before.trailing - 40)
        expectClose(after.top, before.top)
        #expect(document.isDirty)
        #expect(document.undoStack.count == 1)   // one drag, one undo step
    }

    @Test func resizingByACornerKeepsTheOppositeOneAndTheAspect() {
        let document = makeDocument()
        let canvas = CGSize(width: 400, height: 400)
        document.presentation = Presentation(
            canvas: .preset(pixelSize: canvas),
            image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.5)
        )
        let before = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation).imageRect
        let anchor = ImageCorner.topLeft.point(in: before)   // stays put

        document.beginChange()
        document.resizeImage(corner: .bottomRight,
                             to: CGPoint(x: before.maxX + 50, y: before.maxY + 50),
                             canvasSize: canvas, imagePixelSize: document.pixelSize)
        document.commitChange()

        let after = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                               document.presentation).imageRect
        expectClose(after.minX, anchor.x)
        expectClose(after.minY, anchor.y)
        #expect(after.width > before.width)
        // Square image, square canvas: the aspect survives the drag.
        expectClose(after.width, after.height)
    }

    @Test func choosingAFormatFramesTheShotWithAFixedMargin() {
        let image = CGSize(width: 1600, height: 900)      // same shape as the canvas
        let canvas = CGSize(width: 1600, height: 900)
        let placement = PresentationLayout.placement(
            framingWith: 10,
            imagePixelSize: image, canvasSize: canvas
        )
        let gaps = PresentationLayout.gaps(
            PresentationLayout.resolve(
                imagePixelSize: image,
                Presentation(canvas: .preset(pixelSize: canvas), image: placement)
            )
        )
        expectClose(gaps.leading, 10)
        expectClose(gaps.trailing, 10)

        // A picture whose shape differs from the canvas gets the exact margin on
        // the axis that binds and more on the other — the aspect is locked, so
        // there is no third option.
        let wide = PresentationLayout.placement(
            framingWith: 10,
            imagePixelSize: CGSize(width: 1600, height: 400),
            canvasSize: canvas
        )
        let wideGaps = PresentationLayout.gaps(
            PresentationLayout.resolve(
                imagePixelSize: CGSize(width: 1600, height: 400),
                Presentation(canvas: .preset(pixelSize: canvas), image: wide)
            )
        )
        expectClose(wideGaps.leading, 10)
        #expect(wideGaps.top > 10)
    }

    @Test func aCanvasTooSmallForTheMarginStaysFitted() {
        let placement = PresentationLayout.placement(
            framingWith: 10,
            imagePixelSize: CGSize(width: 10, height: 10),
            canvasSize: CGSize(width: 12, height: 12)
        )
        #expect(placement == .fitted)
    }

    // MARK: The auto page

    /// The point of an auto page: four margins, four independent numbers. On a
    /// fixed page 50 on every side is unreachable — the aspect ratio is locked
    /// and four margins are three degrees of freedom.
    @Test func anAutoPageHonoursAllFourMarginsExactly() {
        let image = CGSize(width: 1237, height: 641)
        let resolved = PresentationLayout.resolve(
            imagePixelSize: image,
            Presentation(canvas: .auto(margins: .init(all: 50), scale: 1))
        )
        let gaps = PresentationLayout.gaps(resolved)

        expectClose(gaps.leading, 50)
        expectClose(gaps.trailing, 50)
        expectClose(gaps.top, 50)
        expectClose(gaps.bottom, 50)
        // The page grew; the picture kept every pixel it had.
        #expect(resolved.canvasSize == CGSize(width: 1337, height: 741))
        #expect(resolved.imageRect.size == image)
    }

    @Test func anAutoPageTakesEachMarginOnItsOwn() {
        let image = CGSize(width: 100, height: 100)
        let resolved = PresentationLayout.resolve(
            imagePixelSize: image,
            Presentation(canvas: .auto(margins: .init(top: 5, leading: 10,
                                                      bottom: 20, trailing: 40), scale: 1))
        )
        let gaps = PresentationLayout.gaps(resolved)
        expectClose(gaps.top, 5)
        expectClose(gaps.leading, 10)
        expectClose(gaps.bottom, 20)
        expectClose(gaps.trailing, 40)
        #expect(resolved.canvasSize == CGSize(width: 150, height: 125))
    }

    /// Zero margins are the undecorated document: page equals picture, which is
    /// what keeps `nil` and `.identity` interchangeable.
    @Test func anAutoPageWithoutMarginsIsJustThePicture() {
        let image = CGSize(width: 1200, height: 800)
        let resolved = PresentationLayout.resolve(imagePixelSize: image, Presentation.identity)
        #expect(resolved.canvasSize == image)
        #expect(resolved.imageRect == CGRect(origin: .zero, size: image))
    }

    @Test func movingThePictureOnAnAutoPageTradesMarginsAndKeepsTheSize() {
        let document = makeDocument()          // 8×8 picture
        document.presentation = Presentation(canvas: .auto(margins: .init(all: 20), scale: 1))
        document.markSaved()
        let before = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation)
        #expect(before.canvasSize == CGSize(width: 48, height: 48))

        document.moveImage(by: CGPoint(x: 5, y: -3), canvasSize: before.canvasSize)

        let after = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                               document.presentation)
        let gaps = PresentationLayout.gaps(after)
        // The page kept its size; the picture slid inside it.
        #expect(after.canvasSize == before.canvasSize)
        expectClose(gaps.leading, 25)
        expectClose(gaps.trailing, 15)
        expectClose(gaps.top, 17)
        expectClose(gaps.bottom, 23)
        #expect(after.imageRect.size == before.imageRect.size)
    }

    /// Auto → 1:1 → resize → Auto must come back to what is on screen, not to
    /// the state Auto held before the detour.
    @Test func autoTakesOverTheCurrentPictureAndMargins() {
        let image = CGSize(width: 1000, height: 500)
        // On a square page, scaled down and sitting off centre.
        let fixed = Presentation(
            canvas: .preset(pixelSize: CGSize(width: 1080, height: 1080)),
            image: .init(center: CGPoint(x: 0.4, y: 0.5), scale: 0.6)
        )
        let before = PresentationLayout.resolve(imagePixelSize: image, fixed)
        let gaps = PresentationLayout.gaps(before)

        // What the inspector does when Auto is chosen.
        let auto = Presentation(
            canvas: .auto(margins: .init(top: gaps.top.rounded(),
                                         leading: gaps.leading.rounded(),
                                         bottom: gaps.bottom.rounded(),
                                         trailing: gaps.trailing.rounded()),
                          scale: before.imageRect.width / image.width)
        )
        let after = PresentationLayout.resolve(imagePixelSize: image, auto)

        // Same picture, same size, same margins — the page merely stopped
        // being fixed.
        expectClose(after.imageRect.width, before.imageRect.width)
        expectClose(after.imageRect.height, before.imageRect.height)
        let afterGaps = PresentationLayout.gaps(after)
        expectClose(afterGaps.leading, gaps.leading.rounded())
        expectClose(afterGaps.top, gaps.top.rounded())
        #expect(after.imageRect.width < image.width)   // the scaling survived
    }

    /// On an auto page the three quantities are one sum — page = picture +
    /// margins — and each edit says which of the other two absorbs it.
    ///
    /// Resizing the picture: the page holds still and the margins give way.
    @Test func resizingThePictureOnAnAutoPageLeavesThePageAlone() {
        let document = makeDocument()          // 8×8 picture
        document.presentation = Presentation(canvas: .auto(margins: .init(all: 20),
                                                           scale: 1))
        let before = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation)
        #expect(before.canvasSize == CGSize(width: 48, height: 48))

        // Drag the bottom-right corner out to (36, 36): the picture doubles.
        document.beginChange()
        document.resizeImage(corner: .bottomRight, to: CGPoint(x: 36, y: 36),
                             canvasSize: before.canvasSize,
                             imagePixelSize: document.pixelSize)
        document.commitChange()

        let after = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                               document.presentation)
        let gaps = PresentationLayout.gaps(after)
        #expect(after.canvasSize == before.canvasSize)      // 1. the page holds
        expectClose(after.imageRect.width, 16)              // 3. the picture grew
        expectClose(gaps.leading, 20)                       // the held corner
        expectClose(gaps.top, 20)
        expectClose(gaps.trailing, 12)                      // 2. margins gave way
        expectClose(gaps.bottom, 12)
    }

    /// And the opposite corner is the one that stays put.
    @Test func aCornerDragOnAnAutoPageHoldsTheOppositeCorner() {
        let document = makeDocument()
        document.presentation = Presentation(canvas: .auto(margins: .init(all: 20),
                                                           scale: 1))
        let before = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation)
        document.beginChange()
        document.resizeImage(corner: .topLeft, to: CGPoint(x: 12, y: 12),
                             canvasSize: before.canvasSize,
                             imagePixelSize: document.pixelSize)
        document.commitChange()

        let after = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                               document.presentation).imageRect
        expectClose(after.maxX, before.imageRect.maxX)
        expectClose(after.maxY, before.imageRect.maxY)
        #expect(after.width > before.imageRect.width)
    }

    /// Typing a page size on an auto page: the picture is left alone and the
    /// margins take the difference, keeping whatever bias they had.
    @Test func absorbingAPageSizeChangeKeepsTheMarginBias() {
        // 30 left, 10 right — a picture pushed right. Growing the page by 40
        // must keep that three-to-one bias.
        let split = PresentationLayout.absorb(40, into: 30, and: 10)
        expectClose(split.near, 60)
        expectClose(split.far, 20)

        // With nothing to keep, the delta is simply halved.
        let even = PresentationLayout.absorb(40, into: 0, and: 0)
        expectClose(even.near, 20)
        expectClose(even.far, 20)
    }

    /// Aligning is a move: the page holds and the margins trade. On an auto
    /// page that has to be written to the margins — the placement is not what
    /// the resolver reads there, so sending it to the placement did nothing at
    /// all and the buttons looked dead.
    @Test func aligningOnAnAutoPageMovesThePictureAndKeepsTheSize() {
        let image = CGSize(width: 100, height: 50)
        var presentation = Presentation(
            canvas: .auto(margins: .init(top: 10, leading: 30, bottom: 10, trailing: 30),
                          scale: 1)
        )
        let before = PresentationLayout.resolve(imagePixelSize: image, presentation)
        #expect(before.canvasSize == CGSize(width: 160, height: 70))

        // What the Align Left button does.
        guard case .auto(var margins, let scale) = presentation.canvas else { return }
        let slack = before.canvasSize.width - before.imageRect.width
        margins.leading = 0
        margins.trailing = slack
        presentation.canvas = .auto(margins: margins, scale: scale)

        let after = PresentationLayout.resolve(imagePixelSize: image, presentation)
        let gaps = PresentationLayout.gaps(after)
        #expect(after.canvasSize == before.canvasSize)   // the page held
        expectClose(gaps.leading, 0)
        expectClose(gaps.trailing, 60)
        #expect(after.imageRect.size == before.imageRect.size)
    }

    /// Every kind that offers a gallery has something in it — an empty drawer
    /// under a selected kind reads as a missing feature.
    @Test func everyGalleryKindHasPresets() {
        let kinds = PresentationInspector.backgroundPresetsForTesting.map { background -> String in
            switch background {
            case .solid: return "solid"
            case .linearGradient, .radialGradient: return "gradient"
            case .mesh: return "mesh"
            case .none: return "none"
            // A picture is nobody's preset: the gallery is made of colours the
            // app ships, and the user's own file is not one of them.
            case .picture: return "picture"
            }
        }
        #expect(kinds.filter { $0 == "solid" }.count >= 4)
        // Gradients are filtered twice — by kind and by shape — so each shape
        // needs its own stock, not four between them.
        let linear = PresentationInspector.backgroundPresetsForTesting.filter {
            if case .linearGradient = $0 { return true } else { return false }
        }
        let radial = PresentationInspector.backgroundPresetsForTesting.filter {
            if case .radialGradient = $0 { return true } else { return false }
        }
        #expect(linear.count >= 8)
        #expect(radial.count >= 8)
        #expect(kinds.filter { $0 == "mesh" }.count >= 8)
    }

    /// A preset is an ordinary background value, so every control below the
    /// gallery keeps working on it. If one ever stopped being renderable the
    /// gallery would show a blank tile and say nothing about why.
    @Test func everyBackgroundPresetPaintsSomething() {
        let base = TestImages.make(width: 8, height: 8)
        for background in PresentationInspector.backgroundPresetsForTesting {
            let rep = AnnotationRenderer.renderBitmap(
                base: base, annotations: [],
                presentation: Presentation(
                    canvas: .preset(pixelSize: CGSize(width: 60, height: 60)),
                    background: background,
                    image: .init(center: CGPoint(x: 0.5, y: 0.5), scale: 0.1)
                )
            )
            let corner = rep?.colorAt(x: 1, y: 1)
            #expect(corner != nil)
            #expect((corner?.alphaComponent ?? 0) > 0.99)   // opaque, never a hole
        }
        #expect(PresentationInspector.backgroundPresetsForTesting.count == 32)
    }

    /// The page-layer pass is not cached, so a gesture pays for it on every
    /// pointer sample. While something is being dragged the canvas asks for
    /// half the side, which is a quarter of the pixels — though not a quarter
    /// of the time, since ribs and character cells are counted in fractions of
    /// the page and there are just as many of them at any size.
    @Test func aGestureRendersThePageAtHalfTheSide() {
        let device = CGSize(width: 1200, height: 800)
        let full = PresentationRenderer.pageBitmapSize(device: device, quality: .full)
        let moving = PresentationRenderer.pageBitmapSize(device: device, quality: .interactive)

        #expect(full.width == 1200 && full.height == 800)
        #expect(moving.width == 600 && moving.height == 400)
        #expect(full.width * full.height == moving.width * moving.height * 4)

        // A page too small to halve still has a bitmap to draw into.
        let tiny = PresentationRenderer.pageBitmapSize(device: CGSize(width: 1, height: 1),
                                                       quality: .interactive)
        #expect(tiny.width == 1 && tiny.height == 1)
    }
}
