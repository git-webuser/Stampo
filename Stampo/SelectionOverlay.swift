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

    /// Mode the next `start` opens in. The hotkey scanner always begins plain —
    /// a fresh scan should not silently inherit a modifier from the last one.
    /// The editor seeds it from its own Line Breaks control instead, so the
    /// picker and ⌥ are two ways of saying the same thing rather than two
    /// settings that disagree.
    var initialScanMode: ScanSelectionMode = .plain

    /// Fires whenever ⌥ or ⌃ changes the mode, so an owner that shows the same
    /// state elsewhere can follow the badge.
    var onScanModeChanged: ((ScanSelectionMode) -> Void)?

    /// Pinch and Space-drag, handed to whatever the overlay is covering.
    ///
    /// A full-screen overlay leaves these nil: there is nothing underneath it
    /// to zoom or pan, and the gestures belong to whichever app is down there.
    /// The editor sets them, because its overlay sits on a canvas whose own
    /// zoom and pan are how you reach a region too small to select at fit size
    /// — and the overlay would otherwise swallow both.
    var onMagnify: ((CGFloat) -> Void)?
    var onPan: ((CGSize) -> Void)?

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
    private var tabToken: UUID?
    private var shiftTabToken: UUID?
    private var viewportMonitor: Any?
    private var modifierPollTimer: Timer?
    /// Modifier state at the last flags event, so a press can be told from a
    /// release.
    private var wasControlDown = false
    private var wasOptionDown = false

    private var panel: NSPanel?
    /// Set only for a window-bound overlay; the child relationship is undone in
    /// `dismiss` so the parent never outlives it holding a dead child.
    private weak var parentWindow: NSWindow?
    private var targetScreen: NSScreen?
    private var escObservation: EscObservation?

    private var selectionCursor: NSCursor?
    private var cursorPushed = false
    private var cursorTimer: Timer?
    private var cursorObservers: [NSObjectProtocol] = []

    /// Full teardown, not just the cursor.
    ///
    /// The panel, the Esc observation and both event monitors are released by
    /// `dismiss`, and an owner that simply lets go of an armed overlay used to
    /// skip all three — leaving a borderless panel on screen with nothing left
    /// alive to close it. The panel scanner never hit that because its overlay
    /// lives as long as the controller; the editor's is owned by a view.
    isolated deinit {
        dismiss()
        resetCursorState()
    }

    func start(on screen: NSScreen) {
        start(over: screen.frame, on: screen)
    }

    /// Presents the same overlay over an arbitrary rect in AppKit screen
    /// coordinates instead of a whole display.
    ///
    /// The editor scans inside the rect its image occupies: the window's own
    /// controls stay live because the overlay never reaches them, and a
    /// selection cannot leave the image because the panel is the image. The
    /// display stays an explicit argument — the flip into CG coordinates is
    /// measured against the primary display, not against this rect.
    ///
    /// `parent` binds the overlay to a window. The screen-saver level and
    /// `.canJoinAllSpaces` that the hotkey scanner wants are exactly wrong for
    /// a mode that stays armed: a panel above every app, following the user to
    /// other Spaces, over a window they may have switched away from. As a child
    /// window it orders, moves and hides with its parent instead. Passing nil
    /// keeps the full-screen behaviour untouched.
    func start(over rect: NSRect, on screen: NSScreen, parent: NSWindow? = nil) {
        targetScreen = screen
        let frame = rect

        let panel = makeOverlayPanel(frame: frame)
        if let parent {
            panel.level = .normal
            panel.collectionBehavior = [.fullScreenAuxiliary]
            parentWindow = parent
        }
        let cursor = makeScreenshotCrosshairCursor()
        selectionCursor = cursor

        let view = SelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.selectionCursor = cursor
        selectionMode = showsScanModes ? initialScanMode : .plain
        view.mode = selectionMode
        translationTarget = nil
        view.onCompleted = { [weak self] nsRect in
            guard let self else { return }
            // The panel's *current* origin, not the one it opened at: a
            // window-bound overlay is re-framed as the image zooms, pans or
            // rides a moving window, and the selection belongs to where it
            // ended up.
            let origin = self.panel?.frame.origin ?? frame.origin
            let cgRect = viewRectToCGRect(nsRect, panelOrigin: origin, screen: screen)
            self.dismiss()
            self.onSelected?(cgRect)
        }
        view.onCancelled = { [weak self] in
            self?.dismiss()
            self?.onCancelled?()
        }
        // Only wired when an owner asked for it, so a drag over the full-screen
        // overlay still always means "select".
        if onPan != nil {
            view.onPan = { [weak self] delta in self?.onPan?(delta) }
        }
        panel.contentView = view
        self.panel = panel

        escObservation = EscObservation { [weak self] in self?.cancel() }
        if showsScanModes {
            installModifierMonitor(view: view)
            syncTranslationKeys(view: view)
        }
        if onMagnify != nil || onPan != nil {
            installViewportMonitor(view: view)
        }

        cursor.push()
        cursorPushed = true

        // Allow cursor control even when our process is not the active app —
        // without this NSCursor.set() has no effect while another app is
        // frontmost (e.g. text field I-beam from the underlying app overrides us).
        CGSCursorBridge.setCursorInBackground(true)

        NSApp.activate(ignoringOtherApps: true)
        parentWindow?.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        // Set AFTER makeKeyAndOrderFront so AppKit's window-activation cursor
        // reset is overridden.
        cursor.set()

        installCursorMaintenance(panel: panel)
    }

    /// Moves the armed overlay to a new rect, in AppKit screen coordinates.
    ///
    /// The editor's image is not a fixed target: it grows and shifts with zoom
    /// and pan, and the overlay has to stay exactly over it or a selection
    /// would mean something other than what it enclosed. A no-op when nothing
    /// is armed.
    func updateBounds(_ rect: NSRect) {
        guard let panel, panel.frame != rect else { return }
        panel.setFrame(rect, display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView?.needsDisplay = true
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
        // One more on the next turn of the main queue, to beat AppKit's own
        // restoration after the window orders out. `DispatchQueue.main.async`
        // rather than a `Task`: a task hops through the cooperative pool and
        // lands later than the queue does, which is late enough for a scanner
        // armed in the same breath to have its crosshair overwritten — the
        // cursor visibly dropped to the arrow until the 30 fps maintenance
        // timer put it back.
        DispatchQueue.main.async { MainActor.assumeIsolated { NSCursor.arrow.set() } }
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

        releaseTranslationKeys()

        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }

        if let viewportMonitor {
            NSEvent.removeMonitor(viewportMonitor)
            self.viewportMonitor = nil
        }

        modifierPollTimer?.invalidate()
        modifierPollTimer = nil

        if let panel { parentWindow?.removeChildWindow(panel) }
        parentWindow = nil
        panel?.orderOut(nil)
        panel = nil

        NSCursor.arrow.set()
        // One more on the next turn of the main queue, to beat AppKit's own
        // restoration after the window orders out. `DispatchQueue.main.async`
        // rather than a `Task`: a task hops through the cooperative pool and
        // lands later than the queue does, which is late enough for a scanner
        // armed in the same breath to have its crosshair overwritten — the
        // cursor visibly dropped to the arrow until the 30 fps maintenance
        // timer put it back.
        DispatchQueue.main.async { MainActor.assumeIsolated { NSCursor.arrow.set() } }
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
            self?.applyModifiers(event.modifierFlags, to: view)
            return event
        }

        // A local monitor only hears from an active app, and this one is
        // `LSUIElement`: ⌘-Tab away and the app cannot be ⌘-Tabbed back to, so
        // it stays inactive with the overlay still on screen above everything.
        // The monitor is then permanently deaf and the badge never answers ⌃
        // again — while Esc keeps working, because it goes through a global
        // hotkey rather than a monitor.
        //
        // `NSEvent.modifierFlags` is a plain read of the current state that
        // needs neither activation nor an Accessibility grant, so the armed
        // overlay polls it. Same 30 fps and the same reasoning as the cursor
        // maintenance above: the state can change without an event ever being
        // delivered to us. Both paths run one function, so they cannot drift.
        let poll = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak view] _ in
            Task { @MainActor [weak self, weak view] in
                self?.applyModifiers(NSEvent.modifierFlags, to: view)
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        modifierPollTimer = poll
    }

    /// Edge-detects ⌃ and ⌥ against the last state seen, whichever path saw it.
    private func applyModifiers(_ flags: NSEvent.ModifierFlags, to view: SelectionView?) {
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let controlPressed = control && !wasControlDown
        let optionPressed = option && !wasOptionDown
        wasControlDown = control
        wasOptionDown = option

        // Each key owns its own mode and turning one on turns the other
        // off: they are alternatives, not layers, since translating
        // rejoins the lines that ⌥ exists to preserve.
        if controlPressed {
            selectionMode = selectionMode == .translate ? .plain : .translate
        } else if optionPressed {
            selectionMode = selectionMode == .keepLineBreaks ? .plain : .keepLineBreaks
        } else {
            return
        }
        view?.mode = selectionMode
        syncTranslationKeys(view: view)
        onScanModeChanged?(selectionMode)
    }

    /// Space for panning and pinch for zooming, forwarded to whatever the
    /// overlay covers.
    ///
    /// A monitor rather than `keyDown`/`magnify` on the view, for the same
    /// reason the modifiers need one: this panel is
    /// `[.borderless, .nonactivatingPanel]` and never becomes key, so none of
    /// those ever reach the responder chain. Only the mouse does, which is why
    /// selection worked while every keyboard-driven gesture silently did not.
    ///
    /// Space gates panning and nothing else. A drag is the one gesture that
    /// would otherwise be ambiguous — it already means "select" — so it is the
    /// one that needs a modifier to mean something different. Pinch has no such
    /// conflict and stays free.
    private func installViewportMonitor(view: SelectionView) {
        viewportMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .magnify]
        ) { [weak self, weak view] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown where event.keyCode == KeyCode.space && self.onPan != nil:
                view?.isSpaceHeld = true
                // Swallowed: nothing here types, and an unhandled Space beeps.
                return nil
            case .keyUp where event.keyCode == KeyCode.space && self.onPan != nil:
                view?.isSpaceHeld = false
                view?.endPan()
                return nil
            case .magnify where self.onMagnify != nil:
                self.onMagnify?(event.magnification)
                return nil
            default:
                return event
            }
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
    /// Claims ⇥ system-wide while — and only while — a translating scan is
    /// armed, through the same centre the panel's header cycling uses.
    ///
    /// A local monitor cannot do this job. It hears nothing while the app is
    /// inactive, and this app is `LSUIElement`, so an overlay left on screen
    /// over another app got no ⇥ at all — worse, the key went *through* to that
    /// app, moving its focus ring while the badge sat unchanged. A Carbon
    /// hotkey is heard whatever is frontmost and consumes the key, which is
    /// both halves of the problem.
    ///
    /// Pushed and popped with the mode rather than held for the overlay's whole
    /// life, exactly as `TransientHotkeyCenter.tab` documents: a claimed key is
    /// claimed for every app on the machine, and ⇥ means something everywhere.
    private func syncTranslationKeys(view: SelectionView?) {
        let languages = TranslationLanguages.shared
        // The same test the badge applies. Without it the key cycled on two
        // languages while the badge stayed silent, so the destination changed
        // with nothing on screen saying so — and the scan then refused as
        // "already in that language".
        let wanted = selectionMode == .translate
            && AppSettings.hotkeyHUDFormatEnabled
            && languages.offersChoice

        guard wanted != (tabToken != nil) else { return }

        guard wanted else {
            releaseTranslationKeys()
            return
        }
        tabToken = TransientHotkeyCenter.tab.push { [weak self, weak view] in
            self?.cycleTranslationTarget(backwards: false, view: view)
        }
        shiftTabToken = TransientHotkeyCenter.shiftTab.push { [weak self, weak view] in
            self?.cycleTranslationTarget(backwards: true, view: view)
        }
    }

    private func releaseTranslationKeys() {
        if let tabToken { TransientHotkeyCenter.tab.remove(tabToken) }
        if let shiftTabToken { TransientHotkeyCenter.shiftTab.remove(shiftTabToken) }
        tabToken = nil
        shiftTabToken = nil
    }

    private func cycleTranslationTarget(backwards: Bool, view: SelectionView?) {
        let languages = TranslationLanguages.shared
        translationTarget = TranslationLanguages.language(
            after: translationTarget ?? languages.destination,
            in: languages.favourites,
            backwards: backwards)
        // The badge names the target, so its width changes with the name —
        // the whole view redraws rather than the badge's old frame.
        view?.translationTarget = translationTarget
        view?.needsDisplay = true
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

    /// Set by the overlay only when an owner can act on it. The panel scanner
    /// leaves it nil, and then a drag always selects — there is nothing under a
    /// full-screen overlay to pan.
    var onPan: ((CGSize) -> Void)?

    /// Driven by the overlay's key monitor rather than by `keyDown`: this panel
    /// never becomes key, so nothing arrives through the responder chain. Same
    /// reason the modifier and Esc handling live in monitors.
    var isSpaceHeld = false

    private var panLast: NSPoint?

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
        if isSpaceHeld {
            panLast = convert(event.locationInWindow, from: nil)
            return
        }
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let last = panLast {
            let point = convert(event.locationInWindow, from: nil)
            onPan?(CGSize(width: point.x - last.x, height: point.y - last.y))
            panLast = point
            return
        }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panLast != nil {
            panLast = nil
            return
        }
        guard let start = startPoint, let current = currentPoint else { onCancelled?(); return }
        let rect = makeRect(from: start, to: current)
        startPoint = nil; currentPoint = nil; needsDisplay = true
        guard rect.width >= 4, rect.height >= 4 else { onCancelled?(); return }
        onCompleted?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape { onCancelled?() } else { super.keyDown(with: event) }
    }

    /// Ends a pan that Space let go of mid-drag.
    func endPan() { panLast = nil }

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
