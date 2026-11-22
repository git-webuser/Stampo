import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// What a panel button shows of the pointer, around a menu and around a click.
///
/// Each sequence below was measured on the running app: SwiftUI loses the
/// enter and exit reports for a move that ends in a click, and hears nothing at
/// all while a menu tracks. Every panel button takes its hover through
/// `panelHover`, so the rules are pinned once, here.
@Suite struct PanelHoverStateTests {

    // MARK: A menu opens and closes

    @Test func aMenuHidesALitButtonForAsLongAsItIsOpen() {
        // The sticky highlight: the pointer left this button for the one that
        // opened the menu, and the exit has not come.
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.menuBeganTracking()
        #expect(!state.isLit)
    }

    @Test func whatSwiftUIBelievedComesBackWhenTheMenuCloses() {
        // The pointer came back onto the button while the menu was open — the
        // exit never came, so no enter will — and the menu closed over it. It
        // is lit, as it was (6 of 25 menus, archive and delay, unlit before).
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.menuBeganTracking()
        state.menuEndedTracking()
        #expect(state.isLit)
    }

    @Test func theLateExitAfterTheMenuUnlightsIt() {
        // The pointer ended elsewhere: the exit that was held back arrives a
        // few milliseconds after the close and finishes the job.
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.menuBeganTracking()
        state.menuEndedTracking()
        state.pointer(isOver: false)
        #expect(!state.isLit)
    }

    @Test func aReportDuringAMenuLightsNothingUntilItCloses() {
        var state = PanelHoverState()
        state.menuBeganTracking()
        state.pointer(isOver: true)
        #expect(!state.isLit)
        state.menuEndedTracking()
        #expect(state.isLit)
    }

    @Test func aMenuEndingWithoutABeginChangesNothing() {
        // Another menu's end, heard by a button that never saw it begin.
        var state = PanelHoverState()
        state.menuEndedTracking()
        #expect(!state.isLit)
        state.pointer(isOver: true)
        state.menuEndedTracking()
        #expect(state.isLit)
    }

    // MARK: A click on another button

    @Test func aPressOnAnotherButtonUnlightsThisOne() {
        // "…" to the archive button and a click: the exit from "…" came
        // 0.7–1.7 s later, at the next movement of the mouse.
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.anotherButtonWasPressed()
        #expect(!state.isLit)
    }

    @Test func theExitThatComesLateFindsNothingToTurnOff() {
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.anotherButtonWasPressed()
        state.pointer(isOver: false)
        #expect(!state.isLit)
    }

    @Test func aButtonLightsAgainWhenThePointerEntersItAfterAPressElsewhere() {
        var state = PanelHoverState()
        state.pointer(isOver: true)
        state.anotherButtonWasPressed()
        state.pointer(isOver: false)
        state.pointer(isOver: true)
        #expect(state.isLit)
    }
}

/// The modifier around that state: what it listens to, and what it says.
@MainActor
@Suite struct PanelHoverModifierTests {

    // MARK: Harness

    /// A flag the view writes and the test reads, standing in for a button's
    /// `@State isHovered`.
    private final class Flag {
        var isHovered: Bool
        init(_ isHovered: Bool) { self.isHovered = isHovered }
    }

    private func button(_ flag: Flag, pressed: Bool = false) -> some View {
        let binding = Binding(get: { flag.isHovered }, set: { flag.isHovered = $0 })
        return Color.clear.frame(width: 40, height: 40).panelHover(binding, pressed: pressed)
    }

    /// Hosts a button for the length of the body.
    private func withHostedButton(lit: Bool, _ body: (Flag, NSHostingView<AnyView>) -> Void) {
        let flag = Flag(lit)
        let hosting = NSHostingView(rootView: AnyView(button(flag)))
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // The view subscribes when it appears, which is after a display cycle.
        pump(0.35)
        body(flag, hosting)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private let pressed = Notification.Name("StampoPanelButtonPressed")

    // MARK: Tests

    @Test func aMenuBeginningToTrackClearsALitButton() {
        withHostedButton(lit: true) { flag, _ in
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
            pump(0.1)
            #expect(!flag.isHovered)
        }
    }

    @Test func aMenuEndingTrackingDoesNotLightAButtonNothingBelievesIn() {
        // Where the pointer is when a menu closes is `afterClose`'s to say, and
        // the late reports'. The modifier guesses nothing.
        withHostedButton(lit: false) { flag, _ in
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
            pump(0.1)
            #expect(!flag.isHovered)
        }
    }

    @Test func aPressOnAnotherButtonClearsALitButton() {
        withHostedButton(lit: true) { flag, _ in
            NotificationCenter.default.post(name: pressed, object: UUID())
            pump(0.1)
            #expect(!flag.isHovered)
        }
    }

    /// Hosts a button that is not pressed, then re-renders it with `nowPressed`,
    /// and counts the press announcements heard on the way.
    private func announcements(nowPressed: Bool) -> Int {
        final class Count: @unchecked Sendable { var value = 0 }
        let flag = Flag(false)
        let hosting = NSHostingView(rootView: AnyView(button(flag, pressed: false)))
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        pump(0.35)

        let count = Count()
        let token = NotificationCenter.default.addObserver(forName: pressed, object: nil, queue: .main) { _ in
            count.value += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        hosting.rootView = AnyView(button(flag, pressed: nowPressed))
        pump(0.2)
        return count.value
    }

    @Test func aButtonThatIsPressedAnnouncesIt() {
        // Heard by the others: this is what makes a press elsewhere clear them.
        #expect(announcements(nowPressed: true) == 1)
    }

    @Test func aButtonThatDoesNotMarkItsPressAnnouncesNothing() {
        // The buttons that open a menu: the menu already hides the others, and
        // a pointer that comes back onto one during it is still over it.
        #expect(announcements(nowPressed: false) == 0)
    }
}
