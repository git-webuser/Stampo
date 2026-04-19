import AppKit

// MARK: - WindowPickerOverlay

/// Full-screen window-highlight overlay.
/// Hover over a window to highlight it; click to select.
/// Calls `onSelected` with the CGWindowID of the chosen window.
final class WindowPickerOverlay {
    var onSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?

    private var panel: NSPanel?
    private var targetScreen: NSScreen?
    private var escMonitors: [Any] = []
    private var cursorObservers: [NSObjectProtocol] = []
    private var cursorTimer: Timer?
    /// The pushed cursor — kept so observers can re-apply it after focus/space changes.
    private var wpcCursor: NSCursor?
    /// True while the cursor has been pushed via NSCursor.push() — guards
    /// against a double-pop if both dismiss() and resetCursorState() fire.
    private var cursorPushed = false

    deinit {
        resetCursorState()
    }

    func start(on screen: NSScreen) {
        targetScreen = screen
        let frame = screen.frame

        let panel = makeOverlayPanel(frame: frame)
        let wpcCursor = makeWindowCaptureCursor()

        let view = WindowPickerView(frame: NSRect(origin: .zero, size: frame.size))
        view.targetScreen = screen
        view.wpcCursor = wpcCursor          // view uses same cursor instance for cursor-rects
        view.onSelected = { [weak self] windowID in
            self?.dismiss()
            self?.onSelected?(windowID)
        }
        view.onCancelled = { [weak self] in
            self?.dismiss()
            self?.onCancelled?()
        }
        panel.contentView = view
        self.panel = panel

        installEscMonitors(into: &escMonitors) { [weak self] in self?.cancel() }

        // Push cursor before the window becomes key (mirrors SelectionOverlay pattern).
        // The view's resetCursorRects / cursorUpdate / mouseMoved maintain it afterwards.
        wpcCursor.push()
        self.wpcCursor = wpcCursor
        cursorPushed = true

        // Allow cursor control even when our process is not the active app —
        // without this, NSCursor.set() has no effect while another app is
        // frontmost (e.g. after a Space switch that activates a different app).
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanTrue)

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        // Set AFTER makeKeyAndOrderFront so AppKit's window-activation cursor reset
        // is overridden (same ordering as SelectionOverlay).
        wpcCursor.set()

        installCursorObservers(panel: panel)
    }

    func cancel() {
        dismiss()
        onCancelled?()
    }

    /// Resets cursor state. Safe to call when already inactive (e.g. if
    /// dismiss() was already called). Called defensively from
    /// finishCountdown / captureNowFromCountdown in NotchPanelCapture.
    func resetCursorState() {
        removeCursorObservers()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        wpcCursor = nil
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanFalse)
        NSCursor.arrow.set()
        DispatchQueue.main.async { NSCursor.arrow.set() }
    }

    private func dismiss() {
        guard panel != nil else { return }
        removeCursorObservers()
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        wpcCursor = nil
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

    // MARK: - Cursor observers

    /// Installs notification observers that re-apply the window-capture cursor
    /// on state transitions that can reset it (Space switch, app activation).
    /// Within-overlay cursor maintenance is handled by the view's cursor-rect
    /// methods (resetCursorRects / cursorUpdate / mouseEntered / mouseMoved).
    private func installCursorObservers(panel: NSPanel) {
        // MARK: Event-based approach (active)
        // Handles the two OS-level events that reset cursor in State 1:
        // space switches and app-activation changes.

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
                self.wpcCursor?.set()
            }
        }

        // App-activation: re-apply after our app regains active status.
        let activateObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.cursorPushed else { return }
            self.wpcCursor?.set()
        }

        cursorObservers = [spaceObs, activateObs]

        // Timer-based gap-filler: macOS has no "cursor was reset" event, so
        // there is no way to react to a reset that happens while the cursor is
        // stationary (e.g. Space switch with no subsequent mouse movement).
        // The event observers above cover resets that coincide with movement;
        // this 30 fps timer covers the stationary case. Both run together.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.cursorPushed else { return }
            self.wpcCursor?.set()
        }
        RunLoop.main.add(t, forMode: .common)
        cursorTimer = t
    }

    private func removeCursorObservers() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorObservers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        cursorObservers.removeAll()
    }
}

// MARK: - WindowPickerView

private final class WindowPickerView: NSView {
    var targetScreen: NSScreen?
    var wpcCursor: NSCursor = .arrow      // set by WindowPickerOverlay before display
    var onSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?

    private var hoveredWindowID: CGWindowID?
    private var hoveredViewRect: CGRect?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
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

    // Cursor maintenance — mirrors SelectionView's pattern exactly.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: wpcCursor)
    }
    override func cursorUpdate(with event: NSEvent) {
        wpcCursor.set()
    }
    override func mouseEntered(with event: NSEvent) {
        wpcCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        wpcCursor.set()
        let pt = convert(event.locationInWindow, from: nil)
        updateHover(at: pt)
    }

    override func mouseDown(with event: NSEvent) {
        if let id = hoveredWindowID { onSelected?(id) } else { onCancelled?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape { onCancelled?() } else { super.keyDown(with: event) }
    }

    private func updateHover(at viewPt: NSPoint) {
        guard let screen = targetScreen else { return }
        let result = windowAtViewPoint(viewPt, screen: screen)
        hoveredWindowID = result?.0
        hoveredViewRect = result?.1
        needsDisplay = true
    }

    private func windowAtViewPoint(_ viewPt: NSPoint, screen: NSScreen) -> (CGWindowID, CGRect)? {
        let cgPt = viewPointToCGPoint(viewPt, screen: screen)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let isOn = info[kCGWindowIsOnscreen as String] as? Bool, isOn else { continue }
            guard let num = info[kCGWindowNumber as String] as? UInt32 else { continue }
            guard let bd = info[kCGWindowBounds as String] as? [String: Any] else { continue }

            let wx = (bd["X"] as? CGFloat) ?? 0
            let wy = (bd["Y"] as? CGFloat) ?? 0
            let ww = (bd["Width"] as? CGFloat) ?? 0
            let wh = (bd["Height"] as? CGFloat) ?? 0
            guard ww >= 60, wh >= 60 else { continue }

            let cgRect = CGRect(x: wx, y: wy, width: ww, height: wh)
            guard cgRect.contains(cgPt) else { continue }

            return (CGWindowID(num), cgRectToViewRect(cgRect, screen: screen))
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.fill(bounds)

        guard let rect = hoveredViewRect, rect.width > 0, rect.height > 0 else { return }

        ctx.clear(rect)

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.0)
        ctx.addRect(rect.insetBy(dx: 1, dy: 1))
        ctx.strokePath()
    }
}
