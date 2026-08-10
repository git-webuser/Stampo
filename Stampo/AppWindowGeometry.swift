import AppKit

// MARK: - Window placement

/// Where a free-standing window of an agent app opens.
///
/// Shared by the wizard and the translation setup window rather than written
/// twice: both are `.titled` panels with no dock icon behind them, and both
/// have to land where the user is actually looking on a multi-display desk.
extension NSWindow {

    /// Centres on the display the pointer is on, not on the "main" one.
    ///
    /// An agent app has no window the system can take a hint from, so
    /// `center()` puts the window on whichever display macOS calls main —
    /// regularly the wrong one, and occasionally one the user is not looking
    /// at at all. The pointer is the only evidence available.
    func centerOnPointerScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? screen
        guard let visibleFrame = targetScreen?.visibleFrame else {
            center()
            return
        }

        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        setFrameOrigin(origin)
        keepOnScreen(within: visibleFrame)
    }

    /// Pulls the window back inside the visible frame after it has grown.
    ///
    /// These windows size themselves to their SwiftUI content, so a step that
    /// adds a line can push the bottom edge under the Dock after the window
    /// was already placed.
    func keepOnScreen(within explicitVisibleFrame: NSRect? = nil) {
        guard let visibleFrame = explicitVisibleFrame
            ?? screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        else { return }

        var wanted = frame
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - wanted.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - wanted.height)
        wanted.origin.x = min(max(wanted.minX, visibleFrame.minX), maximumX)
        wanted.origin.y = min(max(wanted.minY, visibleFrame.minY), maximumY)

        if wanted.origin != frame.origin {
            setFrameOrigin(wanted.origin)
        }
    }
}
