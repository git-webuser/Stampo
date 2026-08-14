import AppKit
import CoreGraphics
import Quartz

final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var panel = NotchPanelController()
    private lazy var hover = NotchHoverController(panel: panel)

    /// True when the process is the TEST_HOST of a unit-test run. Startup
    /// side effects (event taps, hotkeys, panel, permission prompts) must be
    /// skipped so tests exercise pure logic without hijacking the machine.
    private static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    /// Called before any nib/window is loaded — the right place to set
    /// AppleLanguages so the entire SwiftUI hierarchy picks up the override.
    // MARK: - Quick Look

    /// QLPreviewPanel asks the responder chain who drives it, and NSApp's
    /// delegate is the last link that is always there — the notch panel is a
    /// non-activating window and never becomes the first responder. Everything
    /// is forwarded to QuickLookPresenter, which owns the item list.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            !QuickLookPresenter.shared.urls.isEmpty
        }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            QuickLookPresenter.shared.attach(to: panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            QuickLookPresenter.shared.detach(from: panel)
        }
    }

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
        guard !Self.isRunningTests else { return }
        AppSettings.migrateLegacySaveDirectoryIfNeeded()
        // "Restart to activate" is a statement about a stale process. This one
        // is brand new and its preflight is authoritative, so the pending flag
        // starts every launch clear.
        AppSettings.screenRecordingSetupRequested = false
        // The welcome flow belongs to first launch only. If Screen Recording is
        // later revoked, capture actions surface their focused permission alert
        // and General Settings links directly to the relevant macOS pane.
        let showWizard = AppSettings.onboardingPending
        // Mute standalone permission alerts up front — hover.start() installs
        // the event tap and could otherwise fire the cold-start alert before
        // the wizard appears.
        if showWizard { UserFacingError.suppressPermissionAlerts = true }
        hover.start()
        // Translation reads the language list and the installed packs
        // synchronously from three entry points that cannot wait on an async
        // check. Warming it here means the answer is already there by the time
        // any of them can be reached; the same refresh runs again whenever the
        // settings section is shown or the app is activated.
        Task { await TranslationLanguages.shared.refresh() }
        // And again whenever the app comes forward. The packs belong to macOS
        // and can be removed in System Settings without telling us, so a list
        // read once at launch goes stale in the one way that matters: the app
        // believes it can translate, tries, and is refused by the framework.
        // The settings pane already did this, but only while it was open.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await TranslationLanguages.shared.refresh() }
        }
        interceptSettingsMenuItem()
        UpdateChecker.shared.startAutomaticChecks()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsFromNotification(_:)),
            name: .requestOpenSettings,
            object: nil
        )
        if showWizard {
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

    /// Fires when the user activates an already-running instance — clicking the
    /// icon in Launchpad or the Dock. As an accessory app Stampo has no windows
    /// to restore, so AppKit would otherwise do nothing and the app feels dead.
    /// Reveal the panel so there's always visible feedback.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningTests else { return true }
        hover.revealPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: restore cursor in case the app terminated during color sampling.
        CGDisplayShowCursor(CGMainDisplayID())
    }
    
}
