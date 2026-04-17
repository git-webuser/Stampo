import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panel = NotchPanelController()
    private lazy var hover = NotchHoverController(panel: panel)

    func applicationDidFinishLaunching(_ notification: Notification) {
        hover.start()
        interceptSettingsMenuItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .requestOpenSettings,
            object: nil
        )
    }

    /// Перехватывает пункт «Settings...» (⌘,) в app menu, который SwiftUI
    /// автоматически добавляет через Settings-сцену, и направляет его к
    /// SettingsWindowController — без вызова showSettingsWindow:.
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
        // Страховка: возвращаем курсор если приложение завершилось во время сэмплинга
        CGDisplayShowCursor(CGMainDisplayID())
    }
    
}
