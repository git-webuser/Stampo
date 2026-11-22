import AppKit

/// What a left click does to the panel, decided from where the click landed.
///
/// `NotchHoverController` hears every left click through two `NSEvent`
/// monitors and hops to the main actor before it acts. The pointer can move
/// during that hop, so the answer must come from the point the *event* carries
/// (`screenPoint(of:)`), never from `NSEvent.mouseLocation` read later: a click
/// inside the panel is not an outside click because the pointer has already left.
nonisolated enum NotchClick {

    enum Action: Equatable {
        /// The click means nothing to the panel.
        case ignore
        /// Open the panel on the clicked screen.
        case show
        /// Close it: the click hit the notch while the panel was open.
        case hideOnNotchClick
        /// Close it: the click landed outside the drawn panel.
        case hideOnOutsideClick
    }

    /// The screen the click landed on, as far as the decision cares.
    struct ScreenSnapshot {
        /// The click-to-open zone on that screen; `.null` when it has none
        /// (menu bar hidden), which makes every click mean nothing.
        var triggerRect: CGRect
        /// A physical notch. Without one, the trigger zone sits over the panel's
        /// own buttons, so it cannot close the panel.
        var hasPhysicalNotch: Bool
    }

    /// The panel's state at the moment the click is handled.
    struct PanelSnapshot {
        var isVisible: Bool
        /// Sleep, Space or display change left the panel bound to another
        /// desktop: `isVisible` cannot be trusted until it is shown again.
        var needsSpaceRebind: Bool
        /// Pinned, picking an area or a colour, a menu is open, and so on.
        var suppressesAutoHide: Bool
        /// What the panel draws, in screen coordinates. The window around it is
        /// taller and transparent, so the window frame is the wrong test.
        var drawnRect: CGRect
    }

    static func decide(at point: CGPoint, screen: ScreenSnapshot, panel: PanelSnapshot) -> Action {
        guard !screen.triggerRect.isNull else { return .ignore }

        let inTrigger = screen.triggerRect.contains(point)

        // A stale panel may still report `isVisible`, but the user cannot see
        // it. Treat it as closed so a click on the notch brings it back.
        if panel.isVisible && !panel.needsSpaceRebind {
            if panel.suppressesAutoHide { return .ignore }
            if screen.hasPhysicalNotch && inTrigger { return .hideOnNotchClick }
            return panel.drawnRect.contains(point) ? .ignore : .hideOnOutsideClick
        }

        return inTrigger ? .show : .ignore
    }

    /// Where the click landed, in screen coordinates.
    ///
    /// A global monitor gets events with no window, and for those AppKit puts
    /// the screen location in `locationInWindow`. A local monitor gets events
    /// for our own windows, whose location is in window coordinates.
    @MainActor
    static func screenPoint(of event: NSEvent) -> CGPoint {
        screenPoint(locationInWindow: event.locationInWindow, in: event.window)
    }

    @MainActor
    static func screenPoint(locationInWindow location: CGPoint, in window: NSWindow?) -> CGPoint {
        guard let window else { return location }
        return window.convertPoint(toScreen: location)
    }

    /// The first screen whose frame holds the point, or nil when none does.
    /// The caller picks the fallback (`NSScreen.main`).
    static func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}
