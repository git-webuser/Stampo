import AppKit

// MARK: - Private CGS cursor API

// CGSSetConnectionProperty с ключом "SetsCursorInBackground" разрешает этому
// процессу управлять курсором даже когда он не является foreground-приложением.
// Используется в barrier, enthrall и других утилитах скрытия курсора.
// Без этого window server передаёт управление чужому процессу при наведении на его окно.
@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(
    _ cid: Int32, _ targetCid: Int32, _ key: CFString, _ value: CFTypeRef)

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

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }) { escMonitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }) { escMonitors.append(m) }

        let cursor = makeScreenshotCrosshairCursor()
        cursor.push()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        cursor.set()
    }

    func cancel() {
        dismiss()
        onCancelled?()
    }

    private func dismiss() {
        guard panel != nil else { return }
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
        NSCursor.pop()
        panel?.orderOut(nil)
        panel = nil
    }

    /// NSRect in view coordinates (AppKit, y=0 bottom-left of screen)
    /// → CGRect in global CG screen coordinates (y=0 top-left of primary display).
    private func nsRectToCGRect(_ rect: NSRect, on screen: NSScreen) -> CGRect {
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? screen.frame.height
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
        addCursorRect(bounds, cursor: makeScreenshotCrosshairCursor())
    }

    override func cursorUpdate(with event: NSEvent) {
        makeScreenshotCrosshairCursor().set()
    }

    override func mouseEntered(with event: NSEvent) {
        makeScreenshotCrosshairCursor().set()
    }

    override func mouseMoved(with event: NSEvent) {
        makeScreenshotCrosshairCursor().set()
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
    private var escMonitors: [Any] = []
    private var hideTimer: Timer?
    private var hideCount = 0

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

        // ESC — глобальный + локальный мониторы
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.cancel() }
        }) { escMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }
            return event
        }) { escMonitors.append(m) }

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        panel.disableCursorRects()

        // Разрешаем управлять курсором в фоне — без этого window server
        // передаёт контроль чужому процессу при наведении на его окно.
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanTrue)

        // Прячем курсор и повторяем каждые ~16 мс через .common — срабатывает
        // и в .default, и в .eventTracking. Каждый вызов учитывается в hideCount,
        // чтобы dismiss() мог точно восстановить баланс.
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

    /// Единственное место где вызывается CGDisplayHideCursor — счётчик всегда точный.
    private func hideCursor() {
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    private func dismiss() {
        guard panel != nil else { return }
        hideTimer?.invalidate()
        hideTimer = nil
        let cid = _CGSDefaultConnection()
        // ShowCursor пока SetsCursorInBackground ещё true — иначе другой процесс
        // (владелец окна B, ставшего активным) успевает перехватить управление.
        for _ in 0 ..< hideCount { CGDisplayShowCursor(CGMainDisplayID()) }
        hideCount = 0
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString,
                                 kCFBooleanFalse)
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        // Курсор восстанавливаем ПОСЛЕ orderOut: AppKit обрабатывает смену активного
        // окна во время orderOut и может перезаписать cursor-состояние, установленное
        // до этого. Синхронный вызов ловит большинство случаев, асинхронный — случаи
        // когда AppKit завершает курсор-менеджмент уже после возврата из orderOut
        // (например при переходе фокуса в окно другого приложения).
        NSCursor.arrow.set()
        DispatchQueue.main.async {
            NSCursor.arrow.set()
        }
    }
}

// MARK: - WindowPickerView

private final class WindowPickerView: NSView {
    var targetScreen: NSScreen?
    var onSelected: ((CGWindowID) -> Void)?
    var onCancelled: (() -> Void)?
    var onNeedsHide: (() -> Void)?   // вызывается при смене окна — оверлей учитывает в счётчике

    private var hoveredWindowID: CGWindowID?
    private var hoveredViewRect: CGRect?

    // Software cursor: рисуем курсор сами — аппаратный скрыт через CGDisplayHideCursor
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

    // Не даём AppKit трогать курсор
    override func resetCursorRects() {}
    override func cursorUpdate(with event: NSEvent) {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        addSubview(softCursor)
        // Начальная позиция по текущему положению мыши
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
        // Смещаем изображение так, чтобы его hotspot совпал с позицией мыши.
        // NSView: y=0 снизу. Hotspot (hx, hy) от верхнего-левого угла изображения:
        //   origin.x = viewPt.x - hx
        //   origin.y = viewPt.y - height + hy
        let hs = _wpcCursor.hotSpot
        let h  = softCursor.frame.height
        let origin = NSPoint(x: viewPt.x - hs.x, y: viewPt.y - h + hs.y)
        // Отключаем implicit CALayer-анимацию: без этого wantsLayer-вью
        // плавно «едет» между позициями (~0.25s), создавая задвоение курсора.
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
        if event.keyCode == 53 { onCancelled?() } else { super.keyDown(with: event) }
    }

    private func updateHover(at viewPt: NSPoint) {
        guard let screen = targetScreen else { return }
        let result = windowAtViewPoint(viewPt, screen: screen)
        if result?.0 != hoveredWindowID {
            onNeedsHide?()   // смена окна → оверлей прячет курсор и учитывает в счётчике
        }
        hoveredWindowID = result?.0
        hoveredViewRect = result?.1
        needsDisplay = true
    }

    private func windowAtViewPoint(_ viewPt: NSPoint, screen: NSScreen) -> (CGWindowID, CGRect)? {
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? screen.frame.height

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
