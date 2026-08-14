import AppKit
import SwiftUI
import OSLog

extension Notification.Name {
    /// Posted by the editor after saving an edited image; object is the URL.
    /// NotchPanelController observes it to add the file to the archive.
    static let editorDidSaveImage = Notification.Name("editorDidSaveImage")
    /// Posted once per finding after the editor's Scan succeeds — each barcode
    /// payload separately, then the recognized text. Object is the inert
    /// string that should be added to the archive as a text entity.
    static let editorDidScan = Notification.Name("editorDidScan")
}

/// One shared editor window, one document at a time. Pattern:
/// FirstLaunchWindowController's singleton + SettingsWindowController's
/// resizable NSHostingController window.
final class EditorWindowController: NSObject, NSWindowDelegate {
    static let shared = EditorWindowController()

    private var window: NSWindow?
    private var document: EditorDocument?
    private let store = ScreenshotFileStore()
    /// Alive only while its sheet is up — it owns the format popup's target.
    private var saveAsPanel: EditorSaveAsPanel?

    /// Toast for editor action and OCR/scan outcomes, shared with the notch
    /// capture flows so the editor and hotkey paths confirm results identically.
    /// Owned here because the panel must outlive EditorView's value-type updates.
    let captureHUD = TextCaptureHUD()

    var isKeyWindow: Bool { window?.isKeyWindow == true }
    /// Screen hosting the editor window; the HUD is centered on it.
    var screen: NSScreen? { window?.screen }

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
            guard resolveUnsavedChanges(existing, afterSave: { [weak self] in
                self?.open(url: url)
            }) else { return }
        }

        guard let image = Self.loadFullResImage(at: url) else {
            Log.capture.error("editor: failed to load image")
            return
        }

        let document = EditorDocument(baseImage: image, sourceURL: url)
        self.document = document
        prepareBlurSources(for: document)

        let root = EditorView(
            document: document,
            saveHandler: { [weak self] doc in
                guard let self else { return false }
                return await self.performSave(doc)
            },
            saveAsHandler: { [weak self] doc in
                guard let self else { return }
                await self.presentSaveAs(doc)
            },
            deleteHandler: { [weak self] doc in self?.performDelete(doc) }
        )
        .managedLocale()

        if let window {
            window.contentViewController = NSHostingController(rootView: root)
            window.contentMinSize = EditorView.minimumContentSize
            window.title = url.lastPathComponent
            window.makeKeyAndOrderFront(nil)
        } else {
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.title = url.lastPathComponent
            window.isReleasedWhenClosed = false
            window.contentMinSize = EditorView.minimumContentSize
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
    /// panel controller can add it to the archive.
    private func performSave(_ document: EditorDocument) async -> Bool {
        guard let artifact = await renderArtifact(for: document) else {
            Log.capture.error("editor: render for save failed")
            return false
        }
        do {
            let store = self.store
            let url = try await Task.detached(priority: .utility) {
                try store.saveEncodedImage(artifact.data, format: artifact.format)
            }.value
            // The artifact is still useful even if the user edited meanwhile,
            // but the current document must remain dirty in that case.
            if document.revision == artifact.revision { document.markSaved() }
            NotificationCenter.default.post(name: .editorDidSaveImage, object: url)
            return true
        } catch {
            Log.capture.error("editor: save failed: \(error)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = LocaleManager.shared.string("Could not save the edited image")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: LocaleManager.shared.string("OK"))
            alert.runModal()
            return false
        }
    }

    /// Save As: the same rendered composite, but written where and in what
    /// format the user picks. Like Save it never touches the original file and
    /// announces the result, so the copy joins the archive too — the only
    /// difference is who chooses the destination.
    private func presentSaveAs(_ document: EditorDocument) async {
        let panel = EditorSaveAsPanel(defaultFormat: .fromSettings())
        saveAsPanel = panel
        // Open where the original lives: for a capture that is the save folder
        // anyway, and for a file dropped into the archive it is the folder the
        // user is actually working in.
        let sourceFolder = document.sourceURL.deletingLastPathComponent()
        let directory = FileManager.default.fileExists(atPath: sourceFolder.path)
            ? sourceFolder
            : AppSettings.saveDirectoryURL
        panel.present(
            suggestedName: document.sourceURL.deletingPathExtension().lastPathComponent,
            directory: directory,
            on: window
        ) { [weak self] url, format in
            guard let self else { return }
            self.saveAsPanel = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    // The selected format must be part of the render snapshot.
                    // Rendering in the Settings format and converting here would
                    // decode/re-encode JPEG artifacts on every Save As.
                    guard let artifact = await self.renderArtifact(
                        for: document,
                        format: format.rawValue
                    ) else {
                        throw ScreenshotFileStore.SaveError.encodingFailed
                    }
                    let store = self.store
                    try await Task.detached(priority: .utility) {
                        try store.writeEncodedData(artifact.data, to: url)
                    }.value
                    if document.revision == artifact.revision { document.markSaved() }
                    NotificationCenter.default.post(name: .editorDidSaveImage, object: url)
                    self.captureHUD.show(.saved, on: self.screen)
                } catch {
                    self.presentSaveError(error)
                }
            }
        }
    }

    private func renderArtifact(for document: EditorDocument,
                                format: String = AppSettings.fileFormat) async -> RenderedArtifact? {
        let snapshot = document.makeRenderSnapshot(format: format)
        return await Task.detached(priority: .userInitiated) {
            AnnotationRenderer.renderEncoded(snapshot: snapshot)
        }.value
    }

    private func presentSaveError(_ error: Error) {
        Log.capture.error("editor: save failed: \(error)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = LocaleManager.shared.string("Could not save the edited image")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: LocaleManager.shared.string("OK"))
        alert.runModal()
    }

    // MARK: Delete

    /// Sends the file this document was opened from to the Trash and closes the
    /// editor. The Trash rather than an unlink: this is the one command here
    /// that destroys the user's own file, and it should be as undoable as the
    /// archive's "Move to Trash", which is the same gesture in another place.
    ///
    /// Nothing else has to be told. The archive and any pin of this file watch
    /// it and drop themselves when it goes, exactly as they do for a file
    /// trashed in Finder.
    private func performDelete(_ document: EditorDocument) {
        let url = document.sourceURL
        // Deleting the file settles the question the close guard would ask:
        // the annotations are being discarded on purpose, along with what they
        // were drawn on.
        document.markSaved()
        NSWorkspace.shared.recycle([url]) { _, error in
            guard let error else { return }
            Log.capture.error("editor: delete failed: \(error)")
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = LocaleManager.shared.string("Could not delete the file")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: LocaleManager.shared.string("OK"))
                alert.runModal()
            }
        }
        window?.close()
    }

    // MARK: Unsaved-changes guard

    /// Returns true when it's OK to discard/replace the document *right now*.
    ///
    /// Saving is asynchronous, so "Save" cannot answer true: the render has not
    /// finished when the alert returns. It answers false — the same as Cancel —
    /// and hands the caller's intent to `afterSave`, which runs once the save
    /// lands and the document is clean. `afterSave` is therefore required, not
    /// optional: a caller that has nothing to retry with would turn the user's
    /// "Save" into a silent "Cancel".
    private func resolveUnsavedChanges(_ document: EditorDocument,
                                       afterSave: @escaping () -> Void) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = LocaleManager.shared.string("Save changes before closing?")
        alert.informativeText = LocaleManager.shared.string("Your annotations will be lost otherwise.")
        alert.addButton(withTitle: LocaleManager.shared.string("Save"))
        alert.addButton(withTitle: LocaleManager.shared.string("Discard"))
        alert.addButton(withTitle: LocaleManager.shared.string("Cancel"))

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:   // Save
            Task { @MainActor [weak self] in
                guard let self, await self.performSave(document) else { return }
                afterSave()
            }
            // The caller must keep its current window/document alive while the
            // worker renders. It will be retried by `afterSave` when clean.
            return false
        case .alertSecondButtonReturn:  // Discard
            return true
        default:                        // Cancel
            return false
        }
    }

    /// Same guard as closing the window, for callers that tear the process
    /// down instead. `NSApp.terminate` never sends `windowShouldClose`, so a
    /// dirty document would otherwise die silently.
    ///
    /// False means "don't tear down yet" — the user cancelled, or chose Save
    /// and the write is still in flight. `afterSave` runs on the MainActor once
    /// the document is clean, so callers pass their own retry: teardown then
    /// re-asks this guard, gets true, and proceeds.
    func confirmDiscardingUnsavedWork(afterSave: @escaping () -> Void) -> Bool {
        guard let document, document.isDirty else { return true }
        return resolveUnsavedChanges(document, afterSave: afterSave)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let document, document.isDirty else { return true }
        return resolveUnsavedChanges(document, afterSave: { [weak self] in
            self?.window?.performClose(nil)
        })
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

    /// Warm the default-intensity sources so the blur tool works instantly;
    /// other levels are computed lazily when the slider first asks for them.
    private func prepareBlurSources(for document: EditorDocument) {
        document.prepareBlurSource(style: .gaussian, level: BlurIntensity.defaultLevel)
        document.prepareBlurSource(style: .pixelate, level: BlurIntensity.defaultLevel)
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
        return NSSize(width: max(EditorView.minimumContentSize.width, w),
                      height: max(EditorView.minimumContentSize.height,
                                  h + toolbarAllowance))
    }
}
