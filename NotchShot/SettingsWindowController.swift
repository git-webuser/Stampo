import AppKit
import SwiftUI

// MARK: - Notification

extension Notification.Name {
    static let settingsWindowDidClose = Notification.Name("NotchShotSettingsWindowDidClose")
}

// MARK: - FixedTitleTabViewController

/// NSTabViewController that keeps the window title fixed to "Settings"
/// regardless of the selected tab's view controller title.
private final class FixedTitleTabViewController: NSTabViewController {
    /// NSWindow observes contentViewController.title via KVO and mirrors it
    /// to window.title on every tab switch. Locking the getter to "Settings"
    /// keeps the window title stable regardless of which tab is active.
    override var title: String? {
        get { "Settings" }
        set { /* intentionally ignored */ }
    }
}

// MARK: - SettingsWindowController

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private override init() {}

    func open() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let tabController = makeTabViewController()

        let win = NSWindow(contentViewController: tabController)
        win.title       = "Settings"
        win.level       = .floating
        win.styleMask   = [.titled, .closable, .miniaturizable]
        win.setFrameAutosaveName("NotchShotSettingsWindow")
        win.appearance  = AppSettings.settingsAppearance.nsAppearance
        win.center()
        win.delegate    = self
        self.window     = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applyAppearance(_ appearance: SettingsAppearance) {
        window?.appearance = appearance.nsAppearance
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NotificationCenter.default.post(name: .settingsWindowDidClose, object: nil)
    }

    // MARK: - Tab view controller

    private func makeTabViewController() -> NSTabViewController {
        let tabs = FixedTitleTabViewController()
        tabs.tabStyle = .toolbar

        let items: [(label: String, image: String, view: AnyView)] = [
            ("General", "gearshape",  AnyView(GeneralSettingsView())),
            ("Capture", "camera",     AnyView(CaptureSettingsView())),
            ("Tray",    "tray",       AnyView(TraySettingsView())),
            ("Hotkeys", "keyboard",   AnyView(HotkeySettingsView())),
            ("About",   "info.circle",AnyView(AboutSettingsView()))
        ]

        for item in items {
            let hosting = NSHostingController(rootView: item.view)
            // Give each tab a comfortable minimum size
            hosting.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

            let tabItem = NSTabViewItem(viewController: hosting)
            tabItem.label = item.label
            tabItem.image = NSImage(systemSymbolName: item.image, accessibilityDescription: item.label)
            tabs.addTabViewItem(tabItem)
        }

        return tabs
    }
}
