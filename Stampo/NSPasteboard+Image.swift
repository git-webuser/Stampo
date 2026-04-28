import AppKit
import ImageIO

extension NSPasteboard {

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
