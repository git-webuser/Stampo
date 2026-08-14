import AppKit
@preconcurrency import Quartz

extension Notification.Name {
    /// Bracket the Quick Look panel's lifetime. Like the share sheet, it is a
    /// window of ours that the notch panel must not slide out from under.
    static let quickLookDidOpen  = Notification.Name("StampoQuickLookDidOpen")
    static let quickLookDidClose = Notification.Name("StampoQuickLookDidClose")
}

/// Space-to-preview for the archive, the way Finder does it.
///
/// `QLPreviewPanel` is a shared singleton that asks the responder chain who
/// controls it, so the app delegate answers on this object's behalf (see
/// AppDelegate) — driving `dataSource` directly without a controller lets
/// AppKit reset it out from under us.
@MainActor
final class QuickLookPresenter: NSObject {
    static let shared = QuickLookPresenter()

    private(set) var urls: [URL] = []
    /// Esc reaches us as a Carbon hotkey before the Quick Look window sees it,
    /// so the panel has to be closed by hand — otherwise Esc would close the
    /// notch panel underneath and leave the preview floating.
    private var escToken: UUID?

    private override init() { super.init() }

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Opens (or retargets) the preview. A second call with the same files
    /// closes it, so the same key that opened the preview dismisses it.
    func toggle(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isOpen, urls == self.urls {
            close()
            return
        }
        self.urls = urls
        // Accessory app: the preview window can't come forward on its own.
        NSApp.activate(ignoringOtherApps: true)
        let panel = QLPreviewPanel.shared()!
        if isOpen {
            panel.reloadData()
            return
        }
        NotificationCenter.default.post(name: .quickLookDidOpen, object: nil)
        escToken = TransientHotkeyCenter.escape.push { [weak self] in self?.close() }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        if isOpen { QLPreviewPanel.shared().orderOut(nil) }
        finish()
    }

    /// Called both by `close()` and by the panel telling us it went away.
    fileprivate func finish() {
        guard escToken != nil else { return }
        if let token = escToken { TransientHotkeyCenter.escape.remove(token) }
        escToken = nil
        urls = []
        NotificationCenter.default.post(name: .quickLookDidClose, object: nil)
    }
}

// MARK: - Panel plumbing

// @preconcurrency: neither Quick Look protocol is main-actor annotated, but
// AppKit only ever calls them on the main thread.
extension QuickLookPresenter: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    /// The panel hands key events it doesn't use back to the controller —
    /// Space closes it again, matching Finder.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 /* Space */ else { return false }
        close()
        return true
    }

    /// Called by the app delegate when the panel takes/releases us.
    func attach(to panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func detach(from panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        finish()
    }
}
