import AppKit
import Testing
@testable import Stampo

/// The editor's scanner puts the selection overlay over the rect its image
/// occupies rather than over a whole display, so the conversion out of the
/// view's coordinates has to be measured against the panel, not the screen.
/// These assert the relationship rather than absolute pixels: the numbers
/// depend on the display the tests happen to run on, the relationship does not.
@MainActor
@Suite struct OverlayPanelOriginTests {

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    @Test func fullScreenFormIsThePanelFormAtTheDisplayOrigin() {
        let viewRect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(
            viewRectToCGRect(viewRect, screen: screen)
            == viewRectToCGRect(viewRect, panelOrigin: screen.frame.origin, screen: screen)
        )
    }

    /// Moving the panel right moves the result right; moving it *up* in AppKit
    /// coordinates moves it *down* in CG's top-left space. Getting this flip
    /// wrong is the failure that would put an editor scan in the wrong place
    /// while still looking plausible.
    @Test func panelOriginShiftsTheResultAndInvertsTheVerticalAxis() {
        let viewRect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let origin = screen.frame.origin
        let base = viewRectToCGRect(viewRect, panelOrigin: origin, screen: screen)
        let moved = viewRectToCGRect(
            viewRect,
            panelOrigin: CGPoint(x: origin.x + 70, y: origin.y + 25),
            screen: screen
        )

        #expect(moved.minX == base.minX + 70)
        #expect(moved.minY == base.minY - 25)
        #expect(moved.size == base.size)
    }

    /// A selection is reported in the panel's own coordinates, so an overlay
    /// that does not start at the display's corner must still land where the
    /// user drew it: view-local (0,0) belongs to the panel, not the screen.
    @Test func selectionInsideAnInsetPanelLandsAtThePanelNotTheScreen() {
        let inset = CGPoint(x: screen.frame.minX + 200, y: screen.frame.minY + 120)
        let atPanelOrigin = CGRect(x: 0, y: 0, width: 10, height: 10)

        let placed = viewRectToCGRect(atPanelOrigin, panelOrigin: inset, screen: screen)
        let wholeScreen = viewRectToCGRect(atPanelOrigin, screen: screen)

        #expect(placed.minX == wholeScreen.minX + 200)
        #expect(placed.minY == wholeScreen.minY - 120)
    }
}
