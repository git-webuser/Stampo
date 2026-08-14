import AppKit

// MARK: - ScanSelectionMode

/// What the scanner will do with the region once the mouse comes up.
///
/// One value rather than two flags, because the two modes cannot both apply:
/// translation forces the recognized lines back into paragraphs regardless of
/// ⌥, so a frame showing both would be promising something that cannot happen.
/// Translation therefore outranks line breaks, here and in the scan itself.
enum ScanSelectionMode: Equatable {
    /// Recognize, join wrapped lines back into paragraphs, file the result.
    case plain
    /// Keep the line breaks the original layout produced (⌥).
    case keepLineBreaks
    /// Translate the recognized text (⌃).
    case translate

    /// Nil for `.plain`: an unmodified frame is the one that should look like
    /// it always has.
    var tint: NSColor? {
        switch self {
        case .plain:          return nil
        case .keepLineBreaks: return .systemOrange
        case .translate:      return .systemBlue
        }
    }

    var titleKey: String {
        switch self {
        case .plain:          return ""
        case .keepLineBreaks: return "Keep line breaks"
        case .translate:      return "Translate"
        }
    }

    var symbolName: String? {
        switch self {
        case .plain:          return nil
        // The return glyph — the thing being preserved, drawn as itself.
        case .keepLineBreaks: return "arrow.turn.down.left"
        case .translate:      return "translate"
        }
    }
}

// MARK: - SelectionOverlay

/// Full-screen drag-to-select overlay.
/// Calls `onSelected` with the selected CGRect in global CG coordinates
/// (origin top-left of primary display — compatible with `screencapture -R`).
final class SelectionOverlay {
    var onSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    /// Set by the scanner before `start`: ⌥ and ⌃ toggle the two scan modes.
    /// Off for a plain selection screenshot, which has only one outcome and
    /// nothing to hint at.
    var showsScanModes = false

    /// The mode in force when the selection was completed. Read by the scanner
    /// immediately after `onSelected` — passing it through the callback would
    /// change a signature three capture paths use and none of them cares
    /// about. Reset at every `start`: a mode that survived from one invocation
    /// to the next would be invisible until the first drag.
    private(set) var selectionMode: ScanSelectionMode = .plain

    /// The language this scan will be translated into when ⇥ has been used to
    /// say so, `nil` when it has not.
    ///
    /// Scoped to one overlay session and reset at every `start`, exactly like
    /// `selectionMode` above and for a stronger version of the same reason. A
    /// mode that outlived a scan would merely be invisible until the first
    /// drag; a *destination* that outlived one used to be written to the
    /// setting the clipboard hotkey reads, so a language picked here for one
    /// screenful silently became where everything went from then on.
    private(set) var translationTarget: Locale.Language?

    private var modifierMonitor: Any?
    private var keyMonitor: Any?
    /// Modifier state at the last flags event, so a press can be told from a
    /// release.
    private var wasControlDown = false
    private var wasOptionDown = false

    private var panel: NSPanel?
    private var targetScreen: NSScreen?
    private var escObservation: EscObservation?

    private var selectionCursor: NSCursor?
    private var cursorPushed = false
    private var cursorTimer: Timer?
    private var cursorObservers: [NSObjectProtocol] = []

    isolated deinit {
        resetCursorState()
    }

    func start(on screen: NSScreen) {
        targetScreen = screen
        let frame = screen.frame

        let panel = makeOverlayPanel(frame: frame)
        let cursor = makeScreenshotCrosshairCursor()
        selectionCursor = cursor

        let view = SelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.selectionCursor = cursor
        selectionMode = .plain
        translationTarget = nil
        view.onCompleted = { [weak self] nsRect in
            guard let self else { return }
            let cgRect = viewRectToCGRect(nsRect, screen: screen)
            self.dismiss()
            self.onSelected?(cgRect)
        }
        view.onCancelled = { [weak self] in
            self?.dismiss()
            self?.onCancelled?()
        }
        panel.contentView = view
        self.panel = panel

        escObservation = EscObservation { [weak self] in self?.cancel() }
        if showsScanModes {
            installModifierMonitor(view: view)
            installTranslationKeyMonitor(view: view)
        }

        cursor.push()
        cursorPushed = true

        // Allow cursor control even when our process is not the active app —
        // without this NSCursor.set() has no effect while another app is
        // frontmost (e.g. text field I-beam from the underlying app overrides us).
        CGSCursorBridge.setCursorInBackground(true)

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        // Set AFTER makeKeyAndOrderFront so AppKit's window-activation cursor
        // reset is overridden.
        cursor.set()

        installCursorMaintenance(panel: panel)
    }

    func cancel() {
        dismiss()
        onCancelled?()
    }

    func resetCursorState() {
        removeCursorMaintenance()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        selectionCursor = nil
        CGSCursorBridge.setCursorInBackground(false)
        NSCursor.arrow.set()
        Task { @MainActor in NSCursor.arrow.set() }
    }

    private func dismiss() {
        guard panel != nil else { return }

        removeCursorMaintenance()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        selectionCursor = nil

        CGSCursorBridge.setCursorInBackground(false)

        escObservation?.cancel()
        escObservation = nil

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }

        panel?.orderOut(nil)
        panel = nil

        NSCursor.arrow.set()
        Task { @MainActor in NSCursor.arrow.set() }
    }

    // MARK: - Translate mode

    /// ⌥ and ⌃ toggle their modes rather than being held down for them.
    ///
    /// Two reasons, and neither is preference. The overlay panel is
    /// `[.borderless, .nonactivatingPanel]` with no `canBecomeKey` override, so
    /// it never becomes the key window and `flagsChanged` never reaches the
    /// view through the responder chain — which is why `EscObservation` exists
    /// at all. Held-modifier state could therefore only be refreshed from mouse
    /// events, leaving a badge on screen after the key came up until the
    /// pointer happened to move. A monitor fixes the delivery; a toggle removes
    /// the need to hold a key through a whole drag, and is only honest because
    /// the mode is now visible on the frame.
    ///
    /// Toggled on the press, never the release. The scan hotkey is ⌃⌥⌘S, so
    /// both keys are already down when this installs — seeding the previous
    /// state from the current flags means letting go of that chord reads as a
    /// release and changes nothing.
    private func installModifierMonitor(view: SelectionView) {
        let flags = NSEvent.modifierFlags
        wasControlDown = flags.contains(.control)
        wasOptionDown = flags.contains(.option)

        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self, weak view] event in
            guard let self else { return event }
            let control = event.modifierFlags.contains(.control)
            let option = event.modifierFlags.contains(.option)
            let controlPressed = control && !self.wasControlDown
            let optionPressed = option && !self.wasOptionDown
            self.wasControlDown = control
            self.wasOptionDown = option

            // Each key owns its own mode and turning one on turns the other
            // off: they are alternatives, not layers, since translating
            // rejoins the lines that ⌥ exists to preserve.
            if controlPressed {
                self.selectionMode = self.selectionMode == .translate ? .plain : .translate
            } else if optionPressed {
                self.selectionMode = self.selectionMode == .keepLineBreaks ? .plain : .keepLineBreaks
            } else {
                return event
            }
            view?.mode = self.selectionMode
            return event
        }
    }

    /// ⇥ cycles the language a translating scan goes into, ⇧⇥ backwards.
    ///
    /// Tab rather than the colour HUD's F: there, F stands for Format and the
    /// mnemonic is the point. No letter stands for "the next language", so a
    /// letter would just be a key to memorise — while Tab already means the
    /// next one everywhere, and a selection overlay has no text entry for it
    /// to take away.
    ///
    /// A monitor rather than the view's `keyDown` for the same reason the
    /// modifiers need one: this panel is `[.borderless, .nonactivatingPanel]`
    /// and never becomes key, so nothing arrives through the responder chain —
    /// which is why Esc has its own `EscObservation` too.
    ///
    /// Only while the translate mode is armed: the key belongs to whoever is
    /// underneath the rest of the time, and swallowing it there would be a
    /// keystroke going missing in another app.
    private func installTranslationKeyMonitor(view: SelectionView) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak view] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let languages = TranslationLanguages.shared
            guard let self, self.selectionMode == .translate,
                  AppSettings.hotkeyHUDFormatEnabled,
                  // The same test the badge applies. Without it the key
                  // cycled on two languages while the badge stayed silent, so
                  // the destination changed with nothing on screen saying so —
                  // and the scan then refused as "already in that language".
                  languages.offersChoice,
                  event.keyCode == KeyCode.tab,
                  flags.isDisjoint(with: [.command, .option, .control])
            else { return event }

            self.translationTarget = TranslationLanguages.language(
                after: self.translationTarget ?? languages.destination,
                in: languages.favourites,
                backwards: flags.contains(.shift))
            // The badge names the target, so its width changes with the name —
            // the whole view redraws rather than the badge's old frame.
            view?.translationTarget = self.translationTarget
            view?.needsDisplay = true
            return nil
        }
    }

    // MARK: - Cursor maintenance

    private func installCursorMaintenance(panel: NSPanel) {
        // Space change: re-front overlay after transition animation (150 ms).
        let spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, let panel, self.cursorPushed else { return }
                panel.orderFrontRegardless()
                self.selectionCursor?.set()
            }
        }

        // App-activation: re-apply after our app regains active status.
        let activateObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.cursorPushed else { return }
                self.selectionCursor?.set()
            }
        }

        cursorObservers = [spaceObs, activateObs]

        // 30 fps timer covers the stationary case where macOS resets the cursor
        // without a mouse-moved event (e.g. I-beam override from underlying text input).
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.cursorPushed else { return }
                self.selectionCursor?.set()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        cursorTimer = t
    }

    private func removeCursorMaintenance() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        cursorObservers.removeAll()
    }
}

// MARK: - SelectionView

private final class SelectionView: NSView {
    var selectionCursor: NSCursor = .crosshair  // set by SelectionOverlay before display
    var onCompleted: ((NSRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    /// Last known pointer position, so the badge has somewhere to sit before a
    /// selection exists to pin it to.
    private var hoverPoint: NSPoint?

    /// What the next release will do, set by the overlay's modifier monitor —
    /// this view cannot observe the keyboard itself, since the panel it lives
    /// in never becomes key.
    var mode: ScanSelectionMode = .plain {
        didSet { if mode != oldValue { needsDisplay = true } }
    }

    /// The language the badge names, when ⇥ has chosen one for this scan. Set
    /// by the same monitor and for the same reason as `mode`.
    var translationTarget: Locale.Language? {
        didSet { if translationTarget != oldValue { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selectionCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        selectionCursor.set()
    }

    override func mouseEntered(with event: NSEvent) {
        selectionCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        selectionCursor.set()
        let previous = hoverPoint
        hoverPoint = convert(event.locationInWindow, from: nil)

        // Only while the badge is actually following the pointer, and only the
        // two rectangles it occupies. `needsDisplay` on a view the size of the
        // display, at mouse-move rate, is a scrim the size of a 5K screen
        // repainted for a label 90 points wide.
        guard mode != .plain, startPoint == nil, let hoverPoint else { return }
        var dirty = badgeFrame(nearPointer: hoverPoint)
        if let previous { dirty = dirty.union(badgeFrame(nearPointer: previous)) }
        setNeedsDisplay(dirty.insetBy(dx: -2, dy: -2))
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let current = currentPoint else { onCancelled?(); return }
        let rect = makeRect(from: start, to: current)
        startPoint = nil; currentPoint = nil; needsDisplay = true
        guard rect.width >= 4, rect.height >= 4 else { onCancelled?(); return }
        onCompleted?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape { onCancelled?() } else { super.keyDown(with: event) }
    }

    private func makeRect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.fill(bounds)

        guard let start = startPoint, let current = currentPoint else {
            // No frame yet. Both modes are toggles, so either can be armed
            // before the drag begins — and then the badge is the only thing
            // that says so. It rides the pointer until there is a rectangle to
            // pin it to.
            if mode != .plain, let hoverPoint {
                drawBadge(in: badgeFrame(nearPointer: hoverPoint))
            }
            return
        }
        let sel = makeRect(from: start, to: current)
        guard sel.width > 0, sel.height > 0 else { return }

        ctx.clear(sel)

        // Tinting the frame is the half that needs no reading: the mode is
        // visible from the corner of the eye, and the badge spells it out for
        // whoever looks straight at it.
        let stroke = mode.tint?.withAlphaComponent(0.95) ?? NSColor.white.withAlphaComponent(0.9)
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(mode == .plain ? 1.5 : 2)
        ctx.addRect(sel.insetBy(dx: 0.75, dy: 0.75))
        ctx.strokePath()

        if mode != .plain { drawBadge(in: badgeFrame(over: sel)) }
    }

    // MARK: - Mode badge

    /// The pill's own geometry and drawing live in `ScanModeBadge`, shared with
    /// the editor's scanner. This view only decides where the badge sits and
    /// when it is drawn, so the two surfaces cannot drift apart.
    private var badge: ScanModeBadge {
        ScanModeBadge(mode: mode, translationTarget: translationTarget)
    }

    private func badgeFrame(over sel: NSRect) -> NSRect {
        badge.frame(over: sel, in: bounds)
    }

    private func badgeFrame(nearPointer point: NSPoint) -> NSRect {
        badge.frame(nearPointer: point, in: bounds)
    }

    private func drawBadge(in frame: NSRect) {
        badge.draw(in: frame)
    }
}
