import AppKit
import Testing
@testable import Stampo

/// The archive is already a source of pictures for a page, by drag alone: a
/// cell leaves as a file URL and both drop zones in the editor take file URLs.
/// This holds the two ends together, because they are written in different
/// files and neither mentions the other — a payload changed to a promise, or
/// to a value, would break the drop with nothing to say so.
@MainActor @Suite struct ArchiveToPageTests {

    private func writePNG(_ name: String) throws -> URL {
        let ctx = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    /// What a dragged screenshot actually carries.
    private func draggedURL(of url: URL) throws -> URL {
        let written = NotchArchiveModel.dragPayload(for: [.screenshot(ArchiveScreenshot(url: url))],
                                                colorScheme: .hex, format: .png)
        let carried = try #require(written.first as? NSURL)
        return carried as URL
    }

    @Test func aScreenshotDraggedFromTheArchiveCanPaintThePage() throws {
        let url = try writePNG("archive-to-background.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let dragged = try draggedURL(of: url)

        let document = EditorDocument(baseImage: try #require(EditorDocument.picture(at: url)),
                                      sourceURL: url)
        document.startDecorationIfNeeded()
        #expect(document.useBackgroundPicture(at: dragged),
                "the background section would not take what the archive hands it")
        #expect(document.presentation?.background.pictureID != nil)
    }

    @Test func aScreenshotDraggedFromTheArchiveCanBecomeAnObject() throws {
        let url = try writePNG("archive-to-object.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let dragged = try draggedURL(of: url)

        let document = EditorDocument(baseImage: try #require(EditorDocument.picture(at: url)),
                                      sourceURL: url)
        document.startDecorationIfNeeded()
        #expect(document.placePicture(at: dragged, centredOn: CGPoint(x: 50, y: 50),
                                      canvasSize: CGSize(width: 400, height: 300)),
                "the canvas would not take what the archive hands it")
        #expect(document.annotations.last?.kind == .picture)
    }

    /// A pile dropped into the archive leaves as its own files, untouched —
    /// the same door, for pictures that were never screenshots.
    @Test func aStackDraggedFromTheArchiveCarriesItsFiles() throws {
        let url = try writePNG("archive-stack.png")
        defer { try? FileManager.default.removeItem(at: url) }
        let written = NotchArchiveModel.dragPayload(for: [.stack(ArchiveStack(urls: [url]))],
                                                colorScheme: .hex, format: .png)
        let carried = try #require(written.first as? NSURL) as URL
        #expect(carried.standardizedFileURL == url.standardizedFileURL)
        #expect(EditorDocument.picture(at: carried) != nil)
    }
}
