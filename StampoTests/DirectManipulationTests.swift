import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// The picture is an object on the canvas: it moves, it resizes, and now its
/// margins and its corner radius are dragged on the picture itself rather than
/// typed at in a panel. These are the conversions that stand between a pointer
/// and the model.
@MainActor @Suite struct DirectManipulationTests {

    private let canvas = CGSize(width: 1000, height: 800)
    private var picture: CGRect { CGRect(x: 100, y: 60, width: 800, height: 680) }

    /// The distance from the page's edge to the pointer *is* the margin — the
    /// same number the field would take.
    @Test func aPointerOnASideIsThatSidesMargin() {
        let point = CGPoint(x: 220, y: 150)

        #expect(PresentationLayout.gap(forPointer: point, on: .leading,
                                       canvasSize: canvas) == 220)
        #expect(PresentationLayout.gap(forPointer: point, on: .top,
                                       canvasSize: canvas) == 150)
        #expect(PresentationLayout.gap(forPointer: point, on: .trailing,
                                       canvasSize: canvas) == 780)
        #expect(PresentationLayout.gap(forPointer: point, on: .bottom,
                                       canvasSize: canvas) == 650)
    }

    /// Dragging past the page's edge is allowed and means the picture reaches
    /// past it — the model says so for typed margins, and a drag must not
    /// invent a different rule.
    @Test func draggingPastTheEdgeGivesANegativeMargin() {
        #expect(PresentationLayout.gap(forPointer: CGPoint(x: -40, y: 0),
                                       on: .leading, canvasSize: canvas) == -40)
        #expect(PresentationLayout.gap(forPointer: CGPoint(x: 1040, y: 0),
                                       on: .trailing, canvasSize: canvas) == -40)
    }

    /// The radius is a share of the canvas's short side, which is what the
    /// renderer multiplies by — the picture's own size only caps it.
    @Test func theRadiusIsReadAgainstTheCanvasShortSide() {
        // 80 points into the corner on both axes, short side 800 → 0.1.
        let corner = CGPoint(x: picture.minX + 80, y: picture.minY + 80)

        #expect(abs(PresentationLayout.cornerRadius(forPointer: corner, from: .topLeft,
                                                    in: picture,
                                                    canvasSize: canvas) - 0.1) < 0.0001)
    }

    /// One number, four handles: every corner sets the same radius, measured
    /// from itself. The same pointer offset from any corner is the same answer.
    @Test func everyCornerSetsTheSameRadius() {
        for corner in ImageCorner.allCases {
            let anchor = corner.point(in: picture)
            let point = CGPoint(x: anchor.x + (corner.isLeading ? 80 : -80),
                                y: anchor.y + (corner.isTop ? 80 : -80))

            #expect(abs(PresentationLayout.cornerRadius(forPointer: point, from: corner,
                                                        in: picture,
                                                        canvasSize: canvas) - 0.1) < 0.0001,
                    "\(corner)")
        }
    }

    /// The smaller of the two axes wins: a corner arc can only use what both
    /// sides give it.
    @Test func theShorterReachIsTheRadius() {
        let lopsided = CGPoint(x: picture.minX + 200, y: picture.minY + 40)

        #expect(abs(PresentationLayout.cornerRadius(forPointer: lopsided, from: .topLeft,
                                                    in: picture,
                                                    canvasSize: canvas) - 0.05) < 0.0001)
    }

    @Test func theRadiusStopsAtHalfAndAtZero() {
        let far = CGPoint(x: picture.minX + 900, y: picture.minY + 900)

        #expect(PresentationLayout.cornerRadius(forPointer: far, from: .topLeft,
                                                in: picture, canvasSize: canvas) == 0.5)
        #expect(PresentationLayout.cornerRadius(forPointer: picture.origin, from: .topLeft,
                                                in: picture, canvasSize: canvas) == 0)
    }

    /// An auto page has no size of its own — it is the picture plus its
    /// margins — so setting a margin resizes the page, and a resized page is
    /// re-fitted and re-centred on the next pass. That moves the very edge the
    /// hand is holding, so the page is placed to keep it under the pointer.
    @Test func theDraggedEdgeStaysUnderThePointer() {
        let image = CGSize(width: 1200, height: 700)
        let viewport = CGSize(width: 900, height: 620)
        func page(_ margin: CGFloat) -> Presentation {
            Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                         background: .solid(.white))
        }
        let pointer = CGPoint(x: 300, y: 310)

        for margin in [CGFloat(40), 200, 600] {
            let centred = EditorCanvasGeometry.resolve(
                viewport: viewport, imagePixelSize: image, presentation: page(margin),
                zoom: 1, pan: .zero)
            let origin = EditorCanvasGeometry.canvasOrigin(
                pinning: .leading, at: pointer,
                imageRect: centred.presentationLayout.imageRect,
                canvasScale: centred.canvasScale, centred: centred.canvasOffset)
            let pinned = EditorCanvasGeometry.resolve(
                viewport: viewport, imagePixelSize: image, presentation: page(margin),
                zoom: 1, pan: .zero, canvasOriginOverride: origin)

            // The picture's left edge on screen is where the pointer is, at any
            // margin — which is what "the hand is holding this edge" means.
            #expect(abs(pinned.imageOffset.x - pointer.x) < 0.001, "margin \(margin)")
            // The other axis is untouched: nothing on it changed.
            #expect(pinned.canvasOffset.y == centred.canvasOffset.y)
        }
    }

    /// And the page keeps fitting the window while it grows — holding the fit
    /// instead was tried and the page walked straight out of the window, taking
    /// the margin being set with it.
    @Test func theWholePageStaysVisibleAsItGrows() {
        let image = CGSize(width: 1200, height: 700)
        let viewport = CGSize(width: 900, height: 620)
        func drawn(_ margin: CGFloat) -> CGSize {
            EditorCanvasGeometry.resolve(
                viewport: viewport, imagePixelSize: image,
                presentation: Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                                           background: .solid(.white)),
                zoom: 1, pan: .zero).canvasDrawSize
        }

        for margin in [CGFloat(40), 200, 600, 2000] {
            let size = drawn(margin)
            #expect(size.width <= viewport.width, "margin \(margin)")
            #expect(size.height <= viewport.height, "margin \(margin)")
        }
    }

    /// One gesture is one undo step: the document's setters are live, and the
    /// canvas opens and closes the change around the whole drag.
    @Test func aDragOfTheMarginIsOneUndoStep() {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/drag.png"))
        document.startDecorationIfNeeded()
        let before = document.presentation
        let steps = document.undoStack.count

        document.beginChange()
        for x in stride(from: 60, through: 140, by: 10) {
            document.setGap(PresentationLayout.Edge.leading, to: CGFloat(x))
        }
        document.commitChange()

        #expect(document.undoStack.count == steps + 1)
        document.undo()
        #expect(document.presentation == before)
    }
}
