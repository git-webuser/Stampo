import SwiftUI

@main
struct StampoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // An App needs at least one scene, and `Settings` is the one that opens
        // no window by itself — the real window is SettingsWindowController's.
        // Left alone, though, the scene also puts its own "Settings…" (⌘,) in
        // the app menu, and that item opens the scene's window: an empty one.
        // So the command group below replaces that item with ours. It is the
        // public way to own the item — the old fix went looking for the scene's
        // item by its action selector, and macOS 27 changed the selector.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.open()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
