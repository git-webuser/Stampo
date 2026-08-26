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

    private func autoPage(_ margin: CGFloat) -> Presentation {
        Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                     background: .solid(.white))
    }

    private func pinned(_ edge: PresentationLayout.Edge, at pointer: CGPoint,
                        margin: CGFloat, image: CGSize, viewport: CGSize)
        -> EditorCanvasGeometry.Resolved {
        let centred = EditorCanvasGeometry.resolve(
            viewport: viewport, imagePixelSize: image, presentation: autoPage(margin),
            zoom: 1, pan: .zero)
        let origin = EditorCanvasGeometry.canvasOrigin(
            pinning: edge, at: pointer,
            imageRect: centred.presentationLayout.imageRect,
            canvasScale: centred.canvasScale,
            canvasDrawSize: centred.canvasDrawSize,
            viewport: viewport, centred: centred.canvasOffset)
        return EditorCanvasGeometry.resolve(
            viewport: viewport, imagePixelSize: image, presentation: autoPage(margin),
            zoom: 1, pan: .zero, canvasOriginOverride: origin)
    }

    /// An auto page has no size of its own — it is the picture plus its
    /// margins — so setting a margin resizes the page, and a resized page is
    /// re-fitted and re-centred on the next pass. That moves the very edge the
    /// hand is holding, so the page is placed to keep it under the pointer —
    /// wherever the window has room for it to be placed.
    @Test func theDraggedEdgeStaysUnderThePointerWhileThereIsRoom() {
        // Small enough to be drawn at 1:1 with slack around it: that slack is
        // what the pin has to work with.
        let image = CGSize(width: 300, height: 200)
        let viewport = CGSize(width: 900, height: 620)
        let pointer = CGPoint(x: 300, y: 310)

        for margin in [CGFloat(32), 60, 100] {
            let geometry = pinned(.leading, at: pointer, margin: margin,
                                  image: image, viewport: viewport)

            #expect(abs(geometry.imageOffset.x - pointer.x) < 0.001, "margin \(margin)")
            // The other axis is untouched: nothing on it changed.
            let centred = EditorCanvasGeometry.resolve(
                viewport: viewport, imagePixelSize: image, presentation: autoPage(margin),
                zoom: 1, pan: .zero)
            #expect(geometry.canvasOffset.y == centred.canvasOffset.y)
        }
    }

    /// And where the window has no room — a page already fitted edge to edge —
    /// the page cannot be moved at all without hiding a side of it, so it is
    /// not moved. There is no third option: the page shrinks as it grows and
    /// stays centred, and the pointer drifts off the edge it is holding.
    @Test func aPageFittedEdgeToEdgeIsNotMovedForThePointer() {
        let image = CGSize(width: 1200, height: 700)
        let viewport = CGSize(width: 900, height: 620)
        let margin: CGFloat = 40

        let centred = EditorCanvasGeometry.resolve(
            viewport: viewport, imagePixelSize: image, presentation: autoPage(margin),
            zoom: 1, pan: .zero)
        let geometry = pinned(.leading, at: CGPoint(x: 300, y: 310), margin: margin,
                              image: image, viewport: viewport)

        #expect(abs(geometry.canvasOffset.x - centred.canvasOffset.x) < 0.001)
    }

    /// Tracking gives way to visibility, in both directions. Holding the fit
    /// walked the page out of the window; pinning without a clamp walked it out
    /// of the *opposite* side. Whatever the pointer asks for, every side of the
    /// page stays in the window.
    @Test func thePageNeverLeavesTheWindow() {
        let image = CGSize(width: 1200, height: 700)
        let viewport = CGSize(width: 900, height: 620)

        for edge in [PresentationLayout.Edge.leading, .trailing, .top, .bottom] {
            for pointer in [CGPoint(x: -400, y: -400), CGPoint(x: 40, y: 40),
                            CGPoint(x: 860, y: 580), CGPoint(x: 4000, y: 4000)] {
                for margin in [CGFloat(40), 600, 3000] {
                    let g = pinned(edge, at: pointer, margin: margin,
                                   image: image, viewport: viewport)
                    let page = CGRect(origin: g.canvasOffset, size: g.canvasDrawSize)

                    #expect(page.minX >= -0.001, "\(edge) \(pointer) \(margin)")
                    #expect(page.minY >= -0.001, "\(edge) \(pointer) \(margin)")
                    #expect(page.maxX <= viewport.width + 0.001, "\(edge) \(pointer) \(margin)")
                    #expect(page.maxY <= viewport.height + 0.001, "\(edge) \(pointer) \(margin)")
                }
            }
        }
    }

    /// And it keeps fitting the window while it grows, at any margin.
    @Test func theWholePageStaysVisibleAsItGrows() {
        let image = CGSize(width: 1200, height: 700)
        let viewport = CGSize(width: 900, height: 620)

        for margin in [CGFloat(40), 200, 600, 2000] {
            let size = EditorCanvasGeometry.resolve(
                viewport: viewport, imagePixelSize: image, presentation: autoPage(margin),
                zoom: 1, pan: .zero).canvasDrawSize

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
