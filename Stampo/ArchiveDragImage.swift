import AppKit

/// The picture a dragged capture or file travels as: its thumbnail drawn the way
/// the cell draws it — filled into the cell's rectangle, corners cut at the
/// cell's radius — so what leaves the cell looks like the cell.
///
/// The sibling of `archiveColorDragImage` and `archiveTextDragImage`, and it
/// follows them on purpose: the image is made at the cell's size and radius, and
/// `ArchiveDragShimView` shrinks it into the drag frame afterwards, so every kind
/// of item shrinks and rounds the same way. The raw thumbnail used to go out
/// instead. It has square corners, and it keeps its own proportions, which the
/// frame (always the cell's 1.6 : 1) then squeezed.
///
/// A thumbnail that has not arrived yet (nil) or has no size stays as it is: the
/// drag starts without a picture, as before.
func archiveThumbnailDragImage(_ thumbnail: NSImage?, size: NSSize, cornerRadius: CGFloat) -> NSImage? {
    guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else { return thumbnail }

    // Aspect-fill, centred: the cell's `.scaledToFill()`.
    let scale = max(size.width / thumbnail.size.width, size.height / thumbnail.size.height)
    let drawn = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
    let target = NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                        width: drawn.width, height: drawn.height)

    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    thumbnail.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    image.unlockFocus()
    return image
}
