import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSPasteboard {

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

    /// Copies the image at `url` to the pasteboard.
    /// Falls back to writing only the URL if the CGImage cannot be decoded.
    func writeImage(at url: URL) {
        Task.detached(priority: .userInitiated) {
            let image: NSImage? = autoreleasepool {
                guard
                    let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
                else { return nil }
                return NSImage(cgImage: cgImage, size: .zero)
            }
            await MainActor.run {
                self.clearContents()
                if let image {
                    self.writeObjects([image, url as NSURL])
                } else {
                    self.writeObjects([url as NSURL])
                }
            }
        }
    }
}
