import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panel = NotchPanelController()
    private lazy var hover = NotchHoverController(panel: panel)

    /// Called before any nib/window is loaded — the right place to set
    /// AppleLanguages so the entire SwiftUI hierarchy picks up the override.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let lang = UserDefaults.standard.string(forKey: AppSettings.Keys.preferredLanguage) ?? "system"
        switch lang {
        case "en": UserDefaults.standard.set(["en"],       forKey: "AppleLanguages")
        case "ru": UserDefaults.standard.set(["ru", "en"], forKey: "AppleLanguages")
        default:   UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.migrateLegacySaveDirectoryIfNeeded()
        hover.start()
        interceptSettingsMenuItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .requestOpenSettings,
            object: nil
        )
        if !UserDefaults.standard.bool(forKey: AppSettings.Keys.hasCompletedOnboarding) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                FirstLaunchWindowController.shared.show()
            }
        }
    }

    /// Intercepts the "Settings…" (⌘,) menu item that SwiftUI automatically
    /// adds via the Settings scene, and redirects it to SettingsWindowController
    /// — without invoking showSettingsWindow:.
    private func interceptSettingsMenuItem() {
        DispatchQueue.main.async {
            for topItem in NSApp.mainMenu?.items ?? [] {
                guard let submenu = topItem.submenu else { continue }
                for item in submenu.items {
                    if item.action == Selector(("showSettingsWindow:")) {
                        item.action = #selector(self.openSettings)
                        item.target = self
                    }
                }
            }
        }
    }

    @objc func openSettings() {
        SettingsWindowController.shared.open()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: restore cursor in case the app terminated during color sampling.
        CGDisplayShowCursor(CGMainDisplayID())
    }
    
}
