import AppKit
import Testing
@testable import Stampo

/// The setup window is opened from a row inside Settings, and the settings
/// window is `.floating`. A normal-level window therefore opens *behind* it and
/// the row reads as a button that does nothing — which is exactly how this
/// shipped for one build.
@MainActor
@Suite struct TranslationSetupWindowTests {

    private var setupWindow: NSWindow? {
        NSApp.windows.first { $0.title == LocaleManager.shared.string("Set up translation") }
    }

    @Test func theWindowOpensAboveTheSettingsWindow() {
        let controller = TranslationSetupWindowController.shared
        controller.show()
        defer { controller.close() }

        #expect(controller.isWindowOpen)
        let window = setupWindow
        #expect(window != nil, "show() must produce a window")
        #expect(window?.isVisible == true)
        // The settings window sits at `.floating`; anything lower disappears
        // behind it.
        #expect((window?.level.rawValue ?? 0) >= NSWindow.Level.floating.rawValue)
    }

    @Test func showingItTwiceRaisesTheSameWindow() {
        let controller = TranslationSetupWindowController.shared
        controller.show()
        controller.show()
        defer { controller.close() }

        let matching = NSApp.windows.filter {
            $0.title == LocaleManager.shared.string("Set up translation")
        }
        #expect(matching.count == 1, "a second trigger must not stack another window")
    }
}
