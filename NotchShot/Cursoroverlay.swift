import AppKit
import SwiftUI

// MARK: - Screenshot-style crosshair cursor

/// Exact replica of the system screencapture crosshair cursor.
/// Geometry and layer order sourced from Apple's public Figma component library.
func makeScreenshotCrosshairCursor(contrastAgainst _: NSColor? = nil) -> NSCursor {
    let size: CGFloat = 25
    let cx = size / 2
    let cy = size / 2

    let armGap:      CGFloat = 0.5
    let armEnd:      CGFloat = 11.5
    let armCore:     CGFloat = 1.0
    let haloWidth:   CGFloat = 3.0
    let ringFillR:   CGFloat = 5.5
    let ringStrokeR: CGFloat = 5.9
    let ringStrokeW: CGFloat = 0.8

    let ringFillColor   = NSColor(white: 0.0, alpha: 0.10)
    let ringStrokeColor = NSColor(white: 0.0, alpha: 0.25)
    let haloColor       = NSColor(white: 1.0, alpha: 0.25)
    let armColor        = NSColor(white: 0.0, alpha: 0.85)

    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return .crosshair }

    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 0, y: -size)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let dirs: [(CGFloat, CGFloat)] = [(0,1),(0,-1),(1,0),(-1,0)]

    func strokeArms(color: NSColor, width: CGFloat, from: CGFloat, to: CGFloat) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        for (dx, dy) in dirs {
            ctx.move(to:    CGPoint(x: cx + dx * from, y: cy + dy * from))
            ctx.addLine(to: CGPoint(x: cx + dx * to,   y: cy + dy * to))
        }
        ctx.strokePath()
    }

    // 1. Ring fill
    ctx.setFillColor(ringFillColor.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx-ringFillR, y: cy-ringFillR,
                               width: ringFillR*2, height: ringFillR*2))
    // 2. Ring stroke
    ctx.setStrokeColor(ringStrokeColor.cgColor)
    ctx.setLineWidth(ringStrokeW)
    ctx.strokeEllipse(in: CGRect(x: cx-ringStrokeR, y: cy-ringStrokeR,
                                 width: ringStrokeR*2, height: ringStrokeR*2))
    // 3. Halo — full length, drawn on top of the ring
    strokeArms(color: haloColor, width: haloWidth, from: 0, to: armEnd + armGap)
    // 4. Arms on top of the halo
    strokeArms(color: armColor, width: armCore, from: armGap, to: armEnd)

    return NSCursor(image: image, hotSpot: NSPoint(x: cx, y: cy))
}

// MARK: - Window-capture cursor (system screenshotwindow)

/// Loads the system "Camera for capturing a window and menu" cursor from HIServices.
/// Uses cursor.pdf + hotspot from info.plist — the same assets that screencapture uses.
func makeWindowCaptureCursor() -> NSCursor {
    let dir = "/System/Library/Frameworks/ApplicationServices.framework" +
              "/Versions/A/Frameworks/HIServices.framework" +
              "/Versions/A/Resources/cursors/screenshotwindow"

    // Hotspot from plist; fall back to known values.
    var hotX: CGFloat = 14
    var hotY: CGFloat = 11
    if let info = NSDictionary(contentsOfFile: dir + "/info.plist") {
        hotX = (info["hotx"] as? CGFloat) ?? hotX
        hotY = (info["hoty"] as? CGFloat) ?? hotY
    }

    guard let image = NSImage(contentsOfFile: dir + "/cursor.pdf") else {
        return .arrow
    }

    return NSCursor(image: image, hotSpot: NSPoint(x: hotX, y: hotY))
}


// MARK: - FullscreenTrackingView

private final class FullscreenTrackingView: NSView {

    var onMouseMoved: ((NSPoint) -> Void)?

    var screenshotCursor: NSCursor = makeScreenshotCrosshairCursor()

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

    func applyCursor() {
        screenshotCursor.set()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: screenshotCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        screenshotCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        screenshotCursor.set()
        guard let win = window else { return }
        let pos = NSPoint(
            x: event.locationInWindow.x + win.frame.minX,
            y: event.locationInWindow.y + win.frame.minY
        )
        onMouseMoved?(pos)
    }

    override func mouseEntered(with event: NSEvent) {
        screenshotCursor.set()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - FullscreenCursorWindow

private final class FullscreenCursorWindow: NSPanel {
    override var canBecomeKey: Bool  { true  }
    override var canBecomeMain: Bool { false }
}

// MARK: - CursorOverlay

@MainActor
final class CursorOverlay {

    private var fullscreenWindow: FullscreenCursorWindow?
    private var currentColor: NSColor?
    private var currentCursor: NSCursor = makeScreenshotCrosshairCursor()

    var onMouseMoved: ((NSPoint) -> Void)?

    // MARK: - Public API

    static func hideCursorAfterMenuCloses() {
        nonisolated(unsafe) var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            if let t = token {
                NotificationCenter.default.removeObserver(t)
                token = nil
            }

            makeScreenshotCrosshairCursor().set()
        }
    }

    func show() {
        let cursorPos = NSEvent.mouseLocation
        guard let screen =
            NSScreen.screens.first(where: { $0.frame.contains(cursorPos) }) ??
            NSScreen.main ??
            NSScreen.screens.first
        else { return }

        ensureFullscreenWindow(on: screen)
        installGlobalMouseMonitor()

        guard let fw = fullscreenWindow else { return }
        fw.orderFrontRegardless()
        fw.makeKey()

        applyCurrentCursor()
    }

    func move(to position: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(position) }) else {
            applyCurrentCursor()
            return
        }

        ensureFullscreenWindow(on: screen)
        applyCurrentCursor()
    }

    func updateColor(_ color: NSColor?) {
        currentColor = color
        currentCursor = makeScreenshotCrosshairCursor(contrastAgainst: color)
        applyCurrentCursor()
    }

    func hide() {
        fullscreenWindow?.orderOut(nil)
        removeGlobalMouseMonitor()
        NSCursor.arrow.set()
    }

    deinit {
        // Defensive cleanup: callers normally invoke hide() explicitly, but if the
        // overlay is deallocated without it (early release of its owner), we still
        // want the global monitor and space observer unregistered so they can't
        // fire into a dangling instance.
        MainActor.assumeIsolated {
            fullscreenWindow?.orderOut(nil)
            removeGlobalMouseMonitor()
        }
    }

    // MARK: - Private

    private var globalMouseMonitor: Any?
    private var spaceObserver: Any?

    private func installGlobalMouseMonitor() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            let pos = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self.move(to: pos)
                self.onMouseMoved?(pos)
            }
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let fw = self.fullscreenWindow else { return }
                fw.orderFrontRegardless()
                fw.makeKey()
                self.applyCurrentCursor()
            }
        }
    }

    private func removeGlobalMouseMonitor() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let o = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            spaceObserver = nil
        }
    }

    private func applyCurrentCursor() {
        if let trackingView = fullscreenWindow?.contentView as? FullscreenTrackingView {
            trackingView.screenshotCursor = currentCursor
            trackingView.applyCursor()
        } else {
            currentCursor.set()
        }
    }

    private func ensureFullscreenWindow(on screen: NSScreen) {
        if let fw = fullscreenWindow {
            fw.setFrame(screen.frame, display: false)

            if let trackingView = fw.contentView as? FullscreenTrackingView {
                trackingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            }

            return
        }

        let fw = FullscreenCursorWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        fw.isFloatingPanel = true
        fw.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 2)
        fw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        fw.isOpaque = false
        fw.backgroundColor = .clear
        fw.hasShadow = false
        fw.hidesOnDeactivate = false
        fw.ignoresMouseEvents = false
        fw.appearance = NSAppearance(named: .darkAqua)

        let trackingView = FullscreenTrackingView(frame: CGRect(origin: .zero, size: screen.frame.size))
        trackingView.autoresizingMask = [.width, .height]
        trackingView.wantsLayer = true
        trackingView.layer?.backgroundColor = CGColor.clear
        trackingView.screenshotCursor = currentCursor
        trackingView.onMouseMoved = { [weak self] pos in
            guard let self else { return }
            self.move(to: pos)
            self.onMouseMoved?(pos)
        }

        fw.contentView = trackingView
        self.fullscreenWindow = fw
    }

}
