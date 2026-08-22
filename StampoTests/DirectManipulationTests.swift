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

    /// The page is fitted to the window on every layout pass, so a drag that
    /// changes the page's size would rescale the scene under the pointer —
    /// which is both a re-render per sample and a picture crawling out from
    /// under the hand. A held fit is what the gesture drags against.
    @Test func aHeldFitSurvivesThePageGrowing() {
        let image = CGSize(width: 1200, height: 700)
        let small = Presentation(canvas: .auto(margins: .init(all: 40), scale: 1),
                                 background: .solid(.white))
        let grown = Presentation(canvas: .auto(margins: .init(all: 400), scale: 1),
                                 background: .solid(.white))
        let viewport = CGSize(width: 900, height: 620)

        let before = EditorCanvasGeometry.resolve(viewport: viewport, imagePixelSize: image,
                                                  presentation: small, zoom: 1, pan: .zero)
        let after = EditorCanvasGeometry.resolve(viewport: viewport, imagePixelSize: image,
                                                 presentation: grown, zoom: 1, pan: .zero)
        let held = EditorCanvasGeometry.resolve(viewport: viewport, imagePixelSize: image,
                                                presentation: grown, zoom: 1, pan: .zero,
                                                baseScaleOverride: before.canvasScale)

        #expect(after.canvasScale < before.canvasScale)      // the fit would shrink
        #expect(held.canvasScale == before.canvasScale)      // held, it does not
    }

    /// Ten pixels was a thick outline on a retina screenshot, and a fixed
    /// number lies in both directions — hence a share of the short side, with
    /// clamps for the extremes.
    @Test func theStartingMarginFollowsThePicture() {
        #expect(Presentation.defaultMargin(for: CGSize(width: 2400, height: 1400)) == 168)
        #expect(Presentation.defaultMargin(for: CGSize(width: 1200, height: 2000)) == 144)
        #expect(Presentation.defaultMargin(for: CGSize(width: 600, height: 400)) == 48)
        // A tiny crop keeps a visible frame; a panorama's short side is small,
        // and a full retina screen's is large.
        #expect(Presentation.defaultMargin(for: CGSize(width: 200, height: 120)) == 32)
        #expect(Presentation.defaultMargin(for: CGSize(width: 6000, height: 4000)) == 240)
        #expect(Presentation.defaultMargin(for: .zero) == 32)
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
