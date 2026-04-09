import SwiftUI

@main
struct NotchShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // EmptyView — окном управляет SettingsWindowController,
        // чтобы не вызывать showSettingsWindow: и не получать предупреждение.
        // Сцена нужна только чтобы SwiftUI зарегистрировал ⌘, в app menu;
        // сам пункт меню перехватывается в AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
