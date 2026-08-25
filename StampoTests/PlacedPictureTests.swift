import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// A picture dropped on the canvas is an object on the page — the thing a
/// person means by the gesture (a second shot beside the first, annotated
/// across both), not the page's background, which is chosen in the panel.
@MainActor @Suite struct PlacedPictureTests {

    private func writePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0.7, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func document() -> EditorDocument {
        let ctx = CGContext(data: nil, width: 200, height: 140, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 140))
        return EditorDocument(baseImage: ctx.makeImage()!,
                              sourceURL: URL(fileURLWithPath: "/tmp/placed-host.png"))
    }

    @Test func aDroppedPictureLandsWhereItWasDroppedAsOneStep() throws {
        let document = document()
        let url = try writePNG("placed-picture.png", width: 100, height: 80)
        defer { try? FileManager.default.removeItem(at: url) }

        let steps = document.undoStack.count
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 300, y: 200),
                                      canvasSize: CGSize(width: 600, height: 400)))

        let placed = try #require(document.annotations.last)
        #expect(placed.kind == .picture)
        #expect(document.picture(for: placed.pictureID) != nil)
        #expect(placed.rect.midX == 300 && placed.rect.midY == 200)
        #expect(placed.rect.width == 100 && placed.rect.height == 80)
        #expect(document.selectedID == placed.id, "the thing just placed is the thing selected")
        #expect(document.undoStack.count == steps + 1)

        // The background is untouched: dropping on the canvas is about the page,
        // not about what the page is painted with.
        #expect(document.presentation?.background.pictureID == nil)

        document.undo()
        #expect(document.annotations.contains { $0.kind == .picture } == false)
    }

    /// A picture belongs to the page, not to the screenshot: it must not move
    /// when the shot is scaled or nudged inside its margins — which is exactly
    /// what "lives in canvas space" means, and it is why a second shot can sit
    /// in the margin beside the first.
    @Test func aPlacedPictureBelongsToThePage() {
        #expect(Annotation.kindLivesInImageSpace(.picture) == false)
    }

    /// It arrives at its own size, unless that would cover more than half the
    /// page — something enormous would land as a wall with no visible handles
    /// to shrink it by.
    @Test func aHugePictureArrivesSmallEnoughToGrab() {
        let big = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let small = CGContext(data: nil, width: 120, height: 90, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let page = CGSize(width: 800, height: 600)

        let placed = EditorDocument.placedPictureSize(of: big, on: page)
        #expect(placed.width <= page.width / 2 + 1 && placed.height <= page.height / 2 + 1)
        #expect(abs(placed.width / placed.height - 4.0 / 3.0) < 0.02, "it keeps its shape")

        // Small enough already: its own pixels, not blown up to fill the room.
        #expect(EditorDocument.placedPictureSize(of: small, on: page)
                == CGSize(width: 120, height: 90))
    }

    /// A picture on the clipboard is the same act as a picture dropped: ⌘V
    /// puts it on the page. A copied *file* counts too — Finder puts a URL on
    /// the pasteboard rather than the pixels, and to the person who copied a
    /// screenshot there the two are the same thing.
    @Test func theClipboardIsReadAsPixelsOrAsAFile() throws {
        let pasteboard = NSPasteboard(name: .init("stampo.tests.pictures"))

        pasteboard.clearContents()
        #expect(EditorDocument.pictureOnPasteboard(pasteboard) == nil)

        pasteboard.clearContents()
        pasteboard.setString("not a picture", forType: .string)
        #expect(EditorDocument.pictureOnPasteboard(pasteboard) == nil)

        let url = try writePNG("pasted-picture.png", width: 40, height: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        let fromFile = EditorDocument.pictureOnPasteboard(pasteboard)
        #expect(fromFile?.width == 40 && fromFile?.height == 30)

        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(contentsOf: url)!])
        #expect(EditorDocument.pictureOnPasteboard(pasteboard) != nil)
    }

    /// Corners and shadow belong to the picture, not to a tool's style: two
    /// shots side by side are often wanted rounded differently, and a style
    /// shared by every future picture could not say that. Both are fractions of
    /// the picture's own size, so its look survives being resized.
    @Test func aPlacedPictureCarriesItsOwnCornersAndShadow() throws {
        let document = document()
        let url = try writePNG("placed-corners.png", width: 80, height: 80)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 100, y: 100),
                                      canvasSize: CGSize(width: 400, height: 300)))

        document.updateSelected {
            $0.pictureCornerRadius = 0.25
            $0.pictureShadow = 0.6
        }
        let placed = try #require(document.annotations.last)
        #expect(placed.pictureCornerRadius == 0.25)
        #expect(placed.pictureShadow == 0.6)

        // Rounding cuts the corners away: the pixel just inside the bounding box
        // is background, while the middle is the picture.
        let rep = try #require(AnnotationRenderer.renderBitmap(
            base: document.baseImage, pictures: document.pictures,
            annotations: document.annotations, presentation: nil))
        let corner = rep.colorAt(x: Int(placed.rect.minX) + 2, y: Int(placed.rect.minY) + 2)
        let middle = rep.colorAt(x: Int(placed.rect.midX), y: Int(placed.rect.midY))
        // The picture is green; the page under it is grey. In the middle the
        // green wins, and in the cut-away corner the two channels are level
        // again — which is the page showing through.
        #expect(Double(middle?.greenComponent ?? 0) - Double(middle?.redComponent ?? 0) > 0.4,
                "the picture is not drawn")
        #expect(abs(Double(corner?.greenComponent ?? 0) - Double(corner?.redComponent ?? 1)) < 0.05,
                "the corner was not rounded away")
    }

    /// The exported file carries what the page shows, so the pixels have to
    /// travel with the snapshot — the same arrangement the blurred copies use.
    @Test func aPlacedPictureReachesTheExportedFile() throws {
        let document = document()
        let url = try writePNG("placed-exported.png", width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        document.startDecorationIfNeeded()
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 40, y: 40),
                                      canvasSize: CGSize(width: 400, height: 300)))

        let snapshot = document.makeRenderSnapshot(format: "png")
        #expect(snapshot.pictures.count == 1, "the pixels travel with the snapshot")

        let rep = AnnotationRenderer.renderBitmap(base: document.baseImage,
                                                  pictures: snapshot.pictures,
                                                  annotations: document.annotations,
                                                  presentation: document.presentation)
        let green = rep?.colorAt(x: 40, y: 40)
        #expect(Double(green?.greenComponent ?? 0) > 0.5, "the placed picture is not in the file")
    }

    /// The panel deletes an object by name, not by selection: the section you
    /// press the button in is the object it throws away, whether or not the
    /// canvas happens to be pointing at it. One press, one step of undo.
    @Test func thePanelDeletesOnePictureByName() throws {
        let document = document()
        let url = try writePNG("placed-delete.png", width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        document.startDecorationIfNeeded()
        let canvas = CGSize(width: 400, height: 300)
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 40, y: 40), canvasSize: canvas))
        let first = try #require(document.annotations.last?.id)
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 120, y: 90), canvasSize: canvas))
        let second = try #require(document.annotations.last?.id)
        document.selectedID = second

        document.delete(id: first)
        #expect(document.annotations.map(\.id) == [second])
        #expect(document.selectedID == second, "deleting one object let go of another")

        document.undo()
        #expect(document.annotations.map(\.id) == [first, second])

        // Throwing away what is selected does let go of it, and a name that is
        // not on the page is not an undo step.
        document.delete(id: second)
        #expect(document.selectedID == nil)
        let steps = document.annotations.count
        document.delete(id: UUID())
        #expect(document.annotations.count == steps)
    }

    /// Shift on a corner keeps a picture's own proportions. A square would be
    /// no kinder to a photograph than free dragging is — the point of the key
    /// is that the picture is not squashed.
    @Test func shiftResizesAPictureWithoutSquashingIt() throws {
        let document = document()
        let url = try writePNG("placed-shift.png", width: 80, height: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        document.startDecorationIfNeeded()
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 100, y: 100),
                                      canvasSize: CGSize(width: 400, height: 300)))
        var picture = try #require(document.annotations.last)
        let ratio = picture.rect.height / picture.rect.width
        #expect(abs(ratio - 0.5) < 0.01, "the picture did not come in at its own shape")

        let corner = CGPoint(x: picture.rect.minX, y: picture.rect.minY)
        picture.apply(handle: .bottomRight,
                      to: CGPoint(x: corner.x + 300, y: corner.y + 20),
                      aspectLocked: true)
        #expect(abs(picture.rect.height / picture.rect.width - ratio) < 0.01,
                "Shift squashed the picture")
        // The longer side of the drag leads, so the corner follows the pointer.
        #expect(abs(picture.rect.width - 300) < 1)

        // Without the key it goes wherever it is dragged.
        picture.apply(handle: .bottomRight,
                      to: CGPoint(x: corner.x + 300, y: corner.y + 20))
        #expect(abs(picture.rect.height - 20) < 1)
    }
}
