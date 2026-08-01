import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// What VoiceOver reads off the panel.
///
/// The panel's three menus are `NSPopUpButton`s wrapped in SwiftUI, and the
/// element VoiceOver focuses is the AppKit button — not the SwiftUI container
/// around it — so `.accessibilityLabel` on the wrapper view goes nowhere and
/// the label has to be set on the button itself. That is invisible from the
/// outside: the app looks and behaves identically either way, and the mistake
/// only surfaces to someone actually running VoiceOver.
///
/// So these tests host the real panel, let it lay out, and ask the buttons
/// what they would say. Nothing here needs the Accessibility permission — an
/// app reading its own `NSAccessibility` attributes is just a method call.
///
/// Expectations go through `LocaleManager`, never English literals: the labels
/// follow the in-app language picker, so a test run under a Russian app
/// language reads Russian labels off a perfectly correct panel.
@MainActor
@Suite struct PanelAccessibilityTests {

    private var modeLabel: String { LocaleManager.shared.string("Capture mode") }
    private var delayLabel: String { LocaleManager.shared.string("Capture delay") }
    private var moreLabel: String { LocaleManager.shared.string("Settings and quit") }

    /// Lays the panel out in an off-screen hosting view and returns every
    /// `NSPopUpButton` it built, keyed by accessibility label.
    /// `NSViewRepresentable.makeNSView` runs during layout, so the tree has to
    /// be pumped before the buttons exist.
    private func panelMenus(mode: CaptureMode = .window,
                            delay: CaptureDelay = .s5) -> [String: NSPopUpButton] {
        let model = NotchPanelModel()
        model.mode = mode
        model.delay = delay

        let view = NotchPanelView(
            metrics: .fallback(),
            interaction: NotchPanelInteractionState(),
            model: model,
            isArchiveOpen: false,
            onClose: {}, onCapture: { _, _ in }, onToggleArchive: {},
            onPickColor: {}, onScan: {}, onModeDelayChanged: {}
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 1200, height: 64)
        hosting.layoutSubtreeIfNeeded()
        // RunLoop, not Task.sleep: this waits on AppKit/SwiftUI layout, which
        // needs the main run loop to turn rather than the main actor to yield.
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        return Dictionary(
            popUpButtons(in: hosting).map { ($0.accessibilityLabel() ?? "", $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popUpButtons)
    }

    /// Every menu announces itself, in the app's language. An unlabelled
    /// `NSPopUpButton` reads as "pop up button" and nothing else, which is
    /// exactly what the SwiftUI-side labels used to produce.
    @Test func everyPanelMenuHasALabel() {
        let menus = panelMenus()
        #expect(menus.count == 3)
        #expect(Set(menus.keys) == [modeLabel, delayLabel, moreLabel])
        #expect(!menus.keys.contains(""))
    }

    /// The mode and delay menus carry their selection as the accessibility
    /// *value*, so VoiceOver says "Capture mode, Window" instead of making the
    /// user open the menu to find out what is selected. These buttons are
    /// transparent and borderless with no title of their own, so nothing else
    /// would tell them.
    @Test func menusAnnounceTheirSelection() {
        let menus = panelMenus(mode: .screen, delay: .s10)
        #expect(menus[modeLabel]?.accessibilityValue() as? String
                == CaptureMode.screen.localizedTitle())
        #expect(menus[delayLabel]?.accessibilityValue() as? String
                == CaptureDelay.s10.localizedTitle())
    }

    /// Changing the selection moves the announced value with it — the label is
    /// set once, but the value is refreshed on every update.
    @Test(arguments: CaptureMode.allCases)
    func everyModeIsAnnouncedAsItsOwnValue(mode: CaptureMode) {
        #expect(panelMenus(mode: mode)[modeLabel]?.accessibilityValue() as? String
                == mode.localizedTitle())
    }

    /// The more menu never has a selection (`selectItem(at: -1)`), so it gets
    /// a label and no value — announcing one would name a menu item the user
    /// never chose.
    @Test func theMoreMenuHasNoSelectionToAnnounce() {
        let more = panelMenus()[moreLabel]
        #expect(more != nil)
        #expect(more?.indexOfSelectedItem == -1)
        #expect((more?.accessibilityValue() as? String).map(\.isEmpty) ?? true)
    }

    /// Both menus drop *down*. A pop-up button positions its menu so the
    /// selected item lands over the button, which for a panel at the top edge
    /// of the screen starts above the screen — macOS then scrolls the menu and
    /// hides the items that don't fit. A pull-down always opens below, so
    /// every item stays reachable whatever is selected. The empty item 0 is
    /// the button's own title slot, which is why the real items are offset by
    /// one everywhere they are touched.
    @Test func modeAndDelayMenusArePullDownsWithAPlaceholderFirst() {
        let menus = panelMenus()
        for label in [modeLabel, delayLabel] {
            let button = menus[label]
            #expect(button?.pullsDown == true)
            #expect(button?.item(at: 0)?.title == "")
        }
    }

    /// The checkmark is placed by hand — a pull-down doesn't mark a current
    /// item on its own — so it has to land on the selected mode and nowhere
    /// else. An off-by-one against the placeholder would tick the wrong row.
    @Test func theSelectedModeIsTheOnlyTickedItem() {
        let modeMenu = panelMenus(mode: .selection)[modeLabel]
        let ticked = CaptureMode.allCases.enumerated().filter { index, _ in
            modeMenu?.item(at: index + 1)?.state == .on
        }
        #expect(ticked.map(\.element) == [.selection])
    }

    /// Same, for the delay menu — it carries the longer list and so the worse
    /// clipping case that moved both menus to pull-down.
    @Test func theSelectedDelayIsTheOnlyTickedItem() {
        let delayMenu = panelMenus(delay: .s3)[delayLabel]
        let ticked = CaptureDelay.allCases.enumerated().filter { index, _ in
            delayMenu?.item(at: index + 1)?.state == .on
        }
        #expect(ticked.map(\.element) == [.s3])
    }
}
