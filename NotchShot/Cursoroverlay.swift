import AppKit
import SwiftUI

// MARK: - Screenshot-style crosshair cursor

/// Точная копия системного screencapture crosshair.
/// Геометрия и порядок слоёв из публичной библиотеки компонентов Apple в Figma.
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
    // 3. Halo — полная длина, поверх кольца
    strokeArms(color: haloColor, width: haloWidth, from: 0, to: armEnd + armGap)
    // 4. Arms поверх гало
    strokeArms(color: armColor, width: armCore, from: armGap, to: armEnd)

    return NSCursor(image: image, hotSpot: NSPoint(x: cx, y: cy))
}

// MARK: - Window-capture cursor (arrow + camera badge)

/// Стрелка macOS + белый закруглённый бейдж с иконкой camera.fill внизу справа.
/// Стиль как у системного drag-курсора (стрелка + облако), но вместо облака — камера.
func makeWindowCaptureCursor() -> NSCursor {
    let arrowBase = NSCursor.arrow.image
    let baseSize  = arrowBase.size          // ~17×22 pt logical

    // Размеры бейджа
    let badgeSize: CGFloat  = 14            // белый прямоугольник
    let iconSize: CGFloat   = 9             // camera.fill внутри
    let cornerR: CGFloat    = 3
    let badgeOffset: CGFloat = 2            // сдвиг от кончика стрелки

    let canvasW = baseSize.width  + badgeSize * 0.7
    let canvasH = baseSize.height + badgeSize * 0.7
    let canvasSize = NSSize(width: canvasW, height: canvasH)

    let image = NSImage(size: canvasSize)
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        return NSCursor(image: image, hotSpot: .zero)
    }

    // Стрелка — верхний левый угол
    arrowBase.draw(
        in: NSRect(x: 0, y: canvasH - baseSize.height,
                   width: baseSize.width, height: baseSize.height),
        from: .zero, operation: .sourceOver, fraction: 1.0
    )

    // Позиция бейджа: правый нижний угол холста
    let bx = canvasW - badgeSize - badgeOffset
    let by = badgeOffset
    let badgeRect = CGRect(x: bx, y: by, width: badgeSize, height: badgeSize)

    // Тень под бейджем
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2,
                  color: NSColor(white: 0, alpha: 0.35).cgColor)

    // Белый закруглённый прямоугольник (как облако у drag-курсора)
    let path = CGPath(roundedRect: badgeRect, cornerWidth: cornerR, cornerHeight: cornerR,
                      transform: nil)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // Иконка camera.fill внутри бейджа
    if let sym = NSImage(systemSymbolName: "camera.fill",
                         accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        if let icon = sym.withSymbolConfiguration(cfg) {
            let ix = bx + (badgeSize - iconSize) / 2
            let iy = by + (badgeSize - iconSize) / 2
            icon.draw(in: NSRect(x: ix, y: iy, width: iconSize, height: iconSize))
        }
    }

    return NSCursor(image: image, hotSpot: NSPoint(x: 0, y: 0))
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
        let screen =
            NSScreen.screens.first(where: { $0.frame.contains(cursorPos) }) ??
            NSScreen.main ??
            NSScreen.screens.first ?? NSScreen()

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
