import SwiftUI
import AppKit

// MARK: - ColorPickerHUDPhase

enum ColorPickerHUDPhase: Equatable {
    case hidden
    case idlePlaceholder
    case livePreview(NSColor)
    case success(NSColor)

    static func == (lhs: ColorPickerHUDPhase, rhs: ColorPickerHUDPhase) -> Bool {
        switch (lhs, rhs) {
        case (.hidden, .hidden):                         return true
        case (.idlePlaceholder, .idlePlaceholder):       return true
        case (.livePreview(let a), .livePreview(let b)): return a == b
        case (.success(let a),    .success(let b)):      return a == b
        default: return false
        }
    }
}

// MARK: - HUDColorFormat

enum HUDColorFormat: CaseIterable, Equatable {
    case hex
    case rgb
    case cmyk

    var title: String {
        switch self {
        case .hex:  return "HEX"
        case .rgb:  return "RGB"
        case .cmyk: return "CMYK"
        }
    }

    var placeholderDashes: String {
        switch self {
        case .hex, .rgb: return "— — —"
        case .cmyk:      return "— — — —"
        }
    }

    func format(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        switch self {
        case .hex:
            return c.hexString
        case .rgb:
            let r = Int(round(c.redComponent   * 255))
            let g = Int(round(c.greenComponent * 255))
            let b = Int(round(c.blueComponent  * 255))
            return "\(r)  \(g)  \(b)"
        case .cmyk:
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            let k = 1 - max(r, g, b)
            if k >= 1 { return "0  0  0  100" }
            let d = 1 - k
            let cv = Int(round(((1 - r - k) / d) * 100))
            let mv = Int(round(((1 - g - k) / d) * 100))
            let yv = Int(round(((1 - b - k) / d) * 100))
            let kv = Int(round(k * 100))
            return "\(cv)  \(mv)  \(yv)  \(kv)"
        }
    }
}

// MARK: - ColorPickerHUDView

struct ColorPickerHUDView: View {
    let phase: ColorPickerHUDPhase
    let format: HUDColorFormat
    /// Показывать ли подсказку про переключение формата клавишей F.
    let showHint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                swatchView

                VStack(alignment: .leading, spacing: 2) {
                    Text(format.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .transaction { $0.animation = nil }

                    Text(valueText)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(valueOpacity))
                        .lineLimit(1)
                        .fixedSize()
                        .transaction { $0.animation = nil }
                }

                if case .success = phase {
                    Text("Copied")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }

            // Подсказка — показываем только первые несколько секунд
            if showHint {
                Text("F — switch format  ·  Esc — cancel")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.3))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(HUDBackground())
        .animation(.easeOut(duration: 0.14), value: phase)
        .animation(.easeOut(duration: 0.2), value: showHint)
    }

    // MARK: Private

    private var resolvedColor: NSColor? {
        switch phase {
        case .livePreview(let c), .success(let c): return c
        default: return nil
        }
    }

    @ViewBuilder
    private var swatchView: some View {
        ZStack {
            // Шахматная подложка для прозрачных цветов
            CheckerboardView()
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(swatchFill)
        }
        .frame(width: 22, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var swatchFill: Color {
        if let c = resolvedColor { return Color(nsColor: c) }
        return Color.white.opacity(0.10)
    }

    private var valueText: String {
        switch phase {
        case .hidden, .idlePlaceholder:
            return format.placeholderDashes
        case .livePreview(let c), .success(let c):
            return format.format(c)
        }
    }

    private var valueOpacity: Double {
        switch phase {
        case .hidden, .idlePlaceholder: return 0.3
        default: return 0.95
        }
    }
}

// MARK: - CheckerboardView (для свотча с прозрачностью)

private struct CheckerboardView: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 4
            var toggle = false
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = toggle ? s : 0
                while x < size.width {
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: s, height: s)),
                        with: .color(.white.opacity(0.15))
                    )
                    x += s * 2
                }
                toggle.toggle()
                y += s
            }
        }
    }
}

// MARK: - HUDBackground

/// Фон HUD с тенью нарисованной через CALayer — не обрезается bounds панели.
private struct HUDBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = HUDBackgroundView()
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class HUDBackgroundView: NSView {
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer.borderWidth = 1
        // Тень через CALayer — не обрезается bounds окна
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.masksToBounds = false
        return layer
    }

    override var isFlipped: Bool { true }
}

// MARK: - ColorPickerHUD (floating panel controller)

final class ColorPickerHUD {

    // MARK: State

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var hintWorkItem: DispatchWorkItem?

    private(set) var currentFormat: HUDColorFormat = .hex
    private var currentPhase: ColorPickerHUDPhase = .hidden
    private var showHint: Bool = false

    // Размер панели — зависит от того, виден ли hint
    private var sizeWithHint    = CGSize(width: 210, height: 72)
    private var sizeWithoutHint = CGSize(width: 210, height: 52)

    private var currentSize: CGSize { showHint ? sizeWithHint : sizeWithoutHint }

    // Текущий offset HUD относительно курсора (меняется при flip)
    private var offsetX: CGFloat =  18
    private var offsetY: CGFloat = -30   // вверх от курсора

    // MARK: - Public API

    func setFormat(_ format: HUDColorFormat) {
        currentFormat = format
        refreshContent()
    }

    /// Показать HUD и привязать к курсору.
    /// Вызывается один раз при старте сессии.
    func beginSession(format: HUDColorFormat) {
        currentFormat = format
        currentPhase  = .idlePlaceholder
        showHint = true

        ensurePanel()
        guard let panel else { return }

        refreshContent()

        // Позиционируем HUD по текущей позиции курсора немедленно —
        // не ждём первого update(color:cursorPosition:).
        moveToPosition(NSEvent.mouseLocation)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }

        // Скрываем hint через 3 секунды
        let hintWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHint = false
            self.refreshContent()
            // Плавно уменьшаем панель
            if let panel = self.panel, let screen = self.screenForPanel() {
                let pos = NSEvent.mouseLocation
                let frame = self.frameForCursor(pos, on: screen)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
        hintWorkItem = hintWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: hintWork)
    }

    /// Обновить цвет и позицию — вызывается на каждый mouseMoved.
    func update(color: NSColor, cursorPosition: NSPoint) {
        currentPhase = .livePreview(color)
        refreshContent()
        moveToPosition(cursorPosition)
    }

    /// Финальный успех — показываем success state, затем скрываем.
    func showSuccess(color: NSColor, on screen: NSScreen?, autoHideAfter delay: TimeInterval = 0.35) {
        hintWorkItem?.cancel()
        hintWorkItem = nil
        showHint = false

        currentPhase = .success(color)
        refreshContent()

        // Паркуем панель в нижний правый угол экрана
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let panel, let frame = frameBottomRight(on: targetScreen) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide(animated: Bool = true) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        hintWorkItem?.cancel()
        hintWorkItem = nil
        currentPhase = .hidden
        showHint = false

        guard let panel, panel.isVisible else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak panel] in
                panel?.orderOut(nil)
            }
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Positioning

    private func moveToPosition(_ cursorPos: NSPoint) {
        guard let panel else { return }
        guard let screen = screenForPoint(cursorPos) ?? NSScreen.main else { return }
        let frame = frameForCursor(cursorPos, on: screen)
        // Без анимации — должно быть мгновенно чтобы следовать за курсором
        panel.setFrame(frame, display: false)
    }

    /// Вычисляет позицию HUD с учётом краёв экрана.
    /// При приближении к краю зеркалит offset по соответствующей оси.
    private func frameForCursor(_ cursor: NSPoint, on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let size = currentSize
        let margin: CGFloat = 8

        // Начальный offset (по умолчанию: правее и выше курсора)
        var dx = offsetX
        var dy = offsetY

        var x = cursor.x + dx
        var y = cursor.y + dy

        // Flip X: выходит за правый край → уходим влево
        if x + size.width > sf.maxX - margin {
            dx = -(size.width + 12)
            x = cursor.x + dx
        }
        // Flip X: выходит за левый край → возвращаем вправо
        if x < sf.minX + margin {
            dx = 18
            x = cursor.x + dx
        }

        // Flip Y: выходит за верхний край → уходим ниже курсора
        if y + size.height > sf.maxY - margin {
            dy = 14   // ниже курсора
            y = cursor.y + dy
        }
        // Flip Y: выходит за нижний край → уходим выше
        if y < sf.minY + margin {
            dy = -size.height - 12
            y = cursor.y + dy
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func frameBottomRight(on screen: NSScreen?) -> NSRect? {
        guard let screen else { return nil }
        let vf = screen.visibleFrame
        let margin: CGFloat = 18
        let size = currentSize
        return NSRect(
            x: vf.maxX - margin - size.width,
            y: vf.minY + margin,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Panel management

    private func ensurePanel() {
        guard panel == nil else { return }
        let initialFrame = NSRect(x: 0, y: 0, width: currentSize.width, height: currentSize.height)
        panel = makePanel(frame: initialFrame)
    }

    private func refreshContent() {
        guard let panel else { return }
        guard let rootView = panel.contentView,
              let blur = rootView.subviews.compactMap({ $0 as? NSVisualEffectView }).first
        else { return }
        let view = ColorPickerHUDView(phase: currentPhase, format: currentFormat, showHint: showHint)
        if let hosting = blur.subviews.compactMap({ $0 as? NSHostingView<ColorPickerHUDView> }).first {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = .clear
            blur.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: blur.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            ])
        }
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel  = true
        p.level            = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque         = false
        p.backgroundColor  = .clear
        p.hasShadow        = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true   // обязательно — иначе ломает sampler
        p.appearance       = nil  // следуем системной теме

        // NSVisualEffectView как subview contentView — правильный паттерн.
        // Это даёт скруглённые углы без прямоугольной тени окна.
        let rootView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = .clear
        p.contentView = rootView

        let blur = NSVisualEffectView(frame: rootView.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material     = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state        = .active
        blur.wantsLayer   = true
        blur.layer?.cornerRadius  = 12
        blur.layer?.cornerCurve   = .continuous
        blur.layer?.masksToBounds = true
        rootView.addSubview(blur)
        return p
    }

    private func screenForPanel() -> NSScreen? {
        guard let panel else { return NSScreen.main }
        return screenForPoint(NSPoint(x: panel.frame.midX, y: panel.frame.midY))
    }

    private func screenForPoint(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}
