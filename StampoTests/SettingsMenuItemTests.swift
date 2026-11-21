import AppKit
import Testing
@testable import Stampo

/// ⌘, used to open an empty SwiftUI window instead of Stampo's settings.
/// The `Settings` scene puts its own "Settings…" into the app menu, and that
/// item opens the scene's window. The old fix looked for the item by the
/// selector `showSettingsWindow:`, which macOS 27 no longer uses (the item is
/// now a `menuAction:` of SwiftUI's private `MenuItemCallback`), so it never
/// matched and nothing complained.
///
/// This suite does not inspect the item — a descriptor cannot tell SwiftUI's
/// item from ours, both read `Settings…` / `,` / ⌘ / `menuAction:`. It fires the
/// key equivalent through the real main menu of the hosting app and looks at
/// which window comes up.
@MainActor @Suite(.serialized) struct SettingsMenuItemTests {

    /// The window id SwiftUI gives the `Settings` scene's own window.
    private static let sceneWindowID = "com_apple_SwiftUI_Settings_window"

    private func settingsItems() -> [NSMenuItem] {
        (NSApp.mainMenu?.items ?? [])
            .compactMap(\.submenu)
            .flatMap(\.items)
            .filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
    }

    /// SwiftUI fills the main menu a moment after launch. Polling, not RunLoop
    /// pumping — pumping a hosted test starves the work it is waiting for.
    private func waitForSettingsItem() async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !settingsItems().isEmpty { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !settingsItems().isEmpty
    }

    private func pressCommandComma() -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, characters: ",", charactersIgnoringModifiers: ",",
            isARepeat: false, keyCode: 43)
        guard let event, let menu = NSApp.mainMenu else { return false }
        return menu.performKeyEquivalent(with: event)
    }

    private func stampoSettingsWindows() -> [NSWindow] {
        let title = LocaleManager.shared.string("Settings")
        return NSApp.windows.filter { $0.title == title && $0.isVisible }
    }

    private func sceneWindowIsVisible() -> Bool {
        NSApp.windows.contains { $0.identifier?.rawValue == Self.sceneWindowID && $0.isVisible }
    }

    private func waitForStampoSettings() async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !stampoSettingsWindows().isEmpty { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !stampoSettingsWindows().isEmpty
    }

    @Test func commandCommaOpensStampoSettingsAndNotTheEmptySceneWindow() async {
        SettingsWindowController.shared.close()
        defer { SettingsWindowController.shared.close() }

        #expect(await waitForSettingsItem(), "the app menu should carry a ⌘, item")
        #expect(settingsItems().count == 1, "exactly one ⌘, item — a second one is SwiftUI's own")

        #expect(pressCommandComma(), "the main menu should take ⌘,")
        #expect(await waitForStampoSettings(), "⌘, should open Stampo's settings window")
        #expect(!sceneWindowIsVisible(), "⌘, must not open the empty SwiftUI Settings window")
    }

    /// Settings already on screen: ⌘, brings that window forward, it does not
    /// stack a second one beside it.
    @Test func commandCommaWithSettingsOpenKeepsASingleWindow() async {
        SettingsWindowController.shared.close()
        defer { SettingsWindowController.shared.close() }

        #expect(await waitForSettingsItem())
        #expect(pressCommandComma())
        #expect(await waitForStampoSettings())

        #expect(pressCommandComma())
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(stampoSettingsWindows().count == 1)
        #expect(!sceneWindowIsVisible())
    }
}
