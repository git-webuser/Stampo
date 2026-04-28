import SwiftUI

@main
struct StampoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // EmptyView — the window is managed by SettingsWindowController so we
        // never call showSettingsWindow: and avoid the SwiftUI warning.
        // The scene exists solely so SwiftUI registers ⌘, in the app menu;
        // the menu item itself is intercepted and redirected in AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
