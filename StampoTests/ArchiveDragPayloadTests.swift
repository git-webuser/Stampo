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
