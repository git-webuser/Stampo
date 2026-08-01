import AppKit
import Foundation
import Testing
@testable import Stampo

// Hosted tests run inside Stampo.app, so Quick Look answers for real here —
// these exercise the loader end to end rather than against a stub. The loader
// is @MainActor and publishes into `image` from a @MainActor Task, so every
// wait below is `Task.sleep` polling; pumping the RunLoop would starve exactly
// the task under test and make every result look nil.
@MainActor
@Suite struct ThumbnailLoaderTests {

    // MARK: - Fixtures

    /// Writes a solid PNG of the given pixel size to a fresh temp file.
    private func makePNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }

    /// A file no Quick Look generator can render: an unknown extension holding
    /// bytes that aren't a document of any kind.
    private func makeUnpreviewableFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-\(UUID().uuidString).stampo-unknown")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        return url
    }

    /// Polls `condition` on the main actor until it holds or the budget runs
    /// out. Returns whether it held, so callers can assert on the outcome
    /// instead of on a bare timeout.
    @discardableResult
    private func wait(seconds: Double = 10, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Longest edge of the produced image. `NSImage(cgImage:size: .zero)` adopts
    /// the CGImage's pixel dimensions, so this is in pixels.
    private func longestEdge(_ image: NSImage) -> CGFloat {
        max(image.size.width, image.size.height)
    }

    // MARK: - Loading

    @Test func loadsAThumbnailForAnImageFile() async throws {
        let url = try makePNG(width: 400, height: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ThumbnailLoader()
        #expect(loader.image == nil)
        loader.load(imageURL: url)

        #expect(await wait { loader.image != nil })
    }

    @Test func maxPixelSizeCapsTheLongestEdgeAndKeepsTheAspect() async throws {
        let url = try makePNG(width: 400, height: 200)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ThumbnailLoader()
        loader.load(imageURL: url, maxPixelSize: 64)
        #expect(await wait { loader.image != nil })

        let image = try #require(loader.image)
        // Quick Look aspect-fits into the requested box at scale 1 — a landscape
        // source stays landscape and neither edge outgrows the request.
        #expect(longestEdge(image) <= 64)
        #expect(image.size.width > image.size.height)
    }

    /// The two-pass request in `generate(for:maxPixelSize:)`: a file nothing can
    /// preview must still come back with its document icon rather than nil.
    @Test func fileWithoutAPreviewFallsBackToItsIcon() async throws {
        let url = try makeUnpreviewableFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ThumbnailLoader()
        loader.load(imageURL: url)

        #expect(await wait { loader.image != nil })
    }

    /// A archive entry whose file was moved or deleted behind the app's back still
    /// gets a picture: Quick Look answers the `.icon` pass from the path's type
    /// alone, without touching the bytes. So a stale cell shows the generic PNG
    /// document icon rather than falling back to the placeholder glyph — worth
    /// pinning down, because it means "loader produced an image" is no evidence
    /// the file is still there.
    @Test func missingFileStillYieldsTheTypeIcon() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-test-missing-\(UUID().uuidString).png")
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let loader = ThumbnailLoader()
        loader.load(imageURL: url)

        #expect(await wait { loader.image != nil })
    }

    // MARK: - Identity guards

    @Test func reloadingTheSameURLKeepsTheLoadedImage() async throws {
        let url = try makePNG(width: 400, height: 400)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = ThumbnailLoader()
        loader.load(imageURL: url)
        #expect(await wait { loader.image != nil })
        let first = try #require(loader.image)

        // Same URL → early return, so no flicker back to nil. SwiftUI re-renders
        // call load() on every update; a reset here would blank the cell.
        loader.load(imageURL: url)
        #expect(loader.image === first)
    }

    @Test func switchingURLClearsTheImageImmediately() async throws {
        let landscape = try makePNG(width: 400, height: 200)
        let portrait  = try makePNG(width: 200, height: 400)
        defer {
            try? FileManager.default.removeItem(at: landscape)
            try? FileManager.default.removeItem(at: portrait)
        }

        let loader = ThumbnailLoader()
        loader.load(imageURL: landscape)
        #expect(await wait { loader.image != nil })

        // A cell reused for another file must never show the previous preview.
        loader.load(imageURL: portrait)
        #expect(loader.image == nil)

        #expect(await wait { loader.image != nil })
        let image = try #require(loader.image)
        #expect(image.size.height > image.size.width)
    }

    @Test func lateResultFromASupersededLoadIsDropped() async throws {
        let landscape = try makePNG(width: 400, height: 200)
        let portrait  = try makePNG(width: 200, height: 400)
        defer {
            try? FileManager.default.removeItem(at: landscape)
            try? FileManager.default.removeItem(at: portrait)
        }

        let loader = ThumbnailLoader()
        // Second load before the first has answered: whichever generation
        // finishes last, only the latest URL may reach `image`.
        loader.load(imageURL: landscape)
        loader.load(imageURL: portrait)

        #expect(await wait { loader.image != nil })
        #expect(try #require(loader.image).size.height > #require(loader.image).size.width)

        // Give the superseded request room to land late — the loadedURL guard
        // is what keeps it out.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let settled = try #require(loader.image)
        #expect(settled.size.height > settled.size.width)
    }
}
