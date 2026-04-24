import AppKit

// MARK: - SelectionOverlay

/// Full-screen drag-to-select overlay.
/// Calls `onSelected` with the selected CGRect in global CG coordinates
/// (origin top-left of primary display — compatible with `screencapture -R`).
final class SelectionOverlay {
    var onSelected: ((CGRect) -> Void)?
    var onCancelled: (() -> Void)?

    private var panel: NSPanel?
    private var targetScreen: NSScreen?
    private var escMonitors: [Any] = []

    private var selectionCursor: NSCursor?
    private var cursorPushed = false
    private var cursorTimer: Timer?
    private var cursorObservers: [NSObjectProtocol] = []

    deinit {
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

        installEscMonitors(into: &escMonitors) { [weak self] in self?.cancel() }

        cursor.push()
        cursorPushed = true

        // Allow cursor control even when our process is not the active app —
        // without this NSCursor.set() has no effect while another app is
        // frontmost (e.g. text field I-beam from the underlying app overrides us).
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanTrue)

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
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanFalse)
        NSCursor.arrow.set()
        DispatchQueue.main.async { NSCursor.arrow.set() }
    }

    private func dismiss() {
        guard panel != nil else { return }

        removeCursorMaintenance()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        selectionCursor = nil

        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanFalse)

        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()

        panel?.orderOut(nil)
        panel = nil

        NSCursor.arrow.set()
        DispatchQueue.main.async { NSCursor.arrow.set() }
    }

    // MARK: - Cursor maintenance

    private func installCursorMaintenance(panel: NSPanel) {
        // Space change: re-front overlay after transition animation (150 ms).
        let spaceObs = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak panel] in
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
            guard let self, self.cursorPushed else { return }
            self.selectionCursor?.set()
        }

        cursorObservers = [spaceObs, activateObs]

        // 30 fps timer covers the stationary case where macOS resets the cursor
        // without a mouse-moved event (e.g. I-beam override from underlying text input).
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.cursorPushed else { return }
            self.selectionCursor?.set()
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

        guard let start = startPoint, let current = currentPoint else { return }
        let sel = makeRect(from: start, to: current)
        guard sel.width > 0, sel.height > 0 else { return }

        ctx.clear(sel)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addRect(sel.insetBy(dx: 0.75, dy: 0.75))
        ctx.strokePath()
    }
}
