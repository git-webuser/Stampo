import AppKit
import SwiftUI

// MARK: - CursorOverlayView

/// Кастомный crosshair-курсор.
/// Классический прицел с пустым центром — горячая точка (центр) не перекрывает
/// сэмплируемый пиксель, что критично для точного позиционирования.
private struct CursorOverlayView: View {

    /// Цвет под курсором — обводка прицела адаптируется для контраста.
    let color: NSColor?

    private let size:        CGFloat = 22
    private let gapRadius:   CGFloat = 3   // радиус пустого центра
    private let lineLength:  CGFloat = 6   // длина каждого луча
    private let lineWidth:   CGFloat = 1.5

    var body: some View {
        ZStack {
            // Тёмная обводка для контраста на светлом фоне
            crosshairShape(inset: 0.5)
                .stroke(shadowColor, lineWidth: lineWidth + 1)

            // Основной crosshair
            crosshairShape(inset: 0)
                .stroke(foregroundColor, lineWidth: lineWidth)
        }
        .frame(width: size, height: size)
    }

    // MARK: Private

    private func crosshairShape(inset: CGFloat) -> some Shape {
        CrosshairShape(
            size: size,
            gapRadius: gapRadius + inset,
            lineLength: lineLength - inset
        )
    }

    /// Основной цвет линий — инвертируем яркость сэмплированного цвета.
    private var foregroundColor: Color {
        guard let c = color?.usingColorSpace(.sRGB) else { return .white }
        let brightness = 0.299 * c.redComponent
                       + 0.587 * c.greenComponent
                       + 0.114 * c.blueComponent
        return brightness > 0.55 ? .black : .white
    }

    private var shadowColor: Color {
        guard let c = color?.usingColorSpace(.sRGB) else { return .black }
        let brightness = 0.299 * c.redComponent
                       + 0.587 * c.greenComponent
                       + 0.114 * c.blueComponent
        return brightness > 0.55 ? Color.white.opacity(0.6) : Color.black.opacity(0.6)
    }
}

// MARK: - CrosshairShape

private struct CrosshairShape: Shape {
    let size: CGFloat
    let gapRadius: CGFloat
    let lineLength: CGFloat

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        var p = Path()

        // Top
        p.move(to: CGPoint(x: cx, y: cy - gapRadius))
        p.addLine(to: CGPoint(x: cx, y: cy - gapRadius - lineLength))

        // Bottom
        p.move(to: CGPoint(x: cx, y: cy + gapRadius))
        p.addLine(to: CGPoint(x: cx, y: cy + gapRadius + lineLength))

        // Left
        p.move(to: CGPoint(x: cx - gapRadius,           y: cy))
        p.addLine(to: CGPoint(x: cx - gapRadius - lineLength, y: cy))

        // Right
        p.move(to: CGPoint(x: cx + gapRadius,           y: cy))
        p.addLine(to: CGPoint(x: cx + gapRadius + lineLength, y: cy))

        return p
    }
}

// MARK: - CursorOverlay (panel controller)

/// Floating panel, который заменяет системный курсор во время сэмплинга.
///
/// Использование:
///   1. `show()` — скрывает системный курсор, показывает overlay
///   2. `move(to:)` — вызывается на каждый mouseMoved, синхронно без анимации
///   3. `updateColor(_:)` — обновляет цвет crosshair под текущий пиксель
///   4. `hide()` — возвращает системный курсор, скрывает overlay
@MainActor
final class CursorOverlay {

    private var panel: NSPanel?
    private var currentColor: NSColor? = nil

    /// Физический размер overlay в логических пикселях.
    /// Горячая точка — центр панели.
    private let overlaySize = CGSize(width: 22, height: 22)

    // MARK: - Public API

    func show() {
        ensurePanel()
        guard let panel else { return }

        // Позиционируем сразу под текущий курсор
        let pos = NSEvent.mouseLocation
        panel.setFrame(frameForCursor(pos), display: false)
        refreshContent()

        NSCursor.hide()
        panel.orderFrontRegardless()
    }

    func move(to position: NSPoint) {
        guard let panel, panel.isVisible else { return }
        panel.setFrame(frameForCursor(position), display: false)
    }

    func updateColor(_ color: NSColor?) {
        currentColor = color
        refreshContent()
    }

    func hide() {
        panel?.orderOut(nil)
        NSCursor.unhide()
    }

    // MARK: - Private

    private func frameForCursor(_ cursor: NSPoint) -> NSRect {
        // Центрируем overlay на горячей точке курсора
        NSRect(
            x: cursor.x - overlaySize.width  / 2,
            y: cursor.y - overlaySize.height / 2,
            width:  overlaySize.width,
            height: overlaySize.height
        )
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        panel = makePanel()
    }

    private func refreshContent() {
        guard let panel else { return }
        let view = CursorOverlayView(color: currentColor)
        if let hosting = panel.contentView as? NSHostingView<CursorOverlayView> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: overlaySize.width, height: overlaySize.height)
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel    = true
        p.level              = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque           = false
        p.backgroundColor    = .clear
        p.hasShadow          = false
        p.hidesOnDeactivate  = false
        p.ignoresMouseEvents = true
        p.appearance         = NSAppearance(named: .darkAqua)
        return p
    }
}
