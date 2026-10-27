import AppKit

/// What an archive cell puts on the pasteboard when it is dragged out.
///
/// Files ride out as plain `NSURL`s — every receiver understands those. The two
/// value kinds need building: a text entry is a string, and a color is written
/// in *both* forms, so the same drag lands as a swatch in a color well and as
/// "#FF3B30" in an editor. Pure and static so the drag and the context menus
/// can't disagree about what an item is.
enum ArchiveDragPayload {

    // A file's ceiling must not depend on whether it has neighbours in the drag.
    static let singleFileLimit = 128 * 1024 * 1024
    // Even small files together can make a copy too expensive for one drag.
    static let selectionLimit = 512 * 1024 * 1024

    /// Decide for the whole drag: offering a link lets the receiver turn even
    /// a small working file into an alias instead of a usable copy.
    static func outsideMask(for payload: [NSPasteboardWriting]) -> NSDragOperation {
        guard payload.contains(where: { $0 is NSURL }) else { return [.copy] }
        return copiesOut(payload) ? [.copy] : [.copy, .link]
    }

    /// Both the per-file ceiling and the selection's total must allow copying.
    /// Packages are filesystem directories and keep link support: sizing one
    /// would walk all its contents on the main thread.
    static func copiesOut(_ payload: [NSPasteboardWriting]) -> Bool {
        let urls = payload.compactMap { ($0 as? NSURL) as URL? }
        guard !urls.isEmpty else { return false }
        var totalSize = 0
        for url in urls {
            guard url.isFileURL else { return false }
            // A symbolic link is sized by its target, just like the file the
            // receiver will use. Missing or unreadable targets keep link support.
            let target = url.resolvingSymlinksInPath()
            guard let values = try? target.resourceValues(forKeys: [.isRegularFileKey,
                                                                  .isReadableKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isReadable == true,
                  let size = values.fileSize, size >= 0,
                  size <= singleFileLimit,
                  size <= selectionLimit - totalSize else { return false }
            totalSize += size
        }
        return true
    }

    static func files(_ urls: [URL]) -> [NSPasteboardWriting] {
        urls.map { $0 as NSURL }
    }

    /// A capture rather than any old file: it leaves in the format the user
    /// picked, the same as it would through the clipboard. Only for the app's
    /// own screenshots — a file dropped into the archive is whatever it is and
    /// leaves untouched. Built when the drag starts, not when the cell draws:
    /// a mismatched capture is re-encoded here.
    static func capture(_ url: URL,
                        as format: EditorExportFormat = .fromSettings()) -> [NSPasteboardWriting] {
        [CaptureExport.fileURL(for: url, as: format) as NSURL]
    }

    static func text(_ text: String) -> [NSPasteboardWriting] {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return [item]
    }

    /// - Parameter formatted: the color in the notation the archive header is
    ///   showing, so what lands in a text editor matches what the cell reads.
    static func color(_ color: NSColor, formatted: String) -> [NSPasteboardWriting] {
        let item = NSPasteboardItem()
        item.setString(formatted, forType: .string)
        // Ask NSColor for its own representation rather than archiving by hand:
        // this is byte-for-byte what AppKit would put on the pasteboard, so a
        // color well accepts it exactly as it accepts a drag from Colors.
        if let plist = color.pasteboardPropertyList(forType: .color) as? Data {
            item.setData(plist, forType: .color)
        }
        return [item]
    }
}
