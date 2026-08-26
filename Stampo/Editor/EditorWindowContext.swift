import AppKit

/// What an editor's views need from the window they live in.
///
/// They used to ask `EditorWindowController.shared`, which was true only while
/// there was one editor: with a window per document, "is the editor key" has as
/// many answers as there are windows, and a canvas that reads the wrong one
/// acts on keys pressed in somebody else's document. Handing each editor a
/// context closes that question — every view answers about *its* window.
///
/// Closures rather than a window reference, because the views must not be able
/// to reach for anything else the window happens to own.
struct EditorWindowContext {
    /// Whether this editor's own window has the keyboard.
    var isKeyWindow: () -> Bool = { false }
    /// Parent for a window-bound child panel — the scanner's overlay.
    var overlayParent: () -> NSWindow? = { nil }
    /// Shows a toast on the screen this editor is on.
    var showCaptureOutcome: (TextCaptureHUD.Outcome) -> Void = { _ in }

    /// For previews and tests, where there is no window: nothing is key,
    /// nothing is parented, and a toast goes nowhere.
    static let detached = EditorWindowContext()
}
