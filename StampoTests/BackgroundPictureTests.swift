import AppKit
import CoreGraphics
import Testing
@testable import Stampo

/// A background made of the user's own picture: carried by name, drawn to fill,
/// and reaching the exported file.
@MainActor @Suite struct BackgroundPictureTests {

    /// Four quadrants, so both the cropping and the orientation are readable
    /// from any corner of what gets drawn.
    private func picture(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let half = CGSize(width: width / 2, height: height / 2)
        // Drawn in the renderer's top-left space, so "top" reads as top.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let quadrants: [(CGRect, CGColor)] = [
            (CGRect(origin: .zero, size: half), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: half.width, y: 0, width: half.width, height: half.height),
             CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: half.height, width: half.width, height: half.height),
             CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: half.width, y: half.height, width: half.width, height: half.height),
             CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        ]
        for (rect, color) in quadrants {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    private func drawn(_ background: Presentation.Background, picture: CGImage?,
                       size: CGSize) -> NSBitmapImageRep {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        PresentationRenderer.drawBackground(background, picture: picture,
                                            in: CGRect(origin: .zero, size: size), ctx: ctx)
        return NSBitmapImageRep(cgImage: ctx.makeImage()!)
    }

    /// The page is a page even before the picture is there: a file still being
    /// chosen, or one the document no longer holds, leaves the backing colour
    /// rather than a hole.
    @Test func aPageWithNoPictureYetIsStillAPage() {
        let backing = Presentation.Color(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        let rep = drawn(.picture(id: UUID(), backing: backing, fit: .fill), picture: nil,
                        size: CGSize(width: 40, height: 40))
        let color = rep.colorAt(x: 20, y: 20)
        #expect(abs(Double(color?.redComponent ?? 0) - 0.2) < 0.05)
        #expect(abs(Double(color?.blueComponent ?? 0) - 0.8) < 0.05)
        #expect(Double(color?.alphaComponent ?? 0) == 1)
    }

    /// Fill, not fit: a background is the one thing that has to reach every
    /// corner, and bars of another colour around it would be a second
    /// background rather than a setting of this one.
    @Test func thePictureFillsThePageAndKeepsItsShape() {
        // A wide picture on a tall page: the sides are cropped away, the top
        // and bottom halves still divide the page in the middle.
        let rep = drawn(.picture(id: UUID(), backing: .black, fit: .fill),
                        picture: picture(width: 400, height: 100),
                        size: CGSize(width: 100, height: 200))
        func hue(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let color = rep.colorAt(x: x, y: y)
            return (Double(color?.redComponent ?? 0), Double(color?.greenComponent ?? 0),
                    Double(color?.blueComponent ?? 0))
        }
        // Top half of the page comes from the top half of the picture, whose
        // middle columns are red on the left and green on the right.
        #expect(hue(20, 40).0 > 0.8 && hue(20, 40).1 < 0.2)     // red
        #expect(hue(80, 40).1 > 0.8 && hue(80, 40).0 < 0.2)     // green
        // Bottom half: blue on the left, yellow on the right.
        #expect(hue(20, 160).2 > 0.8)                            // blue
        #expect(hue(80, 160).0 > 0.8 && hue(80, 160).1 > 0.8)    // yellow
        // Nothing of the backing shows: every corner is picture.
        for (x, y) in [(1, 1), (98, 1), (1, 198), (98, 198)] {
            let color = rep.colorAt(x: x, y: y)
            let red = Double(color?.redComponent ?? 0)
            let green = Double(color?.greenComponent ?? 0)
            let blue = Double(color?.blueComponent ?? 0)
            #expect(red + green + blue > 0.5, "the backing shows through at (\(x), \(y))")
        }
    }

    /// The presentation names the picture and the document holds it, so the
    /// export has to be handed both — the same arrangement as the blurred
    /// copies of the screenshot.
    @Test func theExportedFileCarriesThePicture() {
        let shot = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        shot.setFillColor(CGColor(gray: 0.5, alpha: 1))
        shot.fill(CGRect(x: 0, y: 0, width: 20, height: 20))

        var presentation = Presentation.identity
        presentation.canvas = .auto(margins: Presentation.Margins(top: 30, leading: 30,
                                                                  bottom: 30, trailing: 30),
                                    scale: 1)
        presentation.background = .picture(id: UUID(), backing: .black, fit: .fill)

        let withPicture = AnnotationRenderer.renderBitmap(
            base: shot.makeImage()!, backgroundPicture: picture(width: 80, height: 80),
            annotations: [], presentation: presentation)
        let without = AnnotationRenderer.renderBitmap(
            base: shot.makeImage()!, annotations: [], presentation: presentation)

        // A margin pixel: the picture's own colour with it, the backing without.
        let inFile = withPicture?.colorAt(x: 5, y: 5)
        #expect(Double(inFile?.redComponent ?? 0) > 0.8, "the picture did not reach the file")
        let blank = without?.colorAt(x: 5, y: 5)
        #expect(Double(blank?.redComponent ?? 1) < 0.1, "a missing picture should leave the backing")
    }

    /// Four ways for a picture to meet the page, and each has to be a
    /// different page. "Fill" crops to reach every corner, "fit" shows the
    /// whole picture against the backing, "stretch" squashes, "tile" repeats.
    @Test func everyFitMeetsThePageItsOwnWay() {
        let size = CGSize(width: 120, height: 60)
        // A wide picture with a red top-left quadrant, so cropping, letterboxing
        // and squashing are told apart by where the colours land.
        let wide = picture(width: 400, height: 100)
        func page(_ fit: Presentation.Background.PictureFit) -> NSBitmapImageRep {
            drawn(.picture(id: UUID(), backing: .black, fit: fit), picture: wide, size: size)
        }
        func bytes(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

        let pages = Presentation.Background.PictureFit.allCases.map { bytes(page($0)) }
        for (first, second) in zip(pages, pages.dropFirst()) {
            #expect(first != second, "two fits drew the same page")
        }

        // Fit leaves the backing showing at the sides of a wide picture on a
        // narrower page; fill never does.
        let fitted = page(.fit)
        let corner = fitted.colorAt(x: 2, y: 2)
        #expect(Double(corner?.redComponent ?? 1) < 0.1
                && Double(corner?.greenComponent ?? 1) < 0.1,
                "fit should leave the backing at the corners")
        let filledCorner = page(.fill).colorAt(x: 2, y: 2)
        #expect(Double(filledCorner?.redComponent ?? 0)
                + Double(filledCorner?.greenComponent ?? 0)
                + Double(filledCorner?.blueComponent ?? 0) > 0.5,
                "fill should reach the corners")
    }

    /// One road in, used by the panel's file dialog and by a file dropped on
    /// the canvas alike: the pixels are kept, the presentation names them, and
    /// the page appears if there was none — all in one press of ⌘Z.
    @Test func takingAPictureAsTheBackgroundIsOneStep() throws {
        let ctx = CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let document = EditorDocument(baseImage: ctx.makeImage()!,
                                      sourceURL: URL(fileURLWithPath: "/tmp/drop-host.png"))
        let rep = NSBitmapImageRep(cgImage: picture(width: 80, height: 80))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dropped-background.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(document.presentation == nil)
        let steps = document.undoStack.count
        #expect(document.useBackgroundPicture(at: url))

        // The page exists, it is made of the picture, and the pixels are here.
        let id = document.presentation?.background.pictureID
        #expect(id != nil)
        #expect(document.backgroundPicture(for: id) != nil)
        #expect(document.undoStack.count == steps + 1)

        // However the last one met the page, the next one meets it the same.
        document.presentation?.background = document.presentation!.background
            .settingPictureFit(.tile)
        #expect(document.useBackgroundPicture(at: url))
        #expect(document.presentation?.background.pictureFit == .tile)

        // A file nobody can read as an image changes nothing.
        let notAnImage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dropped-background.txt")
        try Data("not a picture".utf8).write(to: notAnImage)
        defer { try? FileManager.default.removeItem(at: notAnImage) }
        let before = document.presentation
        #expect(document.useBackgroundPicture(at: notAnImage) == false)
        #expect(document.presentation == before)
    }

    /// The bake is keyed on whether the picture is there, so the page drawn
    /// while a file is still being read is not the one kept for afterwards.
    @Test func aPageWaitingForItsPictureIsNotTheBakedOne() {
        EffectBaker.emptyCache()
        EffectBaker.resetBakeCount()
        let background = Presentation.Background.picture(id: UUID(), backing: .white, fit: .fill)
        let effects = [EffectStack.make(.grain, seed: 5)]
        let size = CGSize(width: 60, height: 60)

        _ = EffectBaker.image(background: background, effects: effects, pixelSize: size)
        _ = EffectBaker.image(background: background, effects: effects,
                              picture: picture(width: 40, height: 40), pixelSize: size)
        #expect(EffectBaker.bakeCount == 2)
    }
}
