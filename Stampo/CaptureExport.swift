import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One rule for a capture leaving the app, whichever door it goes out of — the
/// clipboard, a drag: it leaves in the format the user picked for their
/// captures.
///
/// A capture is normally already in that format, and then nothing is touched
/// and nothing is copied: its own bytes and its own file go over. Only one
/// taken before the setting changed is re-encoded, and then it needs a file of
/// its own — the original on disk is still in the old format, and every
/// receiver that prefers files to image data (mail, messengers, Finder) would
/// take it straight back and undo the exercise.
enum CaptureExport {

    struct Payload {
        let data: Data
        let type: NSPasteboard.PasteboardType
        /// The file to hand over: the capture itself, or the throwaway
        /// carrying the re-encode.
        let url: URL
    }

    /// Bytes, type and file for `url`, or nil when it cannot be read or is not
    /// an image at all. A re-encode that fails falls back to the capture as it
    /// lies — better the wrong format than nothing.
    static func payload(for url: URL,
                        as format: EditorExportFormat = .fromSettings()) -> Payload? {
        autoreleasepool {
            guard let data = try? Data(contentsOf: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let uti = CGImageSourceGetType(source) as String?
            else { return nil }

            let wanted = format.contentType.identifier
            let asIs = Payload(data: data, type: NSPasteboard.PasteboardType(uti), url: url)
            guard uti != wanted else { return asIs }

            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return asIs }
            let (fileType, properties) = format.encoding
            guard let converted = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: fileType, properties: properties),
                  let exported = try? ScreenshotFileStore().writeTemporaryExport(
                    converted,
                    named: url.deletingPathExtension().lastPathComponent,
                    format: format.rawValue)
            else { return asIs }
            return Payload(data: converted,
                           type: NSPasteboard.PasteboardType(wanted),
                           url: exported)
        }
    }

    /// The file alone, for a drag: the capture's own when it already agrees
    /// with the setting, the re-encoded throwaway when it does not, and the
    /// capture's own again if anything went wrong on the way.
    static func fileURL(for url: URL,
                        as format: EditorExportFormat = .fromSettings()) -> URL {
        payload(for: url, as: format)?.url ?? url
    }
}
