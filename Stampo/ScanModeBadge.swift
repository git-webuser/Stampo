import AppKit

// MARK: - ScanModeBadge

/// The pill that names what a scan is about to do — "Keep line breaks",
/// "Translate", "Translate to Japanese".
///
/// Extracted from the selection overlay's view so the editor's scanner can put
/// the same badge over its own canvas. The overlay draws it into an `NSView`,
/// the editor into the `CGContext` behind a SwiftUI `Canvas`; both go through
/// `draw(in:)` against whatever graphics context is current, so there is one
/// implementation of the geometry and one of the drawing.
///
/// Geometry is exposed separately from drawing because the overlay redraws only
/// the badge's rect when the pointer moves, and needs the frame before it has
/// anything to draw.
struct ScanModeBadge {
    var mode: ScanSelectionMode
    /// The language a translating scan is headed into, when ⇥ has picked one.
    var translationTarget: Locale.Language?

    /// Verbs, because nothing has happened yet — a mode is armed over a region
    /// the user has not committed to.
    ///
    /// Translation names its destination once there is one to name. With two
    /// languages the destination follows from the text and "Translate" is the
    /// whole truth; past two it is a setting the user can change from right
    /// here, so the badge has to say which way this scan is going.
    var title: String {
        let languages = TranslationLanguages.shared
        guard mode == .translate, languages.offersChoice else {
            return LocaleManager.shared.string(mode.titleKey)
        }
        return String(format: LocaleManager.shared.string("Translate to %@"),
                      TranslationService.displayName(translationTarget ?? languages.destination))
    }

    private var font: NSFont { .systemFont(ofSize: 12, weight: .semibold) }

    private var padding: NSSize { NSSize(width: 9, height: 5) }

    private var symbol: NSImage? {
        guard let name = mode.symbolName else { return nil }
        // Palette colour, not a template tint: drawn straight into the context
        // an untinted symbol comes out black on a black pill.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Height the glyph is drawn at, whatever it is.
    ///
    /// Two SF Symbols at one point size are not one height: `translate` is a
    /// short wide mark, the return arrow is taller. Sizing the pill to the
    /// glyph made the two badges different heights, so the height comes from
    /// this constant and the font instead, and the glyph is scaled into it.
    private var glyphHeight: CGFloat { 13 }

    private var glyphSize: NSSize {
        guard let natural = symbol?.size, natural.height > 0 else { return .zero }
        return NSSize(width: (natural.width / natural.height) * glyphHeight,
                      height: glyphHeight)
    }

    /// Measured from the font rather than the string, so a word with no
    /// ascenders and descenders, and a badge whose height depended on which
    /// word it carried, stay the same height.
    private var textHeight: CGFloat {
        ceil(font.ascender - font.descender)
    }

    var size: NSSize {
        let text = NSAttributedString(string: title, attributes: [.font: font])
        let glyph = glyphSize
        let gap: CGFloat = glyph.width > 0 ? 5 : 0
        return NSSize(
            width: ceil(glyph.width) + gap + ceil(text.size().width) + padding.width * 2,
            height: max(textHeight, glyphHeight) + padding.height * 2
        )
    }

    /// Placement against a selection: above the frame, below it when the top of
    /// the screen is in the way, and only as a last resort inside — a badge
    /// lying across the frame hides the very edge the user is positioning.
    func frame(over sel: NSRect, in bounds: NSRect) -> NSRect {
        let size = size
        let gap: CGFloat = 8

        var y = sel.maxY + gap
        if y + size.height > bounds.maxY {
            y = sel.minY - size.height - gap
        }
        // Both outside placements off-screen means the selection spans nearly
        // the whole height; tuck it just inside the top edge of the frame.
        if y < bounds.minY {
            y = min(sel.maxY - size.height - gap, bounds.maxY - size.height - gap)
        }

        let x = min(max(sel.minX, 4), max(4, bounds.maxX - size.width - 4))
        return NSRect(x: x, y: max(4, y), width: size.width, height: size.height)
    }

    /// Placement against the pointer, before any frame exists. Offset down and
    /// right of the crosshair so it never sits under the cursor itself, and
    /// flipped above the pointer near the bottom of the screen.
    func frame(nearPointer point: NSPoint, in bounds: NSRect) -> NSRect {
        let size = size
        var y = point.y - 30
        if y < bounds.minY + 4 { y = point.y + 18 }
        let x = min(max(point.x + 14, 4), max(4, bounds.maxX - size.width - 4))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Draws into the current `NSGraphicsContext`. Callers that own a raw
    /// `CGContext` (a SwiftUI `Canvas`) push one around this call.
    func draw(in frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.82).setFill()
        path.fill()
        (mode.tint ?? .white).withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbol = symbol
        let glyphSize = glyphSize
        let gap: CGFloat = glyphSize.width > 0 ? 5 : 0

        var x = frame.minX + padding.width
        if let symbol {
            let origin = NSPoint(x: x, y: frame.midY - glyphSize.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: glyphSize),
                        from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high.rawValue])
            x += glyphSize.width + gap
        }

        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
        ])
        // Centred on the font's baseline metrics, so a word with a descender
        // sits on the same line as one without.
        text.draw(at: NSPoint(x: x, y: frame.midY - textHeight / 2 - font.descender / 2))
    }
}
