import AppKit
import ScreenCaptureKit

// MARK: - ColorSampler

@MainActor
final class ColorSampler {

    var onColorChanged: ((NSColor, NSPoint) -> Void)?
    var onConfirmed: ((NSColor) -> Void)?
    var onCancelled: (() -> Void)?
    var format: HUDColorFormat = .hex

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var rightClickMonitor: Any?
    private var leftClickMonitor: Any?
    private var escMonitor: Any?

    private var lastColor: NSColor = .black
    private var isStopped = false

    private var captureInFlight = false
    private var pendingPosition: NSPoint? = nil

    private let cursorOverlay = CursorOverlay()

    /// Одноразовый запуск. После stop() создавай новый экземпляр.
    func start() {
        guard !isStopped else { return }
        // Движение через FullscreenTrackingView — надёжнее глобального монитора
        cursorOverlay.onMouseMoved = { [weak self] pos in
            guard let self else { return }
            Task { @MainActor in
                self.scheduleCapture(at: pos)
            }
        }

        cursorOverlay.show()
        installMonitors()
        scheduleCapture(at: NSEvent.mouseLocation)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        cursorOverlay.onMouseMoved = nil
        cursorOverlay.hide()
        removeMonitors()
    }

    private func installMonitors() {
        // Глобальный монитор для drag (FullscreenTrackingView не получает drag-события)
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDragged
        ) { [weak self] _ in
            guard let self else { return }
            let pos = NSEvent.mouseLocation
            DispatchQueue.main.async { self.cursorOverlay.move(to: pos) }
            Task { @MainActor in self.scheduleCapture(at: pos) }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return nil }
            Task { @MainActor in self.handleLocalEvent(event) }
            return nil
        }

        // Используем локальный монитор — глобальный не получает события
        // собственного приложения когда оно является key window (FullscreenCursorWindow).
        leftClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseUp
        ) { [weak self] event in
            guard let self else { return event }
            DispatchQueue.main.async {
                guard !self.isStopped else { return }
                self.confirm()
            }
            return event
        }

        rightClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .rightMouseDown
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isStopped else { return }
                self.cancel()
            }
        }

        escMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return }
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard !self.isStopped else { return }
                self.cancel()
            }
        }
    }

    private func removeMonitors() {
        [mouseMonitor, localMouseMonitor, leftClickMonitor, rightClickMonitor, escMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        mouseMonitor = nil
        localMouseMonitor = nil
        leftClickMonitor = nil
        rightClickMonitor = nil
        escMonitor = nil
    }

    private func handleLocalEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown: cancel()
        case .keyDown: handleKeyDown(event)
        default: break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()
        case 3:
            let all = HUDColorFormat.allCases
            if let idx = all.firstIndex(of: format) {
                format = all[(idx + 1) % all.count]
                onColorChanged?(lastColor, NSEvent.mouseLocation)
            }
        default: break
        }
    }



    private func confirm() {
        let color = lastColor
        stop()
        onConfirmed?(color)
    }

    private func cancel() {
        stop()
        onCancelled?()
    }

    private func scheduleCapture(at position: NSPoint) {
        guard !isStopped else { return }
        if captureInFlight {
            pendingPosition = position
            return
        }
        captureInFlight = true
        Task { [weak self] in
            guard let self else { return }
            // Ищем дисплей и получаем SCShareableContent на MainActor
            guard let content = await self.shareableContent() else {
                self.captureInFlight = false
                return
            }
            // Определяем нужный дисплей по NSScreen (оба на MainActor)
            let primaryH = NSScreen.screens
                .first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height ?? 0
            guard let display = content.displays.first(where: { d in
                let nsFrame = CGRect(x: d.frame.minX, y: primaryH - d.frame.maxY,
                                     width: d.frame.width, height: d.frame.height)
                return nsFrame.contains(position)
            }) else {
                self.captureInFlight = false
                return
            }
            // Передаём display в nonisolated метод — захват экрана вне MainActor
            let color = await self.pixelColor(at: position, display: display)
            guard !self.isStopped else { return }
            if let color {
                self.lastColor = color
                self.cursorOverlay.updateColor(color)
                self.onColorChanged?(color, position)
            }
            self.captureInFlight = false
            if let pending = self.pendingPosition {
                self.pendingPosition = nil
                self.scheduleCapture(at: pending)
            }
        }
    }

    // MARK: - SCShareableContent cache (5s TTL — дисплеи меняются редко)

    private var cachedContent: SCShareableContent?
    private var cachedContentExpiry: Date = .distantPast

    private func shareableContent() async -> SCShareableContent? {
        if let c = cachedContent, Date() < cachedContentExpiry { return c }
        let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = fresh
        cachedContentExpiry = Date().addingTimeInterval(5)
        return fresh
    }

    // nonisolated — вызывается из Task.detached, не нужен MainActor
    private nonisolated func pixelColor(at point: NSPoint, display: SCDisplay) async -> NSColor? {
        // Захватываем весь дисплей с минимальным разрешением — 1×1 логический пиксель
        // нельзя, SCKit требует целый дисплей. Зато кэшируем SCShareableContent
        // и не пересоздаём filter/config на каждый тик.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width       = Int(display.width)
        config.height      = Int(display.height)
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }

        // Координатная математика через NSScreen (AppKit, origin bottom-left)
        // и SCDisplay.frame (Quartz, origin top-left).
        // displayID объявлен в NotchPanelController как NSScreen extension.
        let screens = await MainActor.run { NSScreen.screens }
        guard let screen = screens.first(where: { $0.displayID == display.displayID }) else { return nil }

        let screenFrame = screen.frame                   // AppKit
        let localX = point.x - screenFrame.minX
        let localY = point.y - screenFrame.minY          // от нижнего края вверх

        // SCDisplay.frame — Quartz. Пиксельные координаты в capture buffer:
        let scaleX = CGFloat(display.width)  / display.frame.width
        let scaleY = CGFloat(display.height) / display.frame.height
        let px = Int(localX * scaleX)
        let py = Int((screenFrame.height - localY - 1) * scaleY)  // AppKit Y → buffer Y

        let imgW = cgImage.width, imgH = cgImage.height
        guard imgW > 0, imgH > 0 else { return nil }
        let cx = max(0, min(px, imgW - 1))
        let cy = max(0, min(py, imgH - 1))

        var pixelData: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixelData, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: -cx, y: -(imgH - cy - 1), width: imgW, height: imgH))

        return NSColor(
            srgbRed: CGFloat(pixelData[0]) / 255,
            green:   CGFloat(pixelData[1]) / 255,
            blue:    CGFloat(pixelData[2]) / 255,
            alpha:   CGFloat(pixelData[3]) / 255
        )
    }
}
