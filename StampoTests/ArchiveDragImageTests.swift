import AppKit
import Foundation
import Testing
@testable import Stampo

/// The picture that leaves the archive under the pointer. A colour and a
/// snippet already travel as rounded plates; a capture used to travel as its
/// raw, square-cornered thumbnail and looked like a different object the moment
/// it left the cell. The drag itself needs a real mouse, but the picture is
/// drawn data — and drawn data is testable.
@MainActor
@Suite struct ArchiveDragImageTests {

    private let cell = NSSize(width: 51.2, height: 32)
    private let radius: CGFloat = 6
    /// How far inside an edge a probe sits. The cell is 51.2 pt wide, which is
    /// not a whole number of pixels, so the last pixel column is only partly
    /// covered; a probe on it would read "cut" where nothing was cut.
    private let inset: CGFloat = 1

    /// A solid-colour thumbnail of the given pixel size, the way
    /// `ThumbnailLoader` hands one out: a bitmap with no point size of its own.
    private func thumbnail(width: Int, height: Int) throws -> NSImage {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: .zero)
        image.addRepresentation(rep)
        image.size = NSSize(width: width, height: height)
        return image
    }

    /// Alpha of the pixel under a point, `y` counted from the top edge.
    private func alpha(of image: NSImage, x: CGFloat, y: CGFloat) throws -> CGFloat {
        let data = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: data))
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let px = min(Int(x * scale), rep.pixelsWide - 1)
        let py = min(Int(y * scale), rep.pixelsHigh - 1)
        return try #require(rep.colorAt(x: px, y: py)).alphaComponent
    }

    @Test func theCornersAreCutAndTheCentreIsSolid() throws {
        let image = try #require(archiveThumbnailDragImage(
            try thumbnail(width: 160, height: 100), size: cell, cornerRadius: radius))

        #expect(try alpha(of: image, x: inset, y: inset) < 1)
        #expect(try alpha(of: image, x: cell.width - inset, y: inset) < 1)
        #expect(try alpha(of: image, x: inset, y: cell.height - inset) < 1)
        #expect(try alpha(of: image, x: cell.width - inset, y: cell.height - inset) < 1)
        #expect(try alpha(of: image, x: cell.width / 2, y: cell.height / 2) == 1)
    }

    /// Only the corners go. A square cut would look the same at the four
    /// corner pixels and still eat an edge.
    @Test func theMiddleOfEveryEdgeStaysSolid() throws {
        let image = try #require(archiveThumbnailDragImage(
            try thumbnail(width: 160, height: 100), size: cell, cornerRadius: radius))

        #expect(try alpha(of: image, x: cell.width / 2, y: inset) == 1)
        #expect(try alpha(of: image, x: cell.width / 2, y: cell.height - inset) == 1)
        #expect(try alpha(of: image, x: inset, y: cell.height / 2) == 1)
        #expect(try alpha(of: image, x: cell.width - inset, y: cell.height / 2) == 1)
    }

    /// Cell coordinates, like the swatch's: AppKit shrinks the image into the
    /// drag frame afterwards, so a capture and a colour shrink and round alike.
    @Test func theImageIsTheCellsSize() throws {
        let image = try #require(archiveThumbnailDragImage(
            try thumbnail(width: 160, height: 100), size: cell, cornerRadius: radius))
        #expect(image.size == cell)
    }

    /// The cell draws its preview aspect-filled, so a window capture much wider
    /// or taller than the cell is cropped, not squeezed. The drag image does the
    /// same, which is also what stops it from being stretched into the frame.
    @Test func aWideThumbnailFillsTheCellWithoutBars() throws {
        let wide = try #require(archiveThumbnailDragImage(
            try thumbnail(width: 200, height: 60), size: cell, cornerRadius: radius))
        #expect(try alpha(of: wide, x: cell.width / 2, y: inset) == 1)
        #expect(try alpha(of: wide, x: cell.width / 2, y: cell.height - inset) == 1)

        let tall = try #require(archiveThumbnailDragImage(
            try thumbnail(width: 60, height: 200), size: cell, cornerRadius: radius))
        #expect(try alpha(of: tall, x: inset, y: cell.height / 2) == 1)
        #expect(try alpha(of: tall, x: cell.width - inset, y: cell.height / 2) == 1)
    }

    /// A thumbnail that is still decoding has no picture to round. The drag
    /// starts without one, exactly as it did before.
    @Test func aThumbnailStillDecodingStaysEmpty() {
        #expect(archiveThumbnailDragImage(nil, size: cell, cornerRadius: radius) == nil)
    }
}
