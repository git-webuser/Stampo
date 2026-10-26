import AppKit
import Foundation
import Testing
@testable import Stampo

/// What a dragged-out archive cell actually puts on the pasteboard. The drag
/// itself needs a real mouse, but the payload is data — and data is testable.
@Suite struct ArchiveDragPayloadTests {

    /// A multi-selection drag fans its entries out exactly the way "Share
    /// Selected" does — one item per colour, snippet and capture, one per member
    /// of a stack. It has to: `ArchiveDragShimView` pairs the payload with its
    /// preview images by index, and a stack expanded on one side only would put
    /// the picture of the colour beside it under a file.
    @Test func aSelectionDragFansOutTheSameWayItsShareDoes() {
        let items: [ArchiveItem] = [
            .color(ArchiveColor(color: NSColor(hexString: "#FF0000")!, hex: "#FF0000")),
            .stack(ArchiveStack(urls: [URL(fileURLWithPath: "/tmp/drop/a.pdf"),
                                       URL(fileURLWithPath: "/tmp/drop/b.pdf"),
                                       URL(fileURLWithPath: "/tmp/drop/c.pdf")])),
            .text(ArchiveText(text: "hello")),
            .screenshot(ArchiveScreenshot(url: URL(fileURLWithPath: "/tmp/archive/shot.png")))
        ]
        let dragged = NotchArchiveModel.dragPayload(for: items, colorScheme: .hex, format: .png)
        let shared = NotchArchiveModel.payload(for: items, colorScheme: .hex)
        #expect(dragged.count == shared.count)
        #expect(dragged.count == 6)
    }

    /// Order is the archive's display order, so the cascade of previews under
    /// the cursor runs left to right the way the row does.
    @Test func aSelectionDragKeepsTheArchivesOrder() {
        let a = URL(fileURLWithPath: "/tmp/drop/a.pdf")
        let b = URL(fileURLWithPath: "/tmp/drop/b.pdf")
        let items: [ArchiveItem] = [
            .stack(ArchiveStack(urls: [a, b])),
            .text(ArchiveText(text: "hello"))
        ]
        let payload = NotchArchiveModel.dragPayload(for: items, colorScheme: .hex, format: .png)
        #expect((payload[0] as? NSURL) as URL? == a)
        #expect((payload[1] as? NSURL) as URL? == b)
        #expect((payload[2] as? NSPasteboardItem)?.string(forType: .string) == "hello")
    }

    /// Each kind still leaves encoded the way its own cell's drag encodes it —
    /// a colour in the header's notation, and as a colour a well can take.
    @Test func aSelectionDragKeepsEachKindsOwnEncoding() {
        let red = NSColor(hexString: "#FF0000")!
        let payload = NotchArchiveModel.dragPayload(for: [.color(ArchiveColor(color: red, hex: "#FF0000"))],
                                                    colorScheme: .rgb, format: .png)
        let item = try? #require(payload.first as? NSPasteboardItem)
        #expect(item?.string(forType: .string) == red.rgbString)
        #expect(item?.data(forType: .color) != nil)
    }

    @Test func nothingSelectedDragsNothing() {
        #expect(NotchArchiveModel.dragPayload(for: [], colorScheme: .hex, format: .png).isEmpty)
    }

    @Test func filesRideOutAsURLs() {
        let a = URL(fileURLWithPath: "/tmp/archive/a.png")
        let b = URL(fileURLWithPath: "/tmp/archive/b.pdf")
        let payload = ArchiveDragPayload.files([a, b])
        #expect(payload.count == 2)
        #expect((payload.first as? NSURL) as URL? == a)
        #expect((payload.last as? NSURL) as URL? == b)
    }

    @Test(arguments: [UInt64(0), 1, 128 * 1024 * 1024])
    func aSingleFileUpTo128MiBOnlyOffersCopy(size: UInt64) throws {
        try withSparseFiles(sizes: [size]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.copiesOut(payload))
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy])
        }
    }

    @Test func aSingleFileOneByteOver128MiBKeepsLinkSupport() throws {
        try withSparseFiles(sizes: [128 * 1024 * 1024 + 1]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.copiesOut(payload) == false)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
    }

    @Test func fourFilesAt512MiBOnlyOfferCopy() throws {
        try withSparseFiles(sizes: [128 * 1024 * 1024, 128 * 1024 * 1024,
                                   128 * 1024 * 1024, 128 * 1024 * 1024]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy])
        }
    }

    @Test func fiveFilesAt512MiBOnlyOfferCopy() throws {
        try withSparseFiles(sizes: [128 * 1024 * 1024, 128 * 1024 * 1024,
                                   128 * 1024 * 1024, 127 * 1024 * 1024,
                                   1024 * 1024]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy])
        }
    }

    @Test func threeFilesAt512MiBKeepLinkSupportForAnOversizedMember() throws {
        try withSparseFiles(sizes: [128 * 1024 * 1024, 128 * 1024 * 1024,
                                   256 * 1024 * 1024]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
    }

    @Test func fiveFilesOneByteOver512MiBKeepLinkSupport() throws {
        try withSparseFiles(sizes: [128 * 1024 * 1024, 128 * 1024 * 1024,
                                   128 * 1024 * 1024, 128 * 1024 * 1024, 1]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
    }

    @Test func manySmallFilesStillUseTheirCombinedSize() throws {
        try withSparseFiles(sizes: Array(repeating: 64 * 1024 * 1024, count: 9)) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
    }

    @Test func aSelectionKeepsLinkSupportForAMemberLargerThanTheFileLimit() throws {
        try withSparseFiles(sizes: [1, 128 * 1024 * 1024 + 1, 1]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
        try withSparseFiles(sizes: [300 * 1024 * 1024, 1]) { urls in
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
    }

    @Test func aPackageKeepsLinkSupportAloneAndInASelection() throws {
        try withSparseFiles(sizes: [1]) { urls in
            let package = urls[0].deletingLastPathComponent()
                .appendingPathComponent("Deck.key", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            try Data([1]).write(to: package.appendingPathComponent("slide.dat"))
            let packagePayload = ArchiveDragPayload.files([package])
            let mixedPayload = ArchiveDragPayload.files(urls + [package])
            #expect(ArchiveDragPayload.outsideMask(for: packagePayload) == [.copy, .link])
            #expect(ArchiveDragPayload.outsideMask(for: mixedPayload) == [.copy, .link])
        }
    }

    @Test func aDirectoryKeepsLinkSupportForTheWholeDrag() throws {
        try withSparseFiles(sizes: [1]) { urls in
            let directory = urls[0].deletingLastPathComponent()
            let folderPayload = ArchiveDragPayload.files([directory])
            let mixedPayload = ArchiveDragPayload.files(urls + [directory])
            #expect(ArchiveDragPayload.outsideMask(for: folderPayload) == [.copy, .link])
            #expect(ArchiveDragPayload.outsideMask(for: mixedPayload) == [.copy, .link])
        }
    }

    @Test func aMissingFileKeepsLinkSupportForTheWholeDrag() throws {
        try withSparseFiles(sizes: [1]) { urls in
            let missing = urls[0].deletingLastPathComponent().appendingPathComponent("missing")
            let missingPayload = ArchiveDragPayload.files([missing])
            let mixedPayload = ArchiveDragPayload.files(urls + [missing])
            #expect(ArchiveDragPayload.outsideMask(for: missingPayload) == [.copy, .link])
            #expect(ArchiveDragPayload.outsideMask(for: mixedPayload) == [.copy, .link])
        }
    }

    @Test func anUnreadableFileKeepsLinkSupport() throws {
        try withSparseFiles(sizes: [1]) { urls in
            let url = urls[0]
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let payload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
        }
    }

    @Test func aNonFileURLKeepsLinkSupport() throws {
        let url = try #require(URL(string: "https://example.com/file.png"))
        let payload: [NSPasteboardWriting] = [url as NSURL]
        #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy, .link])
    }

    @Test func textAndColorOnlyOfferCopy() {
        let text = ArchiveDragPayload.text("hello")
        let color = ArchiveDragPayload.color(.systemRed, formatted: "#FF0000")
        #expect(ArchiveDragPayload.outsideMask(for: text) == [.copy])
        #expect(ArchiveDragPayload.outsideMask(for: color) == [.copy])
        #expect(ArchiveDragPayload.outsideMask(for: text + color) == [.copy])
        #expect(ArchiveDragPayload.outsideMask(for: []) == [.copy])
    }

    @Test(arguments: [UInt64(128 * 1024 * 1024), 128 * 1024 * 1024 + 1])
    func aMixedDragUsesOnlyItsFilePart(size: UInt64) throws {
        try withSparseFiles(sizes: [size]) { urls in
            let filePayload = ArchiveDragPayload.files(urls)
            let mixedPayload = ArchiveDragPayload.text("hello") + filePayload
                + ArchiveDragPayload.color(.systemRed, formatted: "#FF0000")
            let expected: NSDragOperation = size <= 128 * 1024 * 1024 ? [.copy] : [.copy, .link]
            #expect(ArchiveDragPayload.outsideMask(for: mixedPayload) == expected)
        }
    }

    @Test func anImageAndAnotherFileOfTheSameSizeOfferTheSameMask() throws {
        let image = try makePNG()
        defer { try? FileManager.default.removeItem(at: image) }
        let size = try #require(image.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        try withSparseFiles(sizes: [UInt64(size)]) { urls in
            let imagePayload = ArchiveDragPayload.files([image])
            let otherPayload = ArchiveDragPayload.files(urls)
            #expect(ArchiveDragPayload.outsideMask(for: imagePayload) == [.copy])
            #expect(ArchiveDragPayload.outsideMask(for: otherPayload) == [.copy])
        }
    }

    @Test func aMixedCaptureDragUsesTheExportedFileURL() throws {
        let image = try makePNG()
        defer { try? FileManager.default.removeItem(at: image) }
        let capture = ArchiveDragPayload.capture(image, as: .jpg)
        let exported = try #require((capture.first as? NSURL) as URL?)
        #expect(exported.pathExtension == "jpg")
        let payload = ArchiveDragPayload.text("hello") + capture
            + ArchiveDragPayload.color(.systemRed, formatted: "#FF0000")
        #expect(ArchiveDragPayload.outsideMask(for: payload) == [.copy])
    }

    @Test(arguments: [UInt64(128 * 1024 * 1024), 128 * 1024 * 1024 + 1])
    func aSymbolicLinkUsesItsTargetsSize(size: UInt64) throws {
        try withSparseFiles(sizes: [size]) { urls in
            let link = urls[0].deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: urls[0])
            let payload = ArchiveDragPayload.files([link])
            let expected: NSDragOperation = size <= 128 * 1024 * 1024 ? [.copy] : [.copy, .link]
            #expect(ArchiveDragPayload.outsideMask(for: payload) == expected)
        }
    }

    @Test func symbolicLinksToDirectoriesAndMissingFilesKeepLinkSupport() throws {
        try withSparseFiles(sizes: [1]) { urls in
            let directory = urls[0].deletingLastPathComponent()
            let folderLink = directory.appendingPathComponent("folder-link")
            let brokenLink = directory.appendingPathComponent("broken-link")
            try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: directory)
            try FileManager.default.createSymbolicLink(at: brokenLink,
                                                      withDestinationURL: directory.appendingPathComponent("missing"))
            let folderPayload = ArchiveDragPayload.files([folderLink])
            let brokenPayload = ArchiveDragPayload.files([brokenLink])
            #expect(ArchiveDragPayload.outsideMask(for: folderPayload) == [.copy, .link])
            #expect(ArchiveDragPayload.outsideMask(for: brokenPayload) == [.copy, .link])
        }
    }

    private func withSparseFiles(sizes: [UInt64], _ body: ([URL]) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-mask-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try sizes.enumerated().map { index, size in
            let url = directory.appendingPathComponent("file-\(index).dat")
            try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: size)
            return url
        }
        try body(urls)
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
