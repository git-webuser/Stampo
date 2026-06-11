import AppKit
import CoreGraphics

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
            selector: #selector(openSettingsFromNotification(_:)),
            name: .requestOpenSettings,
            object: nil
        )
        if !UserDefaults.standard.bool(forKey: AppSettings.Keys.hasCompletedOnboarding) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                FirstLaunchWindowController.shared.show()
            }
        } else if !CGPreflightScreenCaptureAccess() {
            // Onboarding was already completed but Screen Recording is not
            // granted (e.g. TCC was reset). Trigger a request so Stampo
            // is registered in System Settings → Screen Recording.
            DispatchQueue.main.async {
                _ = CGRequestScreenCaptureAccess()
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

    /// Observer for .requestOpenSettings — the notification may carry a target
    /// tab index for deep-linking (e.g. "save folder inaccessible" → Capture).
    @objc func openSettingsFromNotification(_ note: Notification) {
        if let raw = note.userInfo?[SettingsWindowController.tabUserInfoKey] as? Int,
           let tab = SettingsTab(rawValue: raw) {
            SettingsWindowController.shared.open(tab: tab)
        } else {
            SettingsWindowController.shared.open()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: restore cursor in case the app terminated during color sampling.
        CGDisplayShowCursor(CGMainDisplayID())
    }
    
}
