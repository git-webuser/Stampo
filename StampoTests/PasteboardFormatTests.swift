import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Stampo

/// The editor's Copy hands over the composite in the format the user set for
/// their captures. Writing the NSImage instead silently produced a TIFF
/// whatever the setting said — several times the size and the wrong type.
@MainActor
@Suite struct PasteboardFormatTests {

    private func makeRep(width: Int = 40, height: Int = 30) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A pasteboard of our own: the general one belongs to whoever is using
    /// the Mac while the tests run.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("stampo-test-\(UUID().uuidString)"))
    }

    @Test func everyFormatArrivesAsItself() throws {
        for format in EditorExportFormat.allCases {
            let board = makePasteboard()
            board.writeImage(makeRep(), as: format)

            let type = NSPasteboard.PasteboardType(format.contentType.identifier)
            let data = try #require(board.data(forType: type),
                                    "\(format.rawValue) is not on the pasteboard as itself")
            #expect(!data.isEmpty)
            // What is on the pasteboard decodes as the type it claims to be.
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == format.contentType.identifier)
        }
    }

    /// The chosen format leads the pasteboard's type list, which is what a
    /// receiver asking for the best available takes. macOS adds converted
    /// flavours of its own behind it — a TIFF among them — and those staying
    /// behind is the whole difference from writing an NSImage, where the TIFF
    /// was all there was.
    @Test func theChosenFormatLeadsAndTheConversionsFollow() throws {
        let board = makePasteboard()
        board.writeImage(makeRep(), as: .png)

        #expect(board.types?.first == .png)
        let tiffIndex = try #require(board.types?.firstIndex(of: .tiff))
        let pngIndex = try #require(board.types?.firstIndex(of: .png))
        #expect(pngIndex < tiffIndex)
    }

    @Test func theImageSurvivesTheRoundTrip() throws {
        let board = makePasteboard()
        board.writeImage(makeRep(width: 40, height: 30), as: .png)
        let image = try #require(NSImage(pasteboard: board))
        #expect(image.size.width == 40)
        #expect(image.size.height == 30)
    }

    // MARK: - Copying a file (archive cells, capture thumbnail, pinned window)

    /// Writes a real PNG file and returns it, plus its bytes for comparison.
    private func makePNGFile() throws -> (url: URL, data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-test-\(UUID().uuidString).png")
        let data = try #require(makeRep().representation(using: .png, properties: [:]))
        try data.write(to: url)
        return (url, data)
    }

    /// `writeImage(at:)` reads off the main thread, so the pasteboard fills in
    /// a moment. Polling, not RunLoop pumping — see the note in
    /// ThumbnailLoaderTests.
    private func waitForPasteboard(_ board: NSPasteboard) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if board.types?.isEmpty == false { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return board.types?.isEmpty == false
    }

    /// A capture already in the chosen format goes over untouched — the same
    /// bytes that are on disk, not a TIFF re-encoded from a decode of them.
    @Test func copyingAFileAlreadyInFormatHandsOverItsOwnBytes() async throws {
        let (url, data) = try makePNGFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let board = makePasteboard()
        board.writeImage(at: url, as: .png)
        #expect(await waitForPasteboard(board))

        #expect(board.data(forType: .png) == data)
        #expect(board.types?.first == .png)
    }

    /// A capture taken before the setting changed still arrives in the format
    /// the user asks for now.
    @Test func copyingAFileInAnotherFormatReEncodesIt() async throws {
        let (url, _) = try makePNGFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let board = makePasteboard()
        board.writeImage(at: url, as: .jpg)
        #expect(await waitForPasteboard(board))

        let type = NSPasteboard.PasteboardType(EditorExportFormat.jpg.contentType.identifier)
        let data = try #require(board.data(forType: type))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        // The picture itself is intact, not just the wrapper.
        let image = try #require(NSImage(pasteboard: board))
        #expect(image.size.width == 40)
        #expect(image.size.height == 30)
    }

    /// The other half of the same job: an app that takes the file rather than
    /// the image data must not get the old format back. The file on the
    /// clipboard is the re-encoded one, named after the capture.
    @Test func reEncodingAlsoReplacesTheFileOnTheClipboard() async throws {
        let (url, _) = try makePNGFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let board = makePasteboard()
        board.writeImage(at: url, as: .jpg)
        #expect(await waitForPasteboard(board))

        let files = try #require(board.readObjects(forClasses: [NSURL.self]) as? [URL])
        let file = try #require(files.first)
        #expect(file.pathExtension == "jpg")
        #expect(file.deletingPathExtension().lastPathComponent
                == url.deletingPathExtension().lastPathComponent)
        #expect(file.standardizedFileURL != url.standardizedFileURL)

        let onDisk = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetType(onDisk) as String? == UTType.jpeg.identifier)
    }

    /// Nothing is copied about when the formats already agree — the file that
    /// travels is the capture itself, not a throwaway duplicate of it.
    @Test func matchingFormatsKeepTheOriginalFile() async throws {
        let (url, _) = try makePNGFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let board = makePasteboard()
        board.writeImage(at: url, as: .png)
        #expect(await waitForPasteboard(board))

        let files = try #require(board.readObjects(forClasses: [NSURL.self]) as? [URL])
        #expect(files.first?.standardizedFileURL == url.standardizedFileURL)
    }

    /// Nothing readable as an image: the file still goes over as a file rather
    /// than the clipboard being left empty.
    @Test func copyingSomethingUnreadableStillCarriesTheURL() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-test-\(UUID().uuidString).stampo-unknown")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let board = makePasteboard()
        board.writeImage(at: url)
        #expect(await waitForPasteboard(board))

        let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.contains { $0.standardizedFileURL == url.standardizedFileURL } == true)
    }
}
