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
    private var hideTimer: Timer?
    private var hideCount = 0
    /// true between start() and dismiss() — guards hideCursor() from
    /// firing after the overlay is gone (stale timer tick, late onNeedsHide).
    private var isActive = false

    deinit {
        // Defensive: if dismiss() was never called (e.g. controller torn down
        // mid-session) restore the exact number of hides we issued.
        resetCursorState()
    }

    func start(on screen: NSScreen) {
        targetScreen = screen
        let frame = screen.frame

        let panel = makeOverlayPanel(frame: frame)
        let view = WindowPickerView(frame: NSRect(origin: .zero, size: frame.size))
        view.targetScreen = screen
        view.onSelected = { [weak self] windowID in
            self?.dismiss()
            self?.onSelected?(windowID)
        }
        view.onCancelled = { [weak self] in
            self?.dismiss()
            self?.onCancelled?()
        }
        view.onNeedsHide = { [weak self] in self?.hideCursor() }
        panel.contentView = view
        self.panel = panel

        installEscMonitors(into: &escMonitors) { [weak self] in self?.cancel() }

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        panel.disableCursorRects()

        // Allow cursor control in the background so the window server doesn't
        // hand cursor ownership to another process when hovering over its window.
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanTrue)

        // Hide cursor repeatedly on the common run-loop mode so it fires during
        // both default and event-tracking modes. hideCount tracks every call so
        // dismiss() can restore the exact balance via CGDisplayShowCursor.
        isActive = true
        hideTimer?.invalidate()
        hideTimer = nil
        hideCount = 0
        hideCursor()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.hideCursor()
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    func cancel() {
        dismiss()
        onCancelled?()
    }

    /// Single authoritative call site for CGDisplayHideCursor — keeps the
    /// counter accurate so dismiss() can restore the exact show/hide balance.
    private func hideCursor() {
        guard isActive else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Resets any pending cursor-hide state accumulated since the last start().
    /// Safe to call even when the overlay is not active (becomes a no-op).
    /// Called defensively in finishCountdown / captureNowFromCountdown in case
    /// a stale hideCursor() managed to fire after dismiss().
    func resetCursorState() {
        isActive = false
        hideTimer?.invalidate()
        hideTimer = nil
        if hideCount > 0 {
            let cid = _CGSDefaultConnection()
            for _ in 0 ..< hideCount { CGDisplayShowCursor(CGMainDisplayID()) }
            hideCount = 0
            CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                     kCFBooleanFalse)
        }
        NSCursor.arrow.set()
    }

    private func dismiss() {
        guard panel != nil else { return }
        // Mark inactive first so any late hideCursor() calls (stale timer tick,
        // onNeedsHide dispatched before orderOut) are ignored.
        isActive = false
        hideTimer?.invalidate()
        hideTimer = nil
        let cid = _CGSDefaultConnection()
        // ShowCursor while SetsCursorInBackground is still true — otherwise the
        // newly-activated process could grab cursor control before we release it.
        for _ in 0 ..< hideCount { CGDisplayShowCursor(CGMainDisplayID()) }
        hideCount = 0
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanFalse)
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        // Restore cursor AFTER orderOut: AppKit processes the active-window
        // change during orderOut and can overwrite any cursor state set before
        // it. The async call catches cases where AppKit finishes cursor management
        // after returning from orderOut (e.g. focus shift to another app).
        NSCursor.arrow.set()
        DispatchQueue.main.async { NSCursor.arrow.set() }
    }
}

// MARK: - WindowPickerView

private final class WindowPickerView: NSView {
    var targetScreen: NSScreen?
    var onSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?
    /// Called on every hover-window change so the overlay can increment the hide counter.
    var onNeedsHide: (() -> Void)?

    private var hoveredWindowID: CGWindowID?
    private var hoveredViewRect: CGRect?

    // Software cursor: we draw the cursor ourselves since the hardware cursor
    // is hidden via CGDisplayHideCursor.
    private let _wpcCursor: NSCursor = makeWindowCaptureCursor()
    private lazy var softCursor: NSImageView = {
        let img  = _wpcCursor.image
        let view = NSImageView(frame: NSRect(origin: .zero, size: img.size))
        view.image        = img
        view.imageScaling = .scaleNone
        view.wantsLayer   = true
        return view
    }()

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // Prevent AppKit from overriding the cursor.
    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        addSubview(softCursor)
        // Position the software cursor at the current mouse location.
        if let win = window {
            let screenPt = NSEvent.mouseLocation
            let winPt    = win.convertPoint(fromScreen: screenPt)
            let viewPt   = convert(winPt, from: nil)
            placeSoftCursor(at: viewPt)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func placeSoftCursor(at viewPt: NSPoint) {
        // Offset the image so its hotspot aligns with the pointer position.
        // NSView: y=0 at the bottom. Hotspot (hx, hy) from image top-left:
        //   origin.x = viewPt.x - hx
        //   origin.y = viewPt.y - height + hy
        let hs = _wpcCursor.hotSpot
        let h  = softCursor.frame.height
        let origin = NSPoint(x: viewPt.x - hs.x, y: viewPt.y - h + hs.y)
        // Disable implicit CALayer animation; without this the wantsLayer view
        // glides between positions (~0.25 s), causing a ghosted double-cursor.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        softCursor.frame.origin = origin
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        placeSoftCursor(at: pt)
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
        if result?.0 != hoveredWindowID {
            // Window changed — caller increments hide counter.
            onNeedsHide?()
        }
        hoveredWindowID = result?.0
        hoveredViewRect = result?.1
        needsDisplay = true
    }

    private func windowAtViewPoint(_ viewPt: NSPoint, screen: NSScreen) -> (CGWindowID, CGRect)? {
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? screen.frame.height

        // View → global AppKit → global CG coordinates
        let cgPt = CGPoint(
            x: viewPt.x + screen.frame.minX,
            y: primaryH - (viewPt.y + screen.frame.minY)
        )

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

            // CG rect → view coordinates
            let vx = cgRect.minX - screen.frame.minX
            let vy = primaryH - cgRect.maxY - screen.frame.minY
            return (CGWindowID(num), CGRect(x: vx, y: vy, width: ww, height: wh))
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
