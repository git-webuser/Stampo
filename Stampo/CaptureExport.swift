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

    /// Where a re-encoded copy is parked. The two doors keep the file for
    /// different lengths of time, and each throwaway is swept by the rule of
    /// the door it went out of — see `ScreenshotFileStore`.
    private enum Destination {
        /// The clipboard, which holds one thing at a time and can be pasted
        /// from at any distance from the copy.
        case clipboard
        /// A drag, which is over by the time the mouse comes up.
        case drag
    }

    /// Bytes, type and file for `url`, or nil when it cannot be read or is not
    /// an image at all. A re-encode that fails falls back to the capture as it
    /// lies — better the wrong format than nothing.
    static func payload(for url: URL,
                        as format: EditorExportFormat = .fromSettings()) -> Payload? {
        payload(for: url, as: format, to: .clipboard)
    }

    private static func payload(for url: URL,
                                as format: EditorExportFormat,
                                to destination: Destination) -> Payload? {
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
                  let exported = try? stage(converted,
                                            named: url.deletingPathExtension().lastPathComponent,
                                            format: format,
                                            to: destination)
            else { return asIs }
            return Payload(data: converted,
                           type: NSPasteboard.PasteboardType(wanted),
                           url: exported)
        }
    }

    private static func stage(_ data: Data,
                              named name: String,
                              format: EditorExportFormat,
                              to destination: Destination) throws -> URL {
        let store = ScreenshotFileStore()
        switch destination {
        case .clipboard:
            return try store.writeClipboardExport(data, named: name, format: format.rawValue)
        case .drag:
            return try store.writeTemporaryExport(data, named: name, format: format.rawValue)
        }
    }

    /// The file alone, for a drag: the capture's own when it already agrees
    /// with the setting, the re-encoded throwaway when it does not, and the
    /// capture's own again if anything went wrong on the way.
    static func fileURL(for url: URL,
                        as format: EditorExportFormat = .fromSettings()) -> URL {
        payload(for: url, as: format, to: .drag)?.url ?? url
    }
}
