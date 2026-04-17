import AppKit
import ScreenCaptureKit

// MARK: - ColorSampler

@MainActor
final class ColorSampler {

    var onColorChanged: ((NSColor, NSPoint, MagnifierData?) -> Void)?
    var onConfirmed: ((NSColor) -> Void)?
    var onCancelled: (() -> Void)?
    var format: HUDColorFormat = AppSettings.defaultColorFormat.hudFormat

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var rightClickMonitor: Any?
    private var leftClickMonitor: Any?
    private var escEventTap: CFMachPort?
    private var escEventTapSource: CFRunLoopSource?

    private var lastColor: NSColor = .black
    var isStopped = false

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

    deinit { MainActor.assumeIsolated { stop() } }

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

        // CGEventTap для Esc — работает даже когда другое приложение
        // перехватывает фокус (например поле ввода на другом Space).
        // Глобальный NSEvent монитор в этом случае не получает keyDown.
        let escTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let sampler = Unmanaged<ColorSampler>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = sampler.escEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async {
                guard !sampler.isStopped else { return }
                sampler.cancel()
            }
            // Поглощаем Esc чтобы он не попал в поле ввода
            return nil
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: escTapCallback,
            userInfo: selfPtr
        ) {
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                // tap создан, но source не получился — явно выключаем порт,
                // чтобы не оставлять его висеть в системе.
                CGEvent.tapEnable(tap: tap, enable: false)
                print("[ColorSampler] CFMachPortCreateRunLoopSource failed")
                return
            }
            escEventTap = tap
            escEventTapSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func removeMonitors() {
        [mouseMonitor, localMouseMonitor, leftClickMonitor, rightClickMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        mouseMonitor = nil
        localMouseMonitor = nil
        leftClickMonitor = nil
        rightClickMonitor = nil

        if let tap = escEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = escEventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                escEventTapSource = nil
            }
            escEventTap = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown: cancel()
        case .keyDown: handleKeyDown(event)
        default: break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Стрелки для точного позиционирования
        // Стрелка = 1pt, Shift = 10pt, Shift+Option = 50pt
        let arrowMap: [UInt16: (CGFloat, CGFloat)] = [
            126: (0, -1), 125: (0, 1), 123: (-1, 0), 124: (1, 0)
        ]
        if let (dx, dy) = arrowMap[event.keyCode] {
            let mods = event.modifierFlags
            let step: CGFloat = mods.contains([.shift, .option]) ? 50
                              : mods.contains(.shift)            ? 10 : 1
            let cur = NSEvent.mouseLocation
            let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                           ?? NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: cur.x + dx * step,
                                               y: primaryH - (cur.y - dy * step)))
            let newPos = NSPoint(x: cur.x + dx * step, y: cur.y - dy * step)
            cursorOverlay.move(to: newPos)
            scheduleCapture(at: newPos)
            return
        }
        switch event.keyCode {
        case 53: cancel()
        case 3 where AppSettings.hotkeyHUDFormatEnabled:
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

    func cancel() {
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
        let fresh: SCShareableContent?
        do {
            fresh = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            #if DEBUG
            print("[ColorSampler] SCShareableContent failed: \(error)")
            #endif
            // Surface the failure to the user once (throttled internally) and
            // abort the picker so they aren't left with a frozen magnifier.
            UserFacingError.present(.colorPickerUnavailable(
                reason: error.localizedDescription))
            cancel()
            fresh = nil
        }
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

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            #if DEBUG
            print("[ColorSampler] captureImage failed: \(error)")
            #endif
            // Single throttled alert on persistent capture failure — typically
            // means screen-recording permission was revoked mid-session.
            UserFacingError.present(.colorPickerUnavailable(
                reason: error.localizedDescription))
            cancel()
            return nil
        }

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

    // MARK: - MagnifierData (3×3 из уже захваченного снимка)

    func buildMagnifier(from cgImage: CGImage, centerPx: CGPoint, gridSize: Int = 3) -> MagnifierData {
        let half = gridSize / 2
        let imgW = cgImage.width, imgH = cgImage.height

        // Clamp patch origin so the entire gridSize×gridSize region stays inside the image.
        let srcX = max(0, min(Int(centerPx.x) - half, imgW - gridSize))
        let srcY = max(0, min(Int(centerPx.y) - half, imgH - gridSize))

        let bytesPerRow = gridSize * 4
        var data = [UInt8](repeating: 0, count: gridSize * bytesPerRow)

        // Single render: draw the whole image shifted so pixel (srcX, srcY) lands at (0,0).
        // Derivation: CGContext draws image pixel (px,py) at ctx pos (x0+px, y0+imgH-1-py).
        // We want (srcX, srcY) → (0, 0): x0 = -srcX, y0 = srcY - (imgH - 1) = gridSize - imgH + srcY.
        if let ctx = CGContext(
            data: &data,
            width: gridSize, height: gridSize,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.draw(cgImage, in: CGRect(x: -srcX, y: gridSize - imgH + srcY, width: imgW, height: imgH))
        }

        // Read pixels from the flat bitmap.
        // Despite CGContext having y=0 at the bottom (drawing coords), the bitmap
        // data is stored TOP-DOWN in memory: data[0] is the topmost row
        // (CGContext y = gridSize-1), data[(gridSize-1)*bytesPerRow] is the bottom row
        // (CGContext y = 0). So memory row == canvas row — no inversion needed.
        var rows: [[NSColor]] = []
        for row in 0..<gridSize {
            var rowColors: [NSColor] = []
            for col in 0..<gridSize {
                let offset = (row * gridSize + col) * 4
                rowColors.append(NSColor(
                    srgbRed: CGFloat(data[offset])     / 255,
                    green:   CGFloat(data[offset + 1]) / 255,
                    blue:    CGFloat(data[offset + 2]) / 255,
                    alpha:   1
                ))
            }
            rows.append(rowColors)
        }
        return MagnifierData(pixels: rows, gridSize: gridSize)

        // ── Old approach (kept for reference) ────────────────────────────────────────
        // Each pixel used a separate CGContext(1×1) + full image render, which meant
        // gridSize² render-passes of a potentially 5K image per mouse move.
        // Kept here in case a color-space or premultiplied-alpha issue resurfaces.
        //
        // var rows: [[NSColor]] = []
        // for row in 0..<gridSize {
        //     var rowColors: [NSColor] = []
        //     for col in 0..<gridSize {
        //         let px = Int(centerPx.x) + (col - half)
        //         let py = Int(centerPx.y) + (row - half)
        //         let cx = max(0, min(px, imgW - 1))
        //         let cy = max(0, min(py, imgH - 1))
        //         var d: [UInt8] = [0, 0, 0, 0]
        //         if let ctx = CGContext(data: &d, width: 1, height: 1,
        //             bitsPerComponent: 8, bytesPerRow: 4,
        //             space: CGColorSpaceCreateDeviceRGB(),
        //             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        //             ctx.draw(cgImage, in: CGRect(x: -cx, y: -(imgH - cy - 1), width: imgW, height: imgH))
        //         }
        //         rowColors.append(NSColor(srgbRed: CGFloat(d[0])/255, green: CGFloat(d[1])/255,
        //                                  blue: CGFloat(d[2])/255, alpha: 1))
        //     }
        //     rows.append(rowColors)
        // }
        // return MagnifierData(pixels: rows, gridSize: gridSize)
        // ─────────────────────────────────────────────────────────────────────────────
    }
}
