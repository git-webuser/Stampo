import AppKit
import Testing
@testable import Stampo

/// A left click reaches `NotchHoverController` through an `NSEvent` monitor and
/// is handled after a hop to the main actor. These tests pin that the answer
/// comes from the point the event carries, whatever the real pointer does
/// meanwhile.
///
/// The pointer-sensitive tests build their geometry around the real
/// `NSEvent.mouseLocation`: the panel is placed far from it ("the pointer has
/// left") or under it ("the pointer has entered"), so code that reads the
/// pointer instead of the event gets the other answer on every machine.
@Suite struct NotchClickTests {

    /// Notch-sized trigger zone and a panel hanging from it, all positioned
    /// relative to `origin` so a test can put them anywhere.
    private struct Layout {
        let origin: CGPoint

        private func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + dx, y: origin.y + dy)
        }

        var trigger: CGRect { CGRect(x: origin.x + 300, y: origin.y + 950, width: 224, height: 32) }
        /// The panel is wider than the trigger and shares its top edge, as the
        /// real panel does, so the zone sits over the panel's own buttons.
        var drawnPanel: CGRect { CGRect(x: origin.x + 250, y: origin.y + 700, width: 324, height: 282) }

        var insidePanel: CGPoint { at(400, 800) }
        var outsidePanel: CGPoint { at(100, 800) }
        var onNotchOverPanel: CGPoint { at(400, 965) }

        func screen(notch: Bool = true) -> NotchClick.ScreenSnapshot {
            .init(triggerRect: trigger, hasPhysicalNotch: notch)
        }

        func panel(visible: Bool = true, stale: Bool = false, suppressed: Bool = false,
                   drawn: CGRect? = nil) -> NotchClick.PanelSnapshot {
            .init(isVisible: visible, needsSpaceRebind: stale, suppressesAutoHide: suppressed,
                  drawnRect: drawn ?? drawnPanel)
        }
    }

    private let layout = Layout(origin: CGPoint(x: 1_000, y: 1_000))

    private func click(at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// What the controller does for one click: the point from the event, then
    /// the decision. Nothing here reads the pointer.
    private func action(for event: NSEvent, in layout: Layout,
                        notch: Bool = true, panel: NotchClick.PanelSnapshot) -> NotchClick.Action {
        NotchClick.decide(at: NotchClick.screenPoint(of: event),
                          screen: layout.screen(notch: notch), panel: panel)
    }

    // MARK: Table 2, row 1 — click inside, pointer stays

    @Test func clickInsideTheOpenPanelChangesNothing() {
        #expect(NotchClick.decide(at: layout.insidePanel, screen: layout.screen(),
                                  panel: layout.panel()) == .ignore)
    }

    @Test func clickOutsideTheOpenPanelClosesIt() {
        #expect(NotchClick.decide(at: layout.outsidePanel, screen: layout.screen(),
                                  panel: layout.panel()) == .hideOnOutsideClick)
    }

    // MARK: Row 2 — click inside, pointer left before the handler ran

    @Test func clickInsideStaysInsideWhenThePointerHasLeft() throws {
        // The panel is 20 000 pt away from the real pointer: by the time the
        // handler runs, the pointer is nowhere near it.
        let pointer = NSEvent.mouseLocation
        let far = Layout(origin: CGPoint(x: pointer.x + 20_000, y: pointer.y))
        let event = try click(at: far.insidePanel)

        #expect(action(for: event, in: far, panel: far.panel()) == .ignore)
    }

    // MARK: Row 3 — click outside, pointer entered the panel before the handler ran

    @Test func clickOutsideStaysOutsideWhenThePointerHasEntered() throws {
        // The real pointer sits inside this panel; the click was outside it.
        let pointer = NSEvent.mouseLocation
        let under = Layout(origin: CGPoint(x: pointer.x - 400, y: pointer.y - 800))
        #expect(under.drawnPanel.contains(pointer))
        let event = try click(at: under.outsidePanel)

        #expect(action(for: event, in: under, panel: under.panel()) == .hideOnOutsideClick)
    }

    // MARK: Rows 4 and 5 — the notch, answered from the event

    @Test func notchClickWithAnOpenPanelClosesIt() {
        #expect(NotchClick.decide(at: layout.onNotchOverPanel, screen: layout.screen(notch: true),
                                  panel: layout.panel()) == .hideOnNotchClick)
    }

    @Test func notchClickClosesWhenThePointerHasLeft() throws {
        let pointer = NSEvent.mouseLocation
        let far = Layout(origin: CGPoint(x: pointer.x + 20_000, y: pointer.y))
        let event = try click(at: far.onNotchOverPanel)

        #expect(action(for: event, in: far, panel: far.panel()) == .hideOnNotchClick)
    }

    @Test func withoutAPhysicalNotchTheTriggerZoneOverThePanelDoesNotClose() {
        // The zone covers the panel's buttons there. Pressing one must not hide
        // the panel.
        #expect(NotchClick.decide(at: layout.onNotchOverPanel, screen: layout.screen(notch: false),
                                  panel: layout.panel()) == .ignore)
    }

    @Test func withoutAPhysicalNotchOnlyAClickOutsideThePanelCloses() {
        // The panel is drawn off to the side, so the trigger zone is outside it.
        let aside = layout.panel(drawn: CGRect(x: layout.origin.x + 100, y: layout.origin.y + 700,
                                               width: 100, height: 282))
        #expect(NotchClick.decide(at: layout.onNotchOverPanel, screen: layout.screen(notch: false),
                                  panel: aside) == .hideOnOutsideClick)
    }

    @Test func notchClickWithAClosedPanelOpensIt() {
        #expect(NotchClick.decide(at: layout.onNotchOverPanel, screen: layout.screen(),
                                  panel: layout.panel(visible: false)) == .show)
    }

    @Test func notchClickOpensWhenThePointerHasLeft() throws {
        let pointer = NSEvent.mouseLocation
        let far = Layout(origin: CGPoint(x: pointer.x + 20_000, y: pointer.y))
        let event = try click(at: far.onNotchOverPanel)

        #expect(action(for: event, in: far, panel: far.panel(visible: false)) == .show)
    }

    @Test func clickAwayFromTheNotchWithAClosedPanelDoesNothing() {
        #expect(NotchClick.decide(at: layout.outsidePanel, screen: layout.screen(),
                                  panel: layout.panel(visible: false)) == .ignore)
    }

    @Test func aStalePanelCountsAsClosed() {
        // After sleep or a Space switch the panel may still report visible. A
        // click on the notch brings it back; any other click leaves it alone.
        let stale = layout.panel(visible: true, stale: true)
        #expect(NotchClick.decide(at: layout.onNotchOverPanel, screen: layout.screen(),
                                  panel: stale) == .show)
        #expect(NotchClick.decide(at: layout.outsidePanel, screen: layout.screen(),
                                  panel: stale) == .ignore)
    }

    @Test func aScreenWithNoTriggerZoneIgnoresEveryClick() {
        // The menu bar is hidden, so the screen has no trigger zone.
        let screen = NotchClick.ScreenSnapshot(triggerRect: .null, hasPhysicalNotch: false)
        for point in [layout.insidePanel, layout.outsidePanel, layout.onNotchOverPanel] {
            #expect(NotchClick.decide(at: point, screen: screen, panel: layout.panel()) == .ignore)
        }
    }

    // MARK: Row 6 — pinned, picking an area, picking a colour

    @Test func clicksWhileAutoHideIsSuppressedAreIgnored() {
        let suppressed = layout.panel(suppressed: true)
        for point in [layout.insidePanel, layout.outsidePanel, layout.onNotchOverPanel] {
            #expect(NotchClick.decide(at: point, screen: layout.screen(), panel: suppressed) == .ignore)
        }
    }

    // MARK: Event point — the seam the monitors use

    @Test func eventWithoutAWindowCarriesItsScreenPoint() throws {
        // A global monitor's event has no window; its location is already in
        // screen coordinates. Far outside every screen, so the real pointer can
        // never be the answer.
        let point = CGPoint(x: -50_000, y: -50_000)
        let event = try click(at: point)
        #expect(event.window == nil)

        #expect(NotchClick.screenPoint(of: event) == point)
    }

    @Test func locationInAWindowConvertsToScreenCoordinates() {
        // A local monitor's event carries window coordinates.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let converted = NotchClick.screenPoint(locationInWindow: CGPoint(x: 10, y: 20), in: window)

        #expect(converted == window.frame.origin.applying(.init(translationX: 10, y: 20)))
    }

    @Test func locationWithNoWindowStaysAsIs() {
        #expect(NotchClick.screenPoint(locationInWindow: CGPoint(x: 7, y: 9), in: nil)
                == CGPoint(x: 7, y: 9))
    }

    // MARK: Row 8 — the screen comes from the click

    @Test func screenIsChosenByTheClickPoint() {
        let frames = [CGRect(x: 0, y: 0, width: 1_512, height: 982),
                      CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080)]

        #expect(NotchClick.screenIndex(containing: CGPoint(x: 100, y: 500), in: frames) == 0)
        #expect(NotchClick.screenIndex(containing: CGPoint(x: 2_000, y: 500), in: frames) == 1)
    }

    @Test func aPointOnNoScreenHasNoIndex() {
        let frames = [CGRect(x: 0, y: 0, width: 1_512, height: 982)]

        #expect(NotchClick.screenIndex(containing: CGPoint(x: 5_000, y: 500), in: frames) == nil)
    }
}
