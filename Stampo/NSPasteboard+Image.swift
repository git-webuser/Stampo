import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSPasteboard {

    /// Publishes already-encoded worker output without reconstructing an
    /// `NSBitmapImageRep` on the MainActor.
    func writeImage(_ data: Data, as format: EditorExportFormat) {
        clearContents()
        setData(data, forType: NSPasteboard.PasteboardType(format.contentType.identifier))
    }

    /// Puts an already-rendered composite on the pasteboard, encoded in the
    /// format the user picked in Settings.
    ///
    /// Writing the `NSImage` instead — which is what an `NSPasteboard`
    /// convenience does — hands over a TIFF whatever the setting says: an
    /// uncompressed copy several times the size of the PNG the same capture
    /// saves as, and not the format the user asked their captures to be in.
    /// Only the chosen format is authored, and it is first in the pasteboard's
    /// type list, so that is what a receiver asking for the best available
    /// gets. macOS still offers converted flavours (a TIFF among them) behind
    /// it, which is what keeps apps that read nothing else working.
    func writeImage(_ rep: NSBitmapImageRep, as format: EditorExportFormat) {
        let (fileType, properties) = format.encoding
        clearContents()
        guard let data = rep.representation(using: fileType, properties: properties) else {
            // Encoding is not supposed to fail; an empty clipboard would be a
            // worse answer than the TIFF this used to write.
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            writeObjects([image])
            return
        }
        setData(data, forType: NSPasteboard.PasteboardType(format.contentType.identifier))
    }

    /// Copies the image file at `url` to the pasteboard in `format`: the
    /// picture as data, and a file beside it so a paste in Finder still lands
    /// a file. Both say the same thing — see `CaptureExport`, which is also
    /// what a drag out of the archive goes through.
    ///
    /// A decode into an `NSImage` — what this used to write — hands over a TIFF
    /// whatever the file is and whatever the setting says. Falls back to the
    /// URL alone when the file cannot be read or is not an image after all.
    @MainActor
    func writeImage(at url: URL, as format: EditorExportFormat = .fromSettings()) {
        // The format travels as itself: the enum is Sendable, so there is no
        // reason to send its raw string and parse it back — a round trip that
        // could only ever lose, since an unparseable string would quietly
        // become PNG.
        let worker = Task.detached(priority: .userInitiated) {
            CaptureExport.payload(for: url, as: format)
        }
        Task { @MainActor [weak self] in
            let payload = await worker.value
            guard let self else { return }
            self.clearContents()
            guard let payload else {
                self.writeObjects([url as NSURL])
                return
            }
            // Two items, image first, exactly as the NSImage version wrote
            // them: apps take the picture, Finder takes the file.
            let item = NSPasteboardItem()
            item.setData(payload.data,
                         forType: NSPasteboard.PasteboardType(payload.typeIdentifier))
            self.writeObjects([item, payload.url as NSURL])
        }
    }
}
