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

    func start(on screen: NSScreen) {
        targetScreen = screen
        let frame = screen.frame

        let panel = makeOverlayPanel(frame: frame)
        let view = SelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.onCompleted = { [weak self] nsRect in
            guard let self else { return }
            let cgRect = self.nsRectToCGRect(nsRect, on: screen)
            self.dismiss()
            self.onSelected?(cgRect)
        }
        view.onCancelled = { [weak self] in
            self?.dismiss()
            self?.onCancelled?()
        }
        panel.contentView = view
        self.panel = panel

        NSCursor.crosshair.push()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        dismiss()
        onCancelled?()
    }

    private func dismiss() {
        NSCursor.pop()
        panel?.orderOut(nil)
        panel = nil
    }

    /// NSRect in view coordinates (AppKit, y=0 bottom-left of screen)
    /// → CGRect in global CG screen coordinates (y=0 top-left of primary display).
    private func nsRectToCGRect(_ rect: NSRect, on screen: NSScreen) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(
            x: rect.minX + screen.frame.minX,
            y: primaryH - (rect.maxY + screen.frame.minY),
            width: rect.width,
            height: rect.height
        )
    }
}

// MARK: - SelectionView

private final class SelectionView: NSView {
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
        if event.keyCode == 53 { onCancelled?() } else { super.keyDown(with: event) }
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

// MARK: - WindowPickerOverlay

/// Full-screen window-highlight overlay.
/// Hover over a window to highlight it; click to select.
/// Calls `onSelected` with the CGWindowID of the chosen window.
final class WindowPickerOverlay {
    var onSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?

    private var panel: NSPanel?
    private var targetScreen: NSScreen?

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
        panel.contentView = view
        self.panel = panel

        NSCursor.pointingHand.push()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        dismiss()
        onCancelled?()
    }

    private func dismiss() {
        NSCursor.pop()
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - WindowPickerView

private final class WindowPickerView: NSView {
    var targetScreen: NSScreen?
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
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if let id = hoveredWindowID { onSelected?(id) } else { onCancelled?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancelled?() } else { super.keyDown(with: event) }
    }

    private func updateHover(at viewPt: NSPoint) {
        guard let screen = targetScreen else { return }
        let result = windowAtViewPoint(viewPt, screen: screen)
        hoveredWindowID = result?.0
        hoveredViewRect = result?.1
        needsDisplay = true
    }

    private func windowAtViewPoint(_ viewPt: NSPoint, screen: NSScreen) -> (CGWindowID, CGRect)? {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height

        // View → global AppKit → global CG
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

// MARK: - Shared helpers

private func makeOverlayPanel(frame: NSRect) -> NSPanel {
    let panel = NSPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.appearance = NSAppearance(named: .darkAqua)
    return panel
}
