import AppKit
import Foundation
import Testing
@testable import Stampo

/// What a dragged-out archive cell actually puts on the pasteboard. The drag
/// itself needs a real mouse, but the payload is data — and data is testable.
@Suite struct ArchiveDragPayloadTests {

    @Test func filesRideOutAsURLs() {
        let a = URL(fileURLWithPath: "/tmp/archive/a.png")
        let b = URL(fileURLWithPath: "/tmp/archive/b.pdf")
        let payload = ArchiveDragPayload.files([a, b])
        #expect(payload.count == 2)
        #expect((payload.first as? NSURL) as URL? == a)
        #expect((payload.last as? NSURL) as URL? == b)
    }

    /// A capture already in the chosen format is dragged as itself: the file
    /// on the pasteboard is the one in the archive, not a copy of it.
    @Test func aCaptureAlreadyInFormatRidesOutAsItself() throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = ArchiveDragPayload.capture(url, as: .png)
        #expect(((payload.first as? NSURL) as URL?)?.standardizedFileURL == url.standardizedFileURL)
    }

    /// One taken before the setting changed rides out re-encoded, under the
    /// capture's own name — dragging it into Mail must not hand over the old
    /// format the clipboard has already stopped handing over.
    @Test func aCaptureInAnotherFormatRidesOutReEncoded() throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }

        let dragged = try #require((ArchiveDragPayload.capture(url, as: .jpg).first as? NSURL) as URL?)
        #expect(dragged.pathExtension == "jpg")
        #expect(dragged.deletingPathExtension().lastPathComponent
                == url.deletingPathExtension().lastPathComponent)
        let source = try #require(CGImageSourceCreateWithURL(dragged as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    /// A file the user dropped into the archive is not a capture: it leaves
    /// exactly as it is, whatever the capture format says.
    @Test func aDroppedFileIsNeverReEncoded() throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = ArchiveDragPayload.files([url])
        #expect(((payload.first as? NSURL) as URL?)?.standardizedFileURL == url.standardizedFileURL)
    }

    private func makePNG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-test-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func textRidesOutAsAString() throws {
        let item = try #require(ArchiveDragPayload.text("hello world").first as? NSPasteboardItem)
        #expect(item.string(forType: .string) == "hello world")
        #expect(item.types.contains(.string))
    }

    /// The color goes out twice over: as text for editors, and in AppKit's own
    /// color representation so a color well accepts the same drag.
    @Test func colorRidesOutAsBothTextAndColor() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let item = try #require(ArchiveDragPayload.color(red, formatted: "#FF0000").first as? NSPasteboardItem)

        #expect(item.string(forType: .string) == "#FF0000")
        #expect(item.types.contains(.color))

        let data = try #require(item.data(forType: .color))
        let restored = try #require(NSColor(pasteboardPropertyList: data, ofType: .color))
        #expect(restored.hexString == red.hexString)
    }

    /// The formatted string follows the archive header's notation, so dragging
    /// while RGB is selected must not silently drop a hex value.
    @Test func theTextSideUsesWhateverNotationIsGiven() throws {
        let color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for scheme in ColorSchemeType.allCases {
            let formatted = scheme.convert(color)
            let item = try #require(ArchiveDragPayload.color(color, formatted: formatted).first as? NSPasteboardItem)
            #expect(item.string(forType: .string) == formatted)
        }
    }
}
