import AppKit

/// Where the editor's colours come from and go back to.
///
/// The decor inspector needs two things the editor cannot own: the colours the
/// user has already collected, and somewhere to put a new one. Both are the
/// archive's — a colour picked with the eyedropper is an archive entry, and
/// there is no reason for the editor to keep a second, private list of colours
/// the user cannot see from the panel.
///
/// It is a protocol rather than the archive model itself so the editor keeps
/// knowing only what it uses: a list of colours, and one verb. The conformance
/// lives with the archive, and `NotchPanelController` — which owns it — is what
/// hands it to the editor.
@MainActor protocol PresentationColorShelf: AnyObject {
    /// Newest first, as the archive keeps them.
    var shelfColors: [Presentation.Color] { get }
    /// Adds a colour, or moves an existing one back to the front. Mirrors what
    /// picking the same colour twice with the eyedropper does.
    func addShelfColor(_ color: Presentation.Color)
}

extension Presentation.Color {
    /// sRGB, always — the archive stores whatever `NSColor` the picker handed
    /// it, and a colour in another space would silently shift on the way into
    /// a background the renderer draws in sRGB.
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        self.init(red: rgb.redComponent, green: rgb.greenComponent,
                  blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
