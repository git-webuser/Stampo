import Foundation

/// When the panel window gives the pointer back to whatever is under it.
///
/// The window is as tall as the Translator can get, and below what is drawn it
/// is transparent. `NotchPanelController.updateMouseRegion` asks this each time
/// the pointer moves, and on a timer while an archive drag is in flight.
nonisolated enum PanelMouseRegion {
    /// - Parameters:
    ///   - onDrawnContent: the pointer is over what the panel draws, not over
    ///     the transparent rest of its window.
    ///   - buttonsDown: a mouse button is held. A press that started on the
    ///     panel must stay with it, and a file arriving from Finder is a
    ///     dragging session the window has to be able to receive.
    ///   - archiveDragInFlight: one of the archive's own cells is being dragged
    ///     out. Nothing arrives from outside then — the payload is ours — so
    ///     the window has no reason to hold the pointer over its empty part,
    ///     where a drop would land on the panel instead of the window under it.
    static func ignoresMouse(onDrawnContent: Bool, buttonsDown: Bool, archiveDragInFlight: Bool) -> Bool {
        // Followed by position alone: the held button is the drag itself, and
        // it is the very thing that kept the window taking the pointer here.
        if archiveDragInFlight { return !onDrawnContent }
        return !(onDrawnContent || buttonsDown)
    }
}
