import AppKit
import Testing
@testable import Stampo

/// A window per document: the editor used to be one window that swapped its
/// contents, so a second screenshot could not be opened until the first was
/// settled — the editor locked the capture behind whatever was already in it.
@MainActor @Suite(.serialized) struct EditorWindowsTests {

    private func writePNG(_ name: String) throws -> URL {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    @Test func twoShotsOpenTwoWindowsAndTheSameShotComesForward() throws {
        EditorWindowController.closeAllForTesting()
        let first = try writePNG("editor-windows-first.png")
        let second = try writePNG("editor-windows-second.png")
        defer {
            EditorWindowController.closeAllForTesting()
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        EditorWindowController.open(url: first)
        #expect(EditorWindowController.openCount == 1)

        // The point of the whole change: the second shot does not have to wait
        // for the first to be settled.
        EditorWindowController.open(url: second)
        #expect(EditorWindowController.openCount == 2)

        // One window per file, though: opening the same shot again brings its
        // editor forward rather than starting a second race to save over it.
        EditorWindowController.open(url: first)
        #expect(EditorWindowController.openCount == 2)
    }

    /// A file that cannot be read leaves nothing behind — no empty editor in
    /// the list, and nothing for the next question about unsaved work to walk
    /// into.
    @Test func aFileThatCannotBeReadOpensNothing() {
        EditorWindowController.closeAllForTesting()
        defer { EditorWindowController.closeAllForTesting() }
        let missing = URL(fileURLWithPath: "/nonexistent/editor-windows-ghost.png")
        EditorWindowController.open(url: missing)
        #expect(EditorWindowController.openCount == 0)
    }

    /// With nothing dirty the question passes straight through, however many
    /// windows are open — it is asked before quitting and before the
    /// first-launch window takes the screen.
    @Test func cleanEditorsNeverStandInTheWay() throws {
        EditorWindowController.closeAllForTesting()
        let url = try writePNG("editor-windows-clean.png")
        defer {
            EditorWindowController.closeAllForTesting()
            try? FileManager.default.removeItem(at: url)
        }
        EditorWindowController.open(url: url)
        #expect(EditorWindowController.confirmDiscardingUnsavedWork(afterSave: {}))
    }
}
