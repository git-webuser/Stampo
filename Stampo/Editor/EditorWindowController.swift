import AppKit
import SwiftUI
import OSLog

extension Notification.Name {
    /// Posted by the editor when a save begins. The panel answers with its
    /// wait strip, the same one a translation raises — a save renders the whole
    /// page and writes it, and until this the only sign it had happened at all
    /// was the file appearing in the archive.
    static let editorWillSaveImage = Notification.Name("editorWillSaveImage")
    /// Posted by the editor after saving an edited image; object is the URL.
    /// NotchPanelController observes it to add the file to the archive and to
    /// finish the wait.
    static let editorDidSaveImage = Notification.Name("editorDidSaveImage")
    /// Posted when a save ended without a file — refused, failed to render, or
    /// failed to write. The strip has to come down either way.
    static let editorSaveDidFail = Notification.Name("editorSaveDidFail")
    /// Posted once per finding after the editor's Scan succeeds — each barcode
    /// payload separately, then the recognized text. Object is the inert
    /// string that should be added to the archive as a text entity.
    static let editorDidScan = Notification.Name("editorDidScan")
    /// Posted instead of the scan's own toast when the editor's scan was armed
    /// with ⌃. Object is an `EditorScanTranslation`. The archive belongs to the
    /// panel controller, so the editor announces the prose and the controller
    /// runs the same translation the panel's own scan does.
    static let editorDidScanForTranslation = Notification.Name("editorDidScanForTranslation")
}

/// Recognized prose from an editor scan that asked to be translated, and the
/// language ⇥ named for it — nil means nobody chose, which is what selects the
/// ordinary automatic route.
struct EditorScanTranslation {
    let text: String
    let language: Locale.Language?
}

/// One editor window per document.
///
/// It began as a singleton that swapped its document, which meant a second
/// screenshot could not be opened without settling the first — the editor
/// locked the capture behind whatever was already in it. A window per document
/// removes that, and hands over the system's own window tabs while it is at it.
///
/// The type keeps the list of open editors, because the questions that used to
/// go to a singleton — "open this file", "is anything unsaved" — are still
/// questions about *all* of them, and there is nowhere else that knows.
final class EditorWindowController: NSObject, NSWindowDelegate {
    /// Every open editor, in the order they were opened.
    private static var editors: [EditorWindowController] = []

    /// The app's colour list, shared by every editor — see
    /// `PresentationColorShelf`. Weak, and on the type rather than on an
    /// instance: the archive belongs to the panel controller and outlives every
    /// window, but no editor should be the reason it stays alive.
    static weak var colorShelf: (any PresentationColorShelf)?

    /// Opens the file, or brings its editor forward if it is already open.
    ///
    /// One window per file, keyed by URL: opening the same shot twice used to
    /// mean two windows racing to save over each other.
    static func open(url: URL) {
        if let existing = editors.first(where: { $0.document?.sourceURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let editor = EditorWindowController()
        editors.append(editor)
        editor.open(url: url)
        // A window that failed to open leaves nothing to keep.
        if editor.window == nil { editors.removeAll { $0 === editor } }
    }

    /// True when every open editor is either clean or has been settled by the
    /// user. Asked before quitting and before the first-launch window takes
    /// over: with several windows the question is about all of them, and the
    /// first dirty one that is not settled ends the walk.
    static func confirmDiscardingUnsavedWork(afterSave: @escaping () -> Void) -> Bool {
        for editor in editors where editor.document?.isDirty == true {
            guard editor.confirmDiscardingUnsavedWork(afterSave: afterSave) else { return false }
        }
        return true
    }

    /// How many editors are open. The window per document is the feature, so
    /// the count is worth being able to ask about — the menu will want it, and
    /// a test does now.
    static var openCount: Int { editors.count }

    /// Closes every editor without asking, for tests that opened them.
    static func closeAllForTesting() {
        for editor in editors { editor.window?.close() }
        editors.removeAll()
    }

    /// The editor that has the keyboard, if any is up.
    static var keyEditor: EditorWindowController? {
        editors.first { $0.window?.isKeyWindow == true }
    }

    private var window: NSWindow?
    private var document: EditorDocument?
    private let store = ScreenshotFileStore()
    /// Alive only while its sheet is up — it owns the format popup's target.
    private var saveAsPanel: EditorSaveAsPanel?

    /// Toast for editor action and OCR/scan outcomes, shared with the notch
    /// capture flows so the editor and hotkey paths confirm results identically.
    /// Owned here because the panel must outlive EditorView's value-type updates.
    let captureHUD = TextCaptureHUD()

    /// What this editor's views may ask about its window, and nothing more —
    /// see `EditorWindowContext`. Read through closures so the answers follow
    /// the window rather than being snapshotted before it exists.
    private var windowContext: EditorWindowContext {
        EditorWindowContext(
            isKeyWindow: { [weak self] in self?.window?.isKeyWindow == true },
            overlayParent: { [weak self] in self?.window },
            showCaptureOutcome: { [weak self] outcome in
                guard let self else { return }
                self.captureHUD.show(outcome, on: self.window?.screen)
            }
        )
    }

    /// True while a render-and-write is in flight. See `performSave`.
    private var isSaving = false

    // MARK: Open

    private func open(url: URL) {
        guard let image = Self.loadFullResImage(at: url) else {
            Log.capture.error("editor: failed to load image")
            return
        }

        let document = EditorDocument(baseImage: image, sourceURL: url)
        self.document = document
        prepareBlurSources(for: document)

        let root = EditorView(
            document: document,
            windowContext: windowContext,
            saveHandler: { [weak self] doc in
                guard let self else { return false }
                return await self.performSave(doc)
            },
            saveAsHandler: { [weak self] doc in
                guard let self else { return }
                await self.presentSaveAs(doc)
            },
            deleteHandler: { [weak self] doc in self?.performDelete(doc) },
            presentationInspectorChanged: { [weak self] isPresented in
                // AppKit owns the window minimum; the view only reports the
                // native inspector's state so the main editor never gets
                // squeezed below the toolbar's existing floor.
                DispatchQueue.main.async {
                    self?.updateEditorMinimumSize(inspectorPresented: isPresented)
                }
            },
            colorShelf: Self.colorShelf
        )
        .managedLocale()

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.contentMinSize = EditorView.minimumContentSize
        window.setContentSize(Self.initialContentSize(for: image))
        // One identifier for all of them, so the system's own tabs work: drag
        // one editor onto another and they become tabs, with no code of ours in
        // the way. The autosave name is deliberately *not* set any more — one
        // frame remembered for every window put each new editor exactly on top
        // of the last.
        window.tabbingIdentifier = "StampoEditor"
        window.delegate = self
        self.window = window
        if let previous = Self.editors.last(where: { $0 !== self })?.window {
            // Stepped down from the editor before it, the way documents open
            // everywhere else, rather than centred on top of it.
            window.setFrameTopLeftPoint(
                previous.cascadeTopLeft(from: NSPoint(x: previous.frame.minX,
                                                      y: previous.frame.maxY))
            )
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        // Mandatory for an LSUIElement app: without activation the window
        // never becomes key and the text tool can't take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        warmDecorInspector(for: document)
    }

    /// Builds the decor inspector once, offscreen, so the first press of the
    /// button does not pay for it.
    ///
    /// Measured: the panel takes about 140 ms to build the first time in a
    /// process and 80 ms every time after — the extra is the machinery behind
    /// its own view types, which no generic warm-up reaches (a primer of plain
    /// sliders and fields was tried and left the first build at 139 ms). The
    /// only thing that warms this panel is this panel.
    ///
    /// Safe to build and throw away because the inspector is documented never
    /// to write on appear: it copies the presentation into a local draft and
    /// waits to be told something. The colour shelf is left out so no archive
    /// is touched.
    ///
    /// Half a second after the editor opens, so the cost lands while the user
    /// is still looking at their screenshot rather than while the window is
    /// coming up.
    private func warmDecorInspector(for document: EditorDocument) {
        guard !Self.decorInspectorWarmed else { return }
        Self.decorInspectorWarmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let view = NSHostingView(
                rootView: PresentationInspector(document: document, colorShelf: nil)
                    .frame(width: EditorView.presentationInspectorIdealWidth)
            )
            // Offscreen and never ordered in: laying out is the whole point,
            // and a window that is never shown cannot flash.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.contentView = nil
        }
    }

    /// Once per launch: the machinery it warms belongs to the process, not to
    /// the document.
    private static var decorInspectorWarmed = false

    /// The same warm-up, without the delay — for measuring it.
    static func warmDecorInspectorForTesting(document: EditorDocument) {
        let view = NSHostingView(
            rootView: PresentationInspector(document: document, colorShelf: nil)
                .frame(width: EditorView.presentationInspectorIdealWidth)
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.contentView = nil
    }

    /// Keeps the window wide enough for the editor and the inspector's
    /// smallest usable column. Collapsing releases the extra minimum but does
    /// not forcibly shrink a window the user has already enlarged.
    private func updateEditorMinimumSize(inspectorPresented: Bool) {
        guard let window else { return }
        let base = EditorView.minimumContentSize
        let minimum = CGSize(
            width: base.width + (inspectorPresented
                                 ? EditorView.presentationInspectorMinimumWidth
                                 : 0),
            height: base.height
        )
        window.contentMinSize = minimum

        guard inspectorPresented else { return }
        let current = window.contentView?.bounds.size ?? window.frame.size
        let expanded = CGSize(width: max(current.width, minimum.width),
                              height: max(current.height, minimum.height))
        if expanded != current {
            window.setContentSize(expanded)
        }
    }

    // MARK: Save

    /// Renders the annotated image and writes it to the save directory as a
    /// new file; marks the document clean and announces the file so the
    /// panel controller can add it to the archive.
    ///
    /// The interlock lives here rather than in the view because there are two
    /// ways in: the toolbar's Save, which the view disables while a render is
    /// running, and the unsaved-changes alert, which calls straight through and
    /// never saw that flag. Both saves would have rendered, both would have
    /// been given a collision-free name — one document, two files, two archive
    /// entries. A refused second save answers false, so a close or relaunch
    /// waiting on it stays put rather than proceeding on someone else's write.
    private func performSave(_ document: EditorDocument) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        NotificationCenter.default.post(name: .editorWillSaveImage, object: nil)
        // Every road out of here says so: the strip is up, and a save that ends
        // in an alert or in a refusal must not leave it turning.
        var landed = false
        defer {
            isSaving = false
            if !landed { NotificationCenter.default.post(name: .editorSaveDidFail, object: nil) }
        }

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
            landed = true
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
                    self.captureHUD.show(.saved, on: self.window?.screen)
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
        Self.editors.removeAll { $0 === self }
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
