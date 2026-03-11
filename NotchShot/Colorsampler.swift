import AppKit
import ScreenCaptureKit

// MARK: - ColorSampler

/// Кастомный color sampler с live preview через ScreenCaptureKit.
///
/// Требует разрешения Screen Recording в System Settings.
/// При первом запуске автоматически запрашивает разрешение через SCShareableContent.
///
/// Жизненный цикл:
///   start() → onColorChanged (много раз) → onConfirmed / onCancelled → автоматически stop()
@MainActor
final class ColorSampler {

    // MARK: - Callbacks (все вызываются на MainActor)

    /// Цвет под курсором обновился.
    var onColorChanged: ((NSColor, NSPoint) -> Void)?

    /// Левый клик — подтверждение. Sampler уже остановлен.
    var onConfirmed: ((NSColor) -> Void)?

    /// Escape или правый клик — отмена. Sampler уже остановлен.
    var onCancelled: (() -> Void)?

    /// Текущий формат — меняется клавишей F в любой момент.
    var format: HUDColorFormat = .hex

    // MARK: - Private state

    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var rightClickMonitor: Any?
    private var leftClickMonitor: Any?

    private var lastColor: NSColor = .black
    private var isStopped = false

    /// Throttle: не запускаем новый захват пока предыдущий не завершился.
    private var captureInFlight = false
    /// Позиция, которую нужно захватить следующей (если тик пришёл во время захвата).
    private var pendingPosition: NSPoint? = nil

    private let cursorOverlay = CursorOverlay()

    // MARK: - Public

    func start() {
        guard !isStopped else { return }
        cursorOverlay.show()
        installMonitors()

        // Первый тик — сразу пробуем захватить цвет под курсором
        let pos = NSEvent.mouseLocation
        scheduleCapture(at: pos)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        cursorOverlay.hide()
        removeMonitors()
    }

    // MARK: - Monitor setup

    private func installMonitors() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            guard let self else { return }
            let pos = NSEvent.mouseLocation
            Task { @MainActor in
                // Overlay движется синхронно — без задержки SCK-захвата
                self.cursorOverlay.move(to: pos)
                self.scheduleCapture(at: pos)
            }
        }

        // Локальные события — поглощаем, чтобы не проваливались в приложение
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return nil }
            Task { @MainActor in self.handleLocalEvent(event) }
            return nil
        }

        // Глобальные клики — вне нашего процесса
        leftClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isStopped else { return }
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
    }

    private func removeMonitors() {
        [mouseMonitor, localMouseMonitor, leftClickMonitor, rightClickMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        mouseMonitor = nil
        localMouseMonitor = nil
        leftClickMonitor = nil
        rightClickMonitor = nil
    }

    // MARK: - Event handling

    private func handleLocalEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: confirm()
        case .rightMouseDown: cancel()
        case .keyDown: handleKeyDown(event)
        default: break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            cancel()
        case 3: // F — переключить формат по кругу
            let all = HUDColorFormat.allCases
            if let idx = all.firstIndex(of: format) {
                format = all[(idx + 1) % all.count]
                // Переотправляем последний цвет чтобы HUD немедленно обновился
                onColorChanged?(lastColor, NSEvent.mouseLocation)
            }
        default:
            break
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

    // MARK: - Capture throttle

    /// Если захват свободен — запускаем немедленно.
    /// Если занят — запоминаем позицию; она будет захвачена сразу после завершения текущего.
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

            // Если пока захватывали — пришёл ещё тик, запускаем его
            if let pending = self.pendingPosition {
                self.pendingPosition = nil
                self.scheduleCapture(at: pending)
            }
        }
    }

    // MARK: - Pixel sampling via ScreenCaptureKit

    /// Захватывает 1×1 логический пиксель под `point` через SCK.
    /// Возвращает nil если разрешение не выдано или захват не удался.
    private func pixelColor(at point: NSPoint) async -> NSColor? {
        // SCK требует разрешения Screen Recording.
        // Запрашиваем список контента — это тригерит системный диалог при первом вызове.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) else { return nil }

        // Находим дисплей под курсором
        guard let display = content.displays.first(where: { d in
            let r = CGRect(x: d.frame.minX, y: d.frame.minY,
                           width: d.frame.width, height: d.frame.height)
            // SCK frame в Quartz-координатах (origin top-left главного экрана)
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            let nsFrame = CGRect(x: r.minX, y: mainH - r.maxY,
                                 width: r.width, height: r.height)
            return nsFrame.contains(point)
        }) else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        // Захватываем весь дисплей, потом вырежем нужный пиксель
        config.width  = Int(display.width)
        config.height = Int(display.height)
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else { return nil }

        // Переводим NSPoint → пиксель в изображении.
        // SCK origin — top-left дисплея, в логических пикселях (не backing).
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        // Quartz Y (от верха главного экрана)
        let quartzY = mainH - point.y
        // Координата относительно дисплея
        let displayFrame = display.frame  // в Quartz-координатах
        let px = Int(point.x - displayFrame.minX)
        let py = Int(quartzY - displayFrame.minY)

        // Клампим на случай краевых пикселей
        let imgW = cgImage.width
        let imgH = cgImage.height
        guard imgW > 0, imgH > 0 else { return nil }
        let clampedX = max(0, min(px, imgW - 1))
        let clampedY = max(0, min(py, imgH - 1))

        // Читаем один пиксель через CGContext 1×1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(
            data: &pixelData,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Рисуем нужный пиксель в наш 1×1 контекст
        ctx.draw(cgImage, in: CGRect(x: -clampedX, y: -(imgH - clampedY - 1), width: imgW, height: imgH))

        let r = CGFloat(pixelData[0]) / 255
        let g = CGFloat(pixelData[1]) / 255
        let b = CGFloat(pixelData[2]) / 255
        let a = CGFloat(pixelData[3]) / 255

        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
