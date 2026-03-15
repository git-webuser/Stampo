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
    case hsl
    case hsb
    case cmyk

    var title: String {
        switch self {
        case .hex:  return "HEX"
        case .rgb:  return "RGB"
        case .hsl:  return "HSL"
        case .hsb:  return "HSB"
        case .cmyk: return "CMYK"
        }
    }

    var placeholderDashes: String {
        switch self {
        case .hex:        return "—"
        case .rgb:        return "— — —"
        case .hsl, .hsb:  return "— — —"
        case .cmyk:       return "— — — —"
        }
    }

    func format(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        switch self {
        case .hex:  return c.hexString
        case .rgb:  return c.rgbString
        case .hsl:  return c.hslString
        case .hsb:  return c.hsbString
        case .cmyk: return c.cmykString
        }
    }
}

// MARK: - MagnifierGrid

/// Данные лупы: 9×9 ячеек цветов + координата центрального пикселя.
struct MagnifierData: Equatable {
    /// Цвета в порядке row-major, (0,0) = верхний левый.
    let pixels: [[NSColor]]
    let gridSize: Int

    static let empty = MagnifierData(pixels: [], gridSize: 5)

    static func == (lhs: MagnifierData, rhs: MagnifierData) -> Bool {
        // Сравниваем только размер — цвет центра достаточен для refresh
        lhs.gridSize == rhs.gridSize && lhs.pixels.count == rhs.pixels.count
    }
}

// MARK: - ColorPickerHUDView

struct ColorPickerHUDView: View {
    let phase: ColorPickerHUDPhase
    let format: HUDColorFormat
    let showHint: Bool
    let magnifier: MagnifierData

    // 5×5 сетка, ячейки 9pt = 45pt итого — пропорционально высоте текстового блока
    private let gridSize = 5
    private let cellSize: CGFloat = 9
    private var magnifierSize: CGFloat { CGFloat(gridSize) * cellSize }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            magnifierView
            textPanel
        }
        .padding(8)
        .background(HUDBackground())
        .fixedSize()
    }

    // MARK: - Magnifier / Success swatch

    @ViewBuilder
    private var magnifierView: some View {
        if case .success(let c) = phase {
            // Success: лупа заменяется цветным квадратом
            Color(nsColor: c)
                .frame(width: magnifierSize, height: magnifierSize)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1))
                .transition(.opacity)
        } else {
            liveMagnifier
        }
    }

    private var liveMagnifier: some View {
        ZStack {
            // Пиксели
            if !magnifier.pixels.isEmpty {
                Canvas { ctx, _ in
                    for row in 0..<gridSize {
                        guard row < magnifier.pixels.count else { break }
                        for col in 0..<gridSize {
                            guard col < magnifier.pixels[row].count else { break }
                            ctx.fill(
                                Path(CGRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize,
                                            width: cellSize, height: cellSize)),
                                with: .color(Color(nsColor: magnifier.pixels[row][col]))
                            )
                        }
                    }
                }
                .frame(width: magnifierSize, height: magnifierSize)
            } else {
                Rectangle().fill(Color.white.opacity(0.07))
                    .frame(width: magnifierSize, height: magnifierSize)
            }
            // Сетка
            Canvas { ctx, size in
                var p = Path()
                for i in 1..<gridSize {
                    let v = CGFloat(i) * cellSize
                    p.move(to: .init(x: v, y: 0));          p.addLine(to: .init(x: v, y: size.height))
                    p.move(to: .init(x: 0, y: v));          p.addLine(to: .init(x: size.width, y: v))
                }
                ctx.stroke(p, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
            .frame(width: magnifierSize, height: magnifierSize)
            // Рамка центральной ячейки
            Rectangle().stroke(Color.white, lineWidth: 1.5)
                .frame(width: cellSize, height: cellSize)
        }
        .frame(width: magnifierSize, height: magnifierSize)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(Color.white.opacity(0.22), lineWidth: 1))
        .transition(.opacity)
    }

    // MARK: - Text panel

    @ViewBuilder
    private var textPanel: some View {
        if case .success = phase {
            successContent
                .transition(.opacity.combined(with: .scale(scale: 1.04, anchor: .leading)))
        } else {
            liveContent
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
        }
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(format.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .transaction { $0.animation = nil }
            Text(valueText)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(valueOpacity))
                .lineLimit(1)
                .fixedSize()
                .transaction { $0.animation = nil }
            if showHint { hintRow.transition(.opacity) }
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    private var successContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .symbolEffect(.bounce, value: phase)
            Text("Copied")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(minWidth: 120, alignment: .leading)
    }

    private var hintRow: some View {
        HStack(spacing: 6) {
            hintKey("F")
            Text("Format").foregroundStyle(.white.opacity(0.3))
            hintKey("Esc")
            Text("Cancel").foregroundStyle(.white.opacity(0.3))
        }
        .font(.system(size: 10, weight: .regular))
    }

    private func hintKey(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    private var valueText: String {
        switch phase {
        case .hidden, .idlePlaceholder: return format.placeholderDashes
        case .livePreview(let c), .success(let c): return format.format(c)
        }
    }

    private var valueOpacity: Double {
        switch phase {
        case .hidden, .idlePlaceholder: return 0.25
        default: return 1.0
        }
    }
}


// MARK: - HUDBackground

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
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.45
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -4)
        layer.masksToBounds = false
        return layer
    }
    override var isFlipped: Bool { true }
}

// MARK: - ColorPickerHUD

final class ColorPickerHUD {

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var hintWorkItem: DispatchWorkItem?

    private(set) var currentFormat: HUDColorFormat = .hex
    private var currentPhase: ColorPickerHUDPhase = .hidden
    private var showHint: Bool = false
    private var currentMagnifier: MagnifierData = .empty

    // Фиксированный размер — не меняется со сменой формата/хинта
    // Лупа 9×9 × 10pt = 90, padding 10×2 = 20, итого высота ~110
    private let hudSize = CGSize(width: 240, height: 62)
    private var currentSize: CGSize { hudSize }

    private let offsetX: CGFloat =  18
    private let offsetY: CGFloat = -30

    // MARK: - Public API

    func setFormat(_ format: HUDColorFormat) {
        currentFormat = format
        refreshContent()
    }

    func beginSession(format: HUDColorFormat) {
        currentFormat = format
        currentPhase  = .idlePlaceholder
        currentMagnifier = .empty
        showHint = true

        ensurePanel()
        guard let panel else { return }

        refreshContent()
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

        let hintWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHint = false
            self.refreshContent()
        }
        hintWorkItem = hintWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: hintWork)
    }

    func update(color: NSColor, cursorPosition: NSPoint, magnifier: MagnifierData?) {
        currentPhase = .livePreview(color)
        if let mag = magnifier { currentMagnifier = mag }
        refreshContent()
        moveToPosition(cursorPosition)
    }

    func showSuccess(color: NSColor, on screen: NSScreen?, autoHideAfter delay: TimeInterval = 1.2) {
        hintWorkItem?.cancel()
        hintWorkItem = nil
        showHint = false
        currentPhase = .success(color)
        refreshContent()
        // HUD остаётся на месте — никакого перемещения в угол

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
        panel.setFrame(frame, display: false)
    }

    private func frameForCursor(_ cursor: NSPoint, on screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let size = currentSize
        let margin: CGFloat = 8

        var dx = offsetX
        var dy = offsetY

        var x = cursor.x + dx
        var y = cursor.y + dy

        if x + size.width > sf.maxX - margin {
            dx = -(size.width + 12)
            x = cursor.x + dx
        }
        if x < sf.minX + margin {
            dx = 18
            x = cursor.x + dx
        }
        if y + size.height > sf.maxY - margin {
            dy = 14
            y = cursor.y + dy
        }
        if y < sf.minY + margin {
            dy = -size.height - 12
            y = cursor.y + dy
        }

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }


    // MARK: - Panel management

    private func ensurePanel() {
        guard panel == nil else { return }
        let frame = NSRect(origin: .zero, size: currentSize)
        panel = makePanel(frame: frame)
    }

    private func refreshContent() {
        guard let panel else { return }
        guard let rootView = panel.contentView,
              let blur = rootView.subviews.compactMap({ $0 as? NSVisualEffectView }).first
        else { return }

        let view = ColorPickerHUDView(
            phase: currentPhase,
            format: currentFormat,
            showHint: showHint,
            magnifier: currentMagnifier
        )
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
        p.isFloatingPanel    = true
        p.level              = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque           = false
        p.backgroundColor    = .clear
        p.hasShadow          = false
        p.hidesOnDeactivate  = false
        p.ignoresMouseEvents = true
        p.appearance         = nil

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

    private func screenForPoint(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}
