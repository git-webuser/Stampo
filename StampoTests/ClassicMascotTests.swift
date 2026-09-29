import AppKit
import Testing
@testable import Stampo

/// 0.9.0's mascot answering the two things only the hare was told about.
@MainActor @Suite struct ClassicMascotTests {

    private func mascot() -> ClassicMascotView {
        ClassicMascotView(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
    }

    /// The body, then the two eyes: the order `setup` adds them in.
    private func eyes(_ view: ClassicMascotView) -> [CAShapeLayer] {
        (view.layer?.sublayers ?? []).dropFirst().compactMap { $0 as? CAShapeLayer }
    }

    private func eyesOpen(_ view: ClassicMascotView) -> Bool {
        let eyes = eyes(view)
        return eyes.count == 2 && eyes.allSatisfy { ($0.fillColor?.alpha ?? 0) > 0 }
    }

    /// 0.9.0 was never told about the wait, so a sleeping mascot sleeps on.
    @Test func theWaitIsNotItsNews() {
        let view = mascot()
        view.setState(.sleeping)
        view.setState(.waiting)
        #expect(eyes(view).count == 2)
        #expect(!eyesOpen(view), "the wait woke the mascot")
    }

    /// The picker's cursor is a state of its own here, and opens the eyes.
    @Test func theCursorOpensItsEyes() {
        let view = mascot()
        view.setState(.sleeping)
        view.look(towardX: 0.9, y: 0.9)
        #expect(eyesOpen(view), "a cursor report left the mascot asleep")
    }
}

/// Which mascot the status item gets. The hare ships with the icon drawn
/// after it; a revert of the default would put 0.9.0's mascot beside that
/// icon with every mascot test still green, since each one builds its view
/// directly.
@MainActor @Suite struct MenuBarMascotChoiceTests {

    private let frame = NSRect(x: 0, y: 0, width: 22, height: 18)

    @Test func theHareIsTheDefault() {
        #expect(AppSettings.menuBarHare(stored: nil))
    }

    /// Whoever wrote the key themselves keeps what they wrote.
    @Test func aStoredChoiceStands() {
        #expect(!AppSettings.menuBarHare(stored: false))
        #expect(AppSettings.menuBarHare(stored: true))
    }

    @Test func theFlagPicksTheMascot() {
        #expect(NotchHoverController.menuBarMascot(hare: true, frame: frame) is MascotStatusView)
        #expect(NotchHoverController.menuBarMascot(hare: false, frame: frame) is ClassicMascotView)
    }
}
