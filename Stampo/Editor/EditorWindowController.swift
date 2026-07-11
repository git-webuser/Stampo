import AppKit
import SwiftUI
import OSLog

extension Notification.Name {
    /// Posted by the editor after saving an edited image; object is the URL.
    /// NotchPanelController observes it to add the file to the tray.
    static let editorDidSaveImage = Notification.Name("editorDidSaveImage")
}

/// One shared editor window, one document at a time. Pattern:
/// FirstLaunchWindowController's singleton + SettingsWindowController's
/// resizable NSHostingController window.
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()

    private var window: NSWindow?
    private var document: EditorDocument?
    private let store = ScreenshotFileStore()

    var isKeyWindow: Bool { window?.isKeyWindow == true }

    // MARK: Open

    func open(url: URL) {
        // Same file already open — just come forward.
        if let document, document.sourceURL == url, let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // A dirty document is open: settle it before replacing.
        if let existing = document, existing.isDirty {
            guard resolveUnsavedChanges(existing) else { return }
        }

        guard let image = Self.loadFullResImage(at: url) else {
            Log.capture.error("editor: failed to load image")
            return
        }

        let document = EditorDocument(baseImage: image, sourceURL: url)
        self.document = document
        prepareBlurSources(for: document)

        let root = EditorView(document: document, saveHandler: { [weak self] doc in
            self?.performSave(doc) ?? false
        })
        .managedLocale()

        if let window {
            window.contentViewController = NSHostingController(rootView: root)
            window.title = url.lastPathComponent
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.title = url.lastPathComponent
            window.isReleasedWhenClosed = false
            window.setContentSize(Self.initialContentSize(for: image))
            window.setFrameAutosaveName("EditorWindow")
            window.delegate = self
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        // Mandatory for an LSUIElement app: without activation the window
        // never becomes key and the text tool can't take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Save

    /// Renders the annotated image and writes it to the save directory as a
    /// new file; marks the document clean and announces the file so the
    /// panel controller can add it to the tray.
    private func performSave(_ document: EditorDocument) -> Bool {
        guard let rep = AnnotationRenderer.renderBitmap(
            base: document.baseImage,
            blurred: document.blurredBase,
            pixelated: document.pixelatedBase,
            annotations: document.annotations
        ) else {
            Log.capture.error("editor: render for save failed")
            return false
        }
        do {
            let url = try store.saveImage(rep)
            document.markSaved()
            NotificationCenter.default.post(name: .editorDidSaveImage, object: url)
            return true
        } catch {
            Log.capture.error("editor: save failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Could not save the edited image")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return false
        }
    }

    // MARK: Unsaved-changes guard

    /// Returns true when it's OK to discard/replace the document.
    private func resolveUnsavedChanges(_ document: EditorDocument) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Save changes before closing?")
        alert.informativeText = String(localized: "Your annotations will be lost otherwise.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Save
            return performSave(document)
        case .alertSecondButtonReturn:  // Discard
            return true
        default:                        // Cancel
            return false
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let document, document.isDirty else { return true }
        return resolveUnsavedChanges(document)
    }

    func windowWillClose(_ notification: Notification) {
        document = nil
        window = nil
    }

    // MARK: Helpers

    /// Full-resolution load (ThumbnailLoader downsamples — unusable here).
    /// withSaveDirectoryAccess is required for files inside the security-
    /// scoped save folder and harmless for anything else.
    private static func loadFullResImage(at url: URL) -> CGImage? {
        ((try? AppSettings.withSaveDirectoryAccess { _ in loadCGImage(url) }) ?? nil)
            ?? loadCGImage(url)
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func prepareBlurSources(for document: EditorDocument) {
        let base = document.baseImage
        DispatchQueue.global(qos: .userInitiated).async { [weak document] in
            let blurred = AnnotationRenderer.makeBlurred(base: base)
            let pixelated = AnnotationRenderer.makePixelated(base: base)
            DispatchQueue.main.async {
                document?.blurredBase = blurred
                document?.pixelatedBase = pixelated
            }
        }
    }

    /// Image at ~50% of its pixel size (native look on 2x displays), capped
    /// to 80% of the screen and floored to a workable minimum.
    private static func initialContentSize(for image: CGImage) -> NSSize {
        let toolbarAllowance: CGFloat = 40
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let maxW = visible.width * 0.8
        let maxH = visible.height * 0.8 - toolbarAllowance

        var w = CGFloat(image.width) / 2
        var h = CGFloat(image.height) / 2
        let scale = min(1, min(maxW / w, maxH / h))
        w *= scale
        h *= scale
        return NSSize(width: max(560, w), height: max(360, h + toolbarAllowance))
    }
}
