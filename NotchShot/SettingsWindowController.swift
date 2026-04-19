import AppKit
import SwiftUI

// MARK: - Notification

extension Notification.Name {
    static let settingsWindowDidClose = Notification.Name("NotchShotSettingsWindowDidClose")
}

// MARK: - FixedTitleTabViewController

/// NSTabViewController that owns its toolbar completely:
/// • tabStyle = .unspecified (set in init) — NSTabViewController never touches the toolbar.
/// • noTabsNoBorder — native NSTabView tab strip is hidden.
/// • One NSToolbarItem per tab, rendered by the system (icon above label, selection highlight).
/// • toolbarSelectableItemIdentifiers — AppKit draws the standard selection highlight.
private final class FixedTitleTabViewController: NSTabViewController {

    private var tabIdentifiers: [NSToolbarItem.Identifier] = []

    // MARK: Init

    /// Must be set before viewDidLoad runs; setting tabStyle inside viewDidLoad
    /// causes NSTabViewController to call loadView again → infinite recursion.
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .unspecified
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: Title

    override var title: String? {
        get { LocaleManager.shared.string("Settings") }
        set { /* intentionally ignored */ }
    }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        tabView.tabViewType = .noTabsNoBorder
    }

    // MARK: Toolbar installation

    /// Call after NSWindow(contentViewController:) so tabViewItems are populated.
    func installToolbar(in window: NSWindow) {
        tabIdentifiers = tabViewItems.indices.map {
            NSToolbarItem.Identifier("notchShot.tab.\($0)")
        }

        let toolbar = NSToolbar(identifier: "notchShot.settings.toolbar")
        toolbar.delegate               = self
        toolbar.allowsUserCustomization = false
        if !tabIdentifiers.isEmpty {
            toolbar.selectedItemIdentifier = tabIdentifiers[selectedTabViewItemIndex]
        }
        window.toolbar      = toolbar
        window.toolbarStyle = .preference
    }

    // MARK: NSToolbarDelegate overrides

    override func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers
    }

    override func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers   // .preference style centres them automatically
    }

    override func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        tabIdentifiers   // enables the system selection highlight
    }

    override func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let idx = tabIdentifiers.firstIndex(of: itemIdentifier),
              idx < tabViewItems.count
        else {
            return super.toolbar(toolbar, itemForItemIdentifier: itemIdentifier,
                                 willBeInsertedIntoToolbar: flag)
        }
        let tabItem = tabViewItems[idx]
        let item    = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label  = tabItem.label
        item.image  = tabItem.image
        item.target = self
        item.action = #selector(toolbarTabTapped(_:))
        return item
    }

    @objc private func toolbarTabTapped(_ sender: NSToolbarItem) {
        guard let idx = tabIdentifiers.firstIndex(of: sender.itemIdentifier) else { return }
        selectedTabViewItemIndex = idx
        view.window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
    }

    // MARK: Locale refresh

    func refreshTabGroupLabels(keys: [String]) {
        guard let toolbar = view.window?.toolbar else { return }
        for (item, key) in zip(toolbar.items, keys) {
            item.label = LocaleManager.shared.string(key)
        }
    }
}

// MARK: - SettingsWindowController

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    private static let tabLabelKeys = ["General", "Capture", "Tray", "Hotkeys", "About"]

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localeDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func localeDidChange() {
        guard window != nil else { return }
        DispatchQueue.main.async { self.refreshWindowStrings() }
    }

    private func refreshWindowStrings() {
        guard let window,
              let tabVC = window.contentViewController as? FixedTitleTabViewController
        else { return }
        window.title = LocaleManager.shared.string("Settings")
        tabVC.refreshTabGroupLabels(keys: Self.tabLabelKeys)
        window.titlebarSeparatorStyle = .line
    }

    func open() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let tabController = makeTabViewController()

        let win = NSWindow(contentViewController: tabController)
        win.title       = LocaleManager.shared.string("Settings")
        win.level       = .floating
        win.styleMask   = [.titled, .closable, .miniaturizable]
        win.titlebarSeparatorStyle = .line
        win.setFrameAutosaveName("NotchShotSettingsWindow")
        win.appearance  = AppSettings.settingsAppearance.nsAppearance
        win.center()
        win.delegate    = self
        self.window     = win

        tabController.installToolbar(in: win)

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

    private func makeTabViewController() -> FixedTitleTabViewController {
        let tabs = FixedTitleTabViewController()

        let lm = LocaleManager.shared
        let items: [(label: String, image: String, view: AnyView)] = [
            (lm.string("General"), "gearshape",   AnyView(GeneralSettingsView())),
            (lm.string("Capture"), "camera",      AnyView(CaptureSettingsView())),
            (lm.string("Tray"),    "tray",        AnyView(TraySettingsView())),
            (lm.string("Hotkeys"), "keyboard",    AnyView(HotkeySettingsView())),
            (lm.string("About"),   "info.circle", AnyView(AboutSettingsView()))
        ]

        for item in items {
            let hosting = NSHostingController(rootView: item.view.managedLocale())
            hosting.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

            let tabItem = NSTabViewItem(viewController: hosting)
            tabItem.label = item.label
            tabItem.image = NSImage(systemSymbolName: item.image, accessibilityDescription: item.label)
            tabs.addTabViewItem(tabItem)
        }

        return tabs
    }
}
