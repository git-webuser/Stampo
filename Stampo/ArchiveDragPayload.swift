import AppKit

/// What an archive cell puts on the pasteboard when it is dragged out.
///
/// Files ride out as plain `NSURL`s — every receiver understands those. The two
/// value kinds need building: a text entry is a string, and a color is written
/// in *both* forms, so the same drag lands as a swatch in a color well and as
/// "#FF3B30" in an editor. Pure and static so the drag and the context menus
/// can't disagree about what an item is.
enum ArchiveDragPayload {

    static func files(_ urls: [URL]) -> [NSPasteboardWriting] {
        urls.map { $0 as NSURL }
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
