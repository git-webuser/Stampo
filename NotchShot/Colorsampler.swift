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
    private var startTime: Date = .distantPast
    private let ignoreClicksDuration: TimeInterval = 0.5

    private var captureInFlight = false
    private var pendingPosition: NSPoint? = nil

    private let cursorOverlay = CursorOverlay()

    func start(ignoreClicksUntil: Date? = nil) {
        guard !isStopped else { return }
        startTime = ignoreClicksUntil ?? Date()
        print(">>> sampler.start() startTime=\(startTime) now=\(Date())")

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

        leftClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseUp
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isStopped, self.isReady else { return }
                self.confirm()
            }
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
            print(">>> global keyDown: keyCode=\(event.keyCode)")
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

    private var isReady: Bool {
        let elapsed = Date().timeIntervalSince(startTime)
        print(">>> isReady: elapsed=\(elapsed) threshold=\(ignoreClicksDuration)")
        return Date() >= startTime.addingTimeInterval(ignoreClicksDuration)
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
            if let color = await pixelColor(at: position) {
                guard !self.isStopped else { return }
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

    private func pixelColor(at point: NSPoint) async -> NSColor? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return nil }

        guard let display = content.displays.first(where: { d in
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            let nsFrame = CGRect(x: d.frame.minX, y: mainH - d.frame.maxY,
                                 width: d.frame.width, height: d.frame.height)
            return nsFrame.contains(point)
        }) else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width  = Int(display.width)
        config.height = Int(display.height)
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }

        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let quartzY = mainH - point.y
        let px = Int(point.x - display.frame.minX)
        let py = Int(quartzY - display.frame.minY)
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
