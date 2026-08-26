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

    private func makePicture(width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
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
                      to: CGPoint(x: corner.x + 300, y: corner.y + 20),
                      minimumSide: 1)
        #expect(abs(picture.rect.height - 20) < 1)
    }

    /// Shift held all the way in and all the way out again leaves the shape
    /// exactly as it was.
    ///
    /// It did not: the ratio was read from the rectangle on every sample, and
    /// the corner clamped at the minimum on each axis separately — so the clamp
    /// distorted the picture and the next sample locked to the distortion.
    /// Measured before the fix: 200×100 → 40×20 → 12×8 → 8×8, and back out to
    /// 400×400. A photograph made square by the one key whose whole promise is
    /// that it will not be squashed.
    @Test func shiftSurvivesTheJourneyToTheMinimumAndBack() {
        var picture = Annotation(kind: .picture,
                                 start: CGPoint(x: 100, y: 100),
                                 end: CGPoint(x: 300, y: 200),   // 200 × 100, 2:1
                                 color: .blue, lineWidth: 2)
        let ratio = picture.rect.height / picture.rect.width
        let floor: CGFloat = 24

        for target in [CGPoint(x: 140, y: 120), CGPoint(x: 112, y: 104),
                       CGPoint(x: 104, y: 102), CGPoint(x: 500, y: 400)] {
            picture.apply(handle: .bottomRight, to: target, aspectLocked: true,
                          minimumSide: floor, lockedRatio: ratio)
            #expect(abs(picture.rect.height / picture.rect.width - ratio) < 0.001,
                    "the shape drifted at \(picture.rect)")
            #expect(min(picture.rect.width, picture.rect.height) >= floor - 0.5,
                    "the picture went below its floor: \(picture.rect)")
        }
        // And it is large again, not stuck at the minimum it passed through.
        #expect(picture.rect.width > 300)
        // The anchor never moved.
        #expect(picture.rect.origin == CGPoint(x: 100, y: 100))
    }

    /// The floor holds for a free drag too, and dragging past the anchor stops
    /// there rather than mirroring the picture — the editor does not offer to
    /// flip a photograph anywhere else either.
    @Test func aPictureStopsAtItsFloorRatherThanFlipping() {
        var picture = Annotation(kind: .picture,
                                 start: CGPoint(x: 100, y: 100),
                                 end: CGPoint(x: 300, y: 200),
                                 color: .blue, lineWidth: 2)
        picture.apply(handle: .bottomRight, to: CGPoint(x: 40, y: 30), minimumSide: 24)
        #expect(picture.rect == CGRect(x: 100, y: 100, width: 24, height: 24))
        #expect(picture.flippedVertically == false)
    }

    /// The floor is a fraction of the screenshot, like the margins are, so it
    /// means the same thing on a phone shot and on a 6K one.
    @Test func theFloorIsAFractionOfTheScreenshot() {
        let small = Presentation.minimumPictureSide(for: CGSize(width: 800, height: 600))
        let large = Presentation.minimumPictureSide(for: CGSize(width: 6016, height: 3384))
        #expect(small == 48)                       // 8% of 600
        #expect(large > small)
        #expect(large <= 160)                      // and it stops rising
        // A degenerate page cannot produce a floor of nothing.
        #expect(Presentation.minimumPictureSide(for: .zero) >= 24)
    }

    /// Both roads to a size hold the same floor: the corner on the canvas, and
    /// the number typed into the panel.
    @Test func aTypedSizeCannotGoBelowTheFloor() {
        let rect = CGRect(x: 10, y: 10, width: 200, height: 100)
        let tiny = Annotation.resized(rect, width: 4, keepingRatio: true, minimumShortSide: 24)
        #expect(min(tiny.width, tiny.height) >= 24)
        #expect(abs(tiny.height / tiny.width - 0.5) < 0.01, "the floor squashed it")
        // Unchained, each side is held up on its own.
        let free = Annotation.resized(rect, height: 2, keepingRatio: false,
                                      minimumShortSide: 24)
        #expect(free.height >= 24)
    }

    /// A picture arrives no smaller than it may be dragged to — one rule, at
    /// both ends of its life. A favicon on a page was a speck with eight
    /// overlapping grips on it.
    @Test func aTinyPictureArrivesAtTheFloor() throws {
        let document = document()
        document.startDecorationIfNeeded()
        let layout = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation)
        let floor = Presentation.minimumPictureSide(for: layout.imageRect.size)
        document.placePicture(try #require(makePicture(width: 16, height: 16)),
                              centredOn: CGPoint(x: 100, y: 100),
                              canvasSize: layout.canvasSize)
        let placed = try #require(document.annotations.last)
        #expect(min(placed.rect.width, placed.rect.height) >= floor - 0.5)
    }

    /// The cap holds whatever colour space the file came in: a CMYK scan could
    /// not be drawn into a CMYK context with an alpha channel, so the context
    /// failed to build and the picture came back uncut.
    @Test func theSizeCapHoldsForCMYK() throws {
        let cmyk = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceCMYK(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)
        let image = try #require(cmyk?.makeImage())
        let fitted = EditorDocument.fitted(image)
        #expect(fitted.width == EditorDocument.pictureSizeLimit)
    }

    /// A picture's own effects are its own: baked over its pixels alone, so
    /// they follow it wherever it is put and leave the page under it untouched.
    @Test func aPicturesEffectsAreBakedIntoItAndNothingElse() throws {
        let document = document()
        let url = try writePNG("placed-effects.png", width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        document.startDecorationIfNeeded()
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 40, y: 40),
                                      canvasSize: CGSize(width: 400, height: 300)))
        let id = try #require(document.annotations.last?.id)
        let name = try #require(document.annotations.last?.pictureID)
        let picture = try #require(document.picture(for: name))

        // An empty stack is not a bake at all — the old path, byte for byte.
        EffectBaker.emptyCache()
        EffectBaker.resetBakeCount()
        let full = CGSize(width: CGFloat(picture.width), height: CGFloat(picture.height))
        #expect(EffectBaker.object([], over: picture, named: name, drawnAt: full) == nil)
        #expect(EffectBaker.bakeCount == 0)

        // Layer means nothing inside an object: a "page" effect still applies,
        // because an object is one layer, itself.
        var dim = EffectStack.make(.dim)
        dim.layer = .page
        dim.amount = 1
        let treated = try #require(EffectBaker.object([dim], over: picture, named: name,
                                                      drawnAt: full))
        #expect(EffectBaker.bakeCount == 1)
        #expect(treated.width == picture.width && treated.height == picture.height)
        // …and the second identical request is the cache's, not the GPU's.
        _ = EffectBaker.object([dim], over: picture, named: name, drawnAt: full)
        #expect(EffectBaker.bakeCount == 1)

        // Switched off is not applied.
        dim.isEnabled = false
        #expect(EffectBaker.object([dim], over: picture, named: name, drawnAt: full) == nil)

        // And it reaches the page: the picture goes dark where it is drawn.
        let plain = AnnotationRenderer.renderBitmap(base: document.baseImage,
                                                    pictures: document.pictures,
                                                    annotations: document.annotations,
                                                    presentation: document.presentation)?
            .colorAt(x: 40, y: 40)
        document.annotations[document.annotations.count - 1].pictureEffects = [
            EffectStack.setting(.amount, of: EffectStack.make(.dim), to: 1)
        ]
        #expect(document.annotations.first { $0.id == id }?.pictureEffects.count == 1)
        let dimmed = AnnotationRenderer.renderBitmap(base: document.baseImage,
                                                      pictures: document.pictures,
                                                      annotations: document.annotations,
                                                      presentation: document.presentation)?
            .colorAt(x: 40, y: 40)
        #expect(Double(dimmed?.brightnessComponent ?? 1)
                < Double(plain?.brightnessComponent ?? 0) - 0.05,
                "the picture's own effect did not reach the page")
    }

    /// The size fields, and the chain between them.
    @Test func typedSizeKeepsTheCornerAndOptionallyTheShape() {
        let rect = CGRect(x: 20, y: 30, width: 200, height: 100)

        let wider = Annotation.resized(rect, width: 400, keepingRatio: true)
        #expect(wider.origin == rect.origin, "the picture moved when it was resized")
        #expect(wider.size == CGSize(width: 400, height: 200))

        let taller = Annotation.resized(rect, height: 50, keepingRatio: true)
        #expect(taller.size == CGSize(width: 100, height: 50))

        // Unchained, the other number stays where it was.
        let squashed = Annotation.resized(rect, width: 400, keepingRatio: false)
        #expect(squashed.size == CGSize(width: 400, height: 100))

        // Both at once is not a request to guess which one leads.
        let both = Annotation.resized(rect, width: 300, height: 300, keepingRatio: true)
        #expect(both.size == CGSize(width: 300, height: 300))

        // Nothing collapses to nothing.
        #expect(Annotation.resized(rect, width: -8, keepingRatio: true).width == 1)
    }

    /// The radius dot on a placed picture measures against the picture's own
    /// short side, not the canvas — which is what lets a small picture and a
    /// large one look equally rounded at the same number.
    @Test func theRadiusDotMeasuresAgainstThePictureItself() {
        var picture = Annotation(kind: .picture,
                                 start: CGPoint(x: 100, y: 100),
                                 end: CGPoint(x: 300, y: 200),   // 200 × 100
                                 color: .blue, lineWidth: 2)

        let asked = EditorCanvasView.pictureCornerRadius(
            forPointer: CGPoint(x: 125, y: 125), from: .topLeft, of: picture.rect)
        #expect(abs(asked - 0.25) < 0.001)      // 25 of the 100 short side

        // Never past half, however far the pointer is dragged.
        #expect(EditorCanvasView.pictureCornerRadius(
            forPointer: CGPoint(x: 900, y: 900), from: .topLeft, of: picture.rect) == 0.5)

        // The dot sits at the radius, and never closer in than the minimum
        // inset that keeps it grabbable at zero.
        picture.pictureCornerRadius = 0.25
        let dot = EditorCanvasView.pictureRadiusHandlePoint(.topLeft, of: picture)
        #expect(dot == CGPoint(x: 125, y: 125))
        picture.pictureCornerRadius = 0
        let atZero = EditorCanvasView.pictureRadiusHandlePoint(.topLeft, of: picture)
        #expect(atZero.x > 100 && atZero.x <= 114)
    }

    /// What a document is allowed to weigh.
    ///
    /// Pictures live beside the presentation rather than inside it, and used to
    /// live there for the life of the window: every photograph ever dropped,
    /// at every pixel it arrived with. Two rules now bound that — a picture is
    /// cut down on the way in, and pixels nothing can reach are let go.
    @Test func aPictureIsCutDownOnTheWayIn() throws {
        let wide = try #require(makePicture(width: 6000, height: 3000))
        let document = document()
        document.startDecorationIfNeeded()
        document.placePicture(wide, centredOn: CGPoint(x: 200, y: 150),
                              canvasSize: CGSize(width: 400, height: 300))
        let name = try #require(document.annotations.last?.pictureID)
        let kept = try #require(document.picture(for: name))

        #expect(kept.width == EditorDocument.pictureSizeLimit)
        #expect(kept.height == EditorDocument.pictureSizeLimit / 2, "the shape changed")

        // A picture that already fits is passed through untouched rather than
        // redrawn — the same object, not a copy of the same size.
        let small = try #require(makePicture(width: 300, height: 200))
        #expect(EditorDocument.fitted(small) === small)
    }

    @Test func pixelsNothingCanReachAreLetGo() throws {
        let document = document()
        document.startDecorationIfNeeded()
        let canvas = CGSize(width: 400, height: 300)
        document.placePicture(try #require(makePicture(width: 100, height: 80)),
                              centredOn: CGPoint(x: 100, y: 100), canvasSize: canvas)
        let first = try #require(document.annotations.last?.pictureID)
        #expect(document.pictures.count == 1)

        // Deleting is not the moment: undo has to put it back without another
        // trip to the disk, so the pixels stay while the history holds them.
        document.delete(id: try #require(document.annotations.last?.id))
        #expect(document.pictures[first] != nil, "undo would have nothing to put back")
        document.undo()
        #expect(document.annotations.last?.pictureID == first)

        // Undone and then written over — the redo stack was the last thing
        // holding it, and this is the moment it can go.
        document.undo()
        #expect(document.annotations.isEmpty)
        document.placePicture(try #require(makePicture(width: 100, height: 80)),
                              centredOn: CGPoint(x: 200, y: 200), canvasSize: canvas)
        let second = try #require(document.annotations.last?.pictureID)
        #expect(document.pictures[first] == nil, "the first picture was kept for nobody")
        #expect(document.pictures[second] != nil)
        #expect(document.pictures.count == 1)
    }

    /// A background picture is reachable through the presentation rather than
    /// through an annotation, and the sweep has to see it there too — losing
    /// it would blank the page.
    @Test func theBackgroundsPixelsAreNotSweptAway() throws {
        let document = document()
        let url = try writePNG("kept-background.png", width: 60, height: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        document.startDecorationIfNeeded()
        #expect(document.useBackgroundPicture(at: url))
        let name = try #require(document.presentation?.background.pictureID)

        // Several unrelated changes, each one a sweep.
        for radius in [0.1, 0.2, 0.3] {
            document.beginChange()
            document.presentation?.cornerRadius = CGFloat(radius)
            document.commitChange()
        }
        #expect(document.picture(for: name) != nil, "the page lost its own background")
    }

    /// The chain belongs to the picture, not to the panel, because it decides
    /// what a drag on the canvas does as much as what a typed number does — a
    /// switch obeyed by one of the two roads to a size is a switch that lies.
    /// It arrives on, survives undo, and Shift inverts it for one gesture.
    @Test func theProportionChainIsTheObjectsOwn() throws {
        let document = document()
        let url = try writePNG("chain.png", width: 80, height: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        document.startDecorationIfNeeded()
        #expect(document.placePicture(at: url, centredOn: CGPoint(x: 100, y: 100),
                                      canvasSize: CGSize(width: 400, height: 300)))
        let placed = try #require(document.annotations.last)
        #expect(placed.pictureKeepsProportions, "a picture arrives with its sides tied")

        // Chained and no Shift: the corner keeps the shape.
        var chained = placed
        let ratio = chained.rect.height / chained.rect.width
        let corner = CGPoint(x: chained.rect.minX, y: chained.rect.minY)
        chained.apply(handle: .bottomRight,
                      to: CGPoint(x: corner.x + 200, y: corner.y + 30),
                      aspectLocked: chained.pictureKeepsProportions,
                      minimumSide: 24, lockedRatio: ratio)
        #expect(abs(chained.rect.height / chained.rect.width - ratio) < 0.01)

        // Unchained, the same drag stretches it — which is what unchaining is.
        var free = placed
        free.pictureKeepsProportions = false
        free.apply(handle: .bottomRight,
                   to: CGPoint(x: corner.x + 200, y: corner.y + 30),
                   aspectLocked: free.pictureKeepsProportions,
                   minimumSide: 24, lockedRatio: ratio)
        #expect(abs(free.rect.height - 30) < 1)

        // And the panel's press is one undo step on the document.
        let steps = document.undoStack.count
        document.beginChange()
        document.annotations[document.annotations.count - 1].pictureKeepsProportions = false
        document.commitChange()
        #expect(document.undoStack.count == steps + 1)
        document.undo()
        #expect(document.annotations.last?.pictureKeepsProportions == true)
    }
}
