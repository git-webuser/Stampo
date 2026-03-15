import AppKit
import ScreenCaptureKit

// MARK: - ColorSampler

@MainActor
final class ColorSampler {

    var onColorChanged: ((NSColor, NSPoint, MagnifierData?) -> Void)?
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
                onColorChanged?(lastColor, NSEvent.mouseLocation, nil)
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
        Task { @MainActor in
            if let result = await pixelColor(at: position) {
                guard !self.isStopped else { return }
                let magnifier = self.buildMagnifier(from: result.image, centerPx: result.centerPx)
                self.lastColor = result.color
                self.cursorOverlay.updateColor(result.color)
                self.onColorChanged?(result.color, position, magnifier)
            }
            self.captureInFlight = false
            if let pending = self.pendingPosition {
                self.pendingPosition = nil
                self.scheduleCapture(at: pending)
            }
        }
    }

    // MARK: - SCShareableContent cache

    private var cachedContent: SCShareableContent?
    private var cachedContentExpiry: Date = .distantPast
    private let contentCacheTTL: TimeInterval = 5.0

    private func shareableContent() async -> SCShareableContent? {
        if let c = cachedContent, Date() < cachedContentExpiry { return c }
        let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = fresh
        cachedContentExpiry = Date().addingTimeInterval(contentCacheTTL)
        return fresh
    }

    private func pixelColor(at point: NSPoint) async -> (color: NSColor, image: CGImage, centerPx: CGPoint)? {
        guard let content = await shareableContent() else { return nil }

        // primary screen — тот у которого origin == .zero в AppKit-координатах.
        // Именно относительно его высоты AppKit отсчитывает Y снизу вверх.
        let primaryH = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?
            .frame.height ?? NSScreen.screens.first?.frame.height ?? 0

        // SCDisplay.frame — в Quartz (origin top-left, Y вниз).
        // AppKit NSPoint — origin bottom-left, Y вверх.
        // Конвертация: nsY = primaryH - quartzMaxY, где quartzMaxY = d.frame.minY + d.frame.height
        guard let display = content.displays.first(where: { d in
            let nsFrame = CGRect(
                x: d.frame.minX,
                y: primaryH - d.frame.maxY,
                width: d.frame.width,
                height: d.frame.height
            )
            return nsFrame.contains(point)
        }) else { return nil }

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

        // Конвертируем AppKit point → Quartz point → пиксель в capture buffer.
        // capture buffer соответствует display.frame в Quartz-координатах.
        let quartzY = primaryH - point.y
        let scaleX = CGFloat(display.width)  / display.frame.width
        let scaleY = CGFloat(display.height) / display.frame.height
        let px = Int((point.x  - display.frame.minX) * scaleX)
        let py = Int((quartzY  - display.frame.minY) * scaleY)

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

        let color = NSColor(
            srgbRed: CGFloat(pixelData[0]) / 255,
            green:   CGFloat(pixelData[1]) / 255,
            blue:    CGFloat(pixelData[2]) / 255,
            alpha:   CGFloat(pixelData[3]) / 255
        )
        return (color, cgImage, CGPoint(x: cx, y: cy))
    }

    // MARK: - MagnifierData

    func buildMagnifier(from cgImage: CGImage, centerPx: CGPoint, gridSize: Int = 5) -> MagnifierData {
        let half = gridSize / 2
        let imgW = cgImage.width, imgH = cgImage.height
        var rows: [[NSColor]] = []
        for row in 0..<gridSize {
            var rowColors: [NSColor] = []
            for col in 0..<gridSize {
                let px = Int(centerPx.x) + (col - half)
                let py = Int(centerPx.y) + (row - half)
                let cx = max(0, min(px, imgW - 1))
                let cy = max(0, min(py, imgH - 1))
                var d: [UInt8] = [0, 0, 0, 0]
                if let ctx = CGContext(data: &d, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.draw(cgImage, in: CGRect(x: -cx, y: -(imgH - cy - 1), width: imgW, height: imgH))
                }
                rowColors.append(NSColor(srgbRed: CGFloat(d[0])/255, green: CGFloat(d[1])/255,
                                         blue: CGFloat(d[2])/255, alpha: 1))
            }
            rows.append(rowColors)
        }
        return MagnifierData(pixels: rows, gridSize: gridSize)
    }
}
