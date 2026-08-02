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
}
