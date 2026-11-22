import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// A panel button lit by where the pointer is, not by what SwiftUI heard.
///
/// Measured on the running app: the panel is a non-activating window of an
/// inactive app, and most of its mouse-moved events go to the global monitor
/// instead (359 heard there against 131 by the panel's own monitor in one
/// 30 s run). SwiftUI picks the button under the pointer on each event it
/// gets, so between two neighbouring buttons the old one stayed lit for
/// 0.5–1.8 s, until the next event the panel did get. The hub is fed by the
/// monitors the controller already has and asks each button's anchor whether
/// the pointer is over it.

// MARK: - The state

@Suite struct PanelHoverRouteStateTests {

    @Test func aButtonOnARouteThatTakesNoPointerIsNeverLit() {
        // Main, mounted under the archive with its hit-testing off, sits where
        // the archive's own buttons are. The pointer is "over" it all the same.
        var state = PanelHoverState()
        state.route(takesPointer: false)
        state.pointer(isOver: true)
        #expect(!state.isLit)
    }

    @Test func theBeliefIsKeptWhileTheRouteIsAwayAndLightsWhenItReturns() {
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.route(takesPointer: false)
        #expect(!state.isLit)
        state.route(takesPointer: true)
        #expect(state.isLit)
    }

    @Test func aMenuAndARouteHideTheButtonIndependently() {
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.route(takesPointer: false)
        state.menuBeganTracking()
        state.route(takesPointer: true)
        #expect(!state.isLit)
        state.menuEndedTracking()
        #expect(state.isLit)
    }
}

// MARK: - The hub, on bare anchors

@MainActor
@Suite(.serialized) struct PanelPointerHubTests {

    /// Two anchors side by side in one window, 20 pt apart, and everything the
    /// hub told them. The hub's own pointer is parked far away for the length
    /// of the test, so the real pointer decides nothing.
    private final class Rig {
        let window: NSWindow
        let a = PanelHoverAnchor()
        let b = PanelHoverAnchor()
        private(set) var aReports: [Bool] = []
        private(set) var bReports: [Bool] = []
        private let savedLocation = PanelPointerHub.shared.location

        init() {
            PanelPointerHub.shared.location = { NSPoint(x: -5000, y: -5000) }
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let frame = NSRect(x: screen.minX + screen.width * 0.3,
                               y: screen.minY + screen.height * 0.3, width: 200, height: 40)
            window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
            a.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
            b.frame = NSRect(x: 100, y: 0, width: 80, height: 40)
            content.addSubview(a)
            content.addSubview(b)
            a.onPointer = { [weak self] in self?.aReports.append($0) }
            b.onPointer = { [weak self] in self?.bReports.append($0) }
            window.contentView = content
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            aReports.removeAll()
            bReports.removeAll()
        }

        func finish() {
            window.orderOut(nil)
            PanelPointerHub.shared.location = savedLocation
        }

        var pointInA: NSPoint { NSPoint(x: window.frame.minX + 40, y: window.frame.midY) }
        var pointInB: NSPoint { NSPoint(x: window.frame.minX + 140, y: window.frame.midY) }
        var pointInGap: NSPoint { NSPoint(x: window.frame.minX + 90, y: window.frame.midY) }
        var pointAway: NSPoint { NSPoint(x: -5000, y: -5000) }
    }

    @Test func theAnchorUnderThePointerIsToldInsideAndTheOtherOutside() {
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        #expect(rig.aReports.last == true)
        #expect(rig.bReports.last == false)
    }

    @Test func movingToTheNextAnchorMovesTheReport() {
        // The measured defect: "…" to the archive button, no click, no event
        // for the panel. Position alone has to be enough.
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        PanelPointerHub.shared.pointerMoved(to: rig.pointInB, buttonsDown: false)
        #expect(rig.aReports.last == false)
        #expect(rig.bReports.last == true)
    }

    @Test func aPointerInTheGapIsOverNeitherAnchor() {
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        PanelPointerHub.shared.pointerMoved(to: rig.pointInGap, buttonsDown: false)
        #expect(rig.aReports.last == false)
        #expect(rig.bReports.last == false)
    }

    @Test func aPointerOffThePanelIsOverNoAnchor() {
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInB, buttonsDown: false)
        PanelPointerHub.shared.pointerMoved(to: rig.pointAway, buttonsDown: false)
        #expect(rig.bReports.last == false)
    }

    @Test func nothingIsToldWhileAMouseButtonIsDown() {
        // A press, or a cell being dragged out of the archive over the buttons:
        // neither lights what it passes over.
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        let before = (rig.aReports.count, rig.bReports.count)
        PanelPointerHub.shared.pointerMoved(to: rig.pointInB, buttonsDown: true)
        #expect(rig.aReports.count == before.0)
        #expect(rig.bReports.count == before.1)
    }

    @Test func theReportComesBackWhenTheButtonGoesUp() {
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        PanelPointerHub.shared.pointerMoved(to: rig.pointInB, buttonsDown: true)
        PanelPointerHub.shared.pointerMoved(to: rig.pointInB, buttonsDown: false)
        #expect(rig.aReports.last == false)
        #expect(rig.bReports.last == true)
    }

    @Test func thePointerGoingAwayToldEveryAnchorOutside() {
        // The panel hides with the pointer parked on a button.
        let rig = Rig(); defer { rig.finish() }
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        PanelPointerHub.shared.pointerGone()
        #expect(rig.aReports.last == false)
        #expect(rig.bReports.last == false)
    }

    @Test func anAnchorInAWindowThatIsNotOnScreenIsNeverUnderThePointer() {
        // A pick that hides the panel leaves its views mounted; no exit would
        // ever come for them.
        let rig = Rig(); defer { rig.finish() }
        rig.window.orderOut(nil)
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        #expect(rig.aReports.last != true)
    }

    @Test func anAnchorThatLeftItsWindowIsNotToldAnything() {
        let rig = Rig(); defer { rig.finish() }
        rig.a.removeFromSuperview()
        PanelPointerHub.shared.pointerMoved(to: rig.pointInA, buttonsDown: false)
        #expect(rig.aReports.isEmpty)
        #expect(rig.bReports.last == false)
    }

    @Test func anAnchorTakesNoClicks() {
        let rig = Rig(); defer { rig.finish() }
        #expect(rig.a.hitTest(NSPoint(x: 40, y: 20)) == nil)
        #expect(rig.window.contentView?.hitTest(NSPoint(x: 40, y: 20)) !== rig.a)
    }
}

// MARK: - A button, hosted

@MainActor
@Suite(.serialized) struct PanelHoverFollowsThePointerTests {

    private final class Flag {
        var isHovered = false
    }

    /// Two real panel buttons in a row, 20 pt apart, in a window of their own.
    private final class Rig {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        let a = Flag()
        let b = Flag()
        /// Which of the hub's pointers the buttons get when they ask.
        var asked = NSPoint(x: -5000, y: -5000)
        private let savedLocation = PanelPointerHub.shared.location

        init(scale: CGFloat = 1, takesPointer: Bool = true) {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let size = NSSize(width: 200, height: 40)
            let frame = NSRect(x: screen.minX + screen.width * 0.6,
                               y: screen.minY + screen.height * 0.6,
                               width: size.width, height: size.height)
            hosting = NSHostingView(rootView: AnyView(EmptyView()))
            // The panel's own kind of window.
            window = NSPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosting.frame = NSRect(origin: .zero, size: size)
            window.contentView = hosting
            PanelPointerHub.shared.location = { [unowned self] in asked }
            render(scale: scale, takesPointer: takesPointer)
            window.orderFrontRegardless()
            pump(0.35)
        }

        func render(scale: CGFloat = 1, takesPointer: Bool = true) {
            let flagA = a, flagB = b
            let bindA = Binding(get: { flagA.isHovered }, set: { flagA.isHovered = $0 })
            let bindB = Binding(get: { flagB.isHovered }, set: { flagB.isHovered = $0 })
            let row = HStack(spacing: 20) {
                Button { } label: { Color.clear.frame(width: 80, height: 40) }
                    .buttonStyle(.plain)
                    .panelHover(bindA)
                Color.clear.frame(width: 80, height: 40)
                    .panelHover(bindB)
            }
            .frame(width: 200 / scale, height: 40 / scale, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 200, height: 40, alignment: .topLeading)
            .panelHitTesting(takesPointer)
            hosting.rootView = AnyView(row)
        }

        func finish() {
            window.orderOut(nil)
            PanelPointerHub.shared.location = savedLocation
        }

        func move(to point: NSPoint, buttonsDown: Bool = false) {
            asked = point
            PanelPointerHub.shared.pointerMoved(to: point, buttonsDown: buttonsDown)
            pump(0.05)
        }

        func pump(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        /// Points are the way the panel's own coordinates are laid out: x from
        /// the window's left edge, in the middle of its height.
        func point(x: CGFloat) -> NSPoint { NSPoint(x: window.frame.minX + x, y: window.frame.midY) }
    }

    @Test func aButtonLightsFromThePointerAloneAndGoesOutWithIt() {
        let rig = Rig(); defer { rig.finish() }
        rig.move(to: rig.point(x: 40))
        #expect(rig.a.isHovered)
        #expect(!rig.b.isHovered)
        rig.move(to: rig.point(x: 140))
        #expect(!rig.a.isHovered)
        #expect(rig.b.isHovered)
        rig.move(to: NSPoint(x: -5000, y: -5000))
        #expect(!rig.a.isHovered)
        #expect(!rig.b.isHovered)
    }

    @Test func aButtonOnARouteThatTakesNoPointerStaysUnlitUnderIt() {
        let rig = Rig(takesPointer: false); defer { rig.finish() }
        rig.move(to: rig.point(x: 40))
        #expect(!rig.a.isHovered)
    }

    @Test func aRouteComingBackUnderAParkedPointerLightsItsButton() {
        // No move comes with the route: the buttons ask where the pointer is.
        let rig = Rig(takesPointer: false); defer { rig.finish() }
        rig.move(to: rig.point(x: 40))
        rig.render(takesPointer: true)
        rig.pump(0.15)
        #expect(rig.a.isHovered)
    }

    @Test func aRouteLeavingUnlightsItsButton() {
        let rig = Rig(); defer { rig.finish() }
        rig.move(to: rig.point(x: 40))
        #expect(rig.a.isHovered)
        rig.render(takesPointer: false)
        rig.pump(0.15)
        #expect(!rig.a.isHovered)
    }

    @Test func aMenuHidesTheLitButtonAndItsClosingReturnsIt() {
        let rig = Rig(); defer { rig.finish() }
        rig.move(to: rig.point(x: 40))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        rig.pump(0.1)
        #expect(!rig.a.isHovered)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        rig.pump(0.1)
        #expect(rig.a.isHovered)
    }

    @Test func aMenuClosingOverAButtonNobodyToldAboutLightsItAtOnce() {
        // The pointer ended over B while the menu was up, and neither SwiftUI
        // nor a monitor said so. The close asks.
        let rig = Rig(); defer { rig.finish() }
        rig.move(to: rig.point(x: 40))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        rig.pump(0.1)
        rig.asked = rig.point(x: 140)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        rig.pump(0.1)
        #expect(rig.b.isHovered)
        #expect(!rig.a.isHovered)
    }

    @Test func aButtonUnderAScaledPanelIsFoundWhereItIsDrawn() {
        // A notch-less screen draws the panel at its design size and scales it
        // to fit the menu bar. At half size the buttons sit in x 0–40 and
        // 50–90; unscaled they would be 0–80 and 100–180.
        let rig = Rig(scale: 0.5); defer { rig.finish() }
        rig.move(to: rig.point(x: 25))
        #expect(rig.a.isHovered)
        #expect(!rig.b.isHovered)
        rig.move(to: rig.point(x: 70))
        #expect(!rig.a.isHovered)
        #expect(rig.b.isHovered)
        rig.move(to: rig.point(x: 120))
        #expect(!rig.a.isHovered)
        #expect(!rig.b.isHovered)
    }

    @Test func anAnchorIsNeverTheViewAClickLandsOn() {
        // The anchor sits behind a real button. It must not become the view
        // AppKit hands the click to. (A synthetic click does not reach a
        // SwiftUI button in a test window, with or without an anchor, so the
        // hit view is what can be checked here; the click itself is checked
        // on the running panel.)
        let rig = Rig(); defer { rig.finish() }
        for x in [CGFloat(40), 140] {
            let hit = rig.hosting.hitTest(NSPoint(x: x, y: 20))
            #expect(!(hit is PanelHoverAnchor))
        }
    }
}
