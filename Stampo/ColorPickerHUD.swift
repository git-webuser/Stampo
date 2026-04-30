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

/// Pixel data for the magnifier: a gridSize×gridSize colour grid.
struct MagnifierData: Equatable {
    /// Colours in row-major order; (0,0) is the top-left cell.
    let pixels: [[NSColor]]
    let gridSize: Int

    static let empty = MagnifierData(pixels: [], gridSize: 3)

    static func == (lhs: MagnifierData, rhs: MagnifierData) -> Bool {
        guard lhs.gridSize == rhs.gridSize,
              lhs.pixels.count == rhs.pixels.count else { return false }
        for (rowL, rowR) in zip(lhs.pixels, rhs.pixels) {
            guard rowL.count == rowR.count else { return false }
            for (cL, cR) in zip(rowL, rowR) where !cL.isEqual(cR) { return false }
        }
        return true
    }
}

// MARK: - ColorPickerHUDView

struct ColorPickerHUDView: View, Equatable {
    let phase: ColorPickerHUDPhase
    let format: HUDColorFormat
    let magnifier: MagnifierData
    /// When HUD is to the left of the cursor the magnifier moves to the right
    /// side so it stays close to the cursor (matching the right-side behaviour).
    let magnifierOnRight: Bool

    private let gridSize = 3
    private let cellSize: CGFloat = 14
    private var magnifierSize: CGFloat { CGFloat(gridSize) * cellSize }
    private var isSuccess: Bool { if case .success = phase { return true }; return false }

    private var valueText: String {
        switch phase {
        case .hidden, .idlePlaceholder: return format.placeholderDashes
        case .livePreview(let c), .success(let c): return format.format(c)
        }
    }
    private var valueOpacity: Double {
        switch phase { case .hidden, .idlePlaceholder: return 0.25; default: return 1.0 }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if magnifierOnRight {
                textArea.padding(.leading, 4)
                magnifierArea
            } else {
                magnifierArea
                textArea.padding(.trailing, 4)
            }
        }
        .padding(8)
        // The dark card and its border live on a CALayer underneath the
        // hosting view (see ColorPickerHUD.makePanel) so they animate in
        // lockstep with the panel resize, instead of fighting SwiftUI's
        // spring on the .background modifier.
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSuccess)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: format)
        .fixedSize()
        .managedLocale()
    }

    @ViewBuilder private var magnifierArea: some View {
        if case .success(let c) = phase {
            Color(nsColor: c)
                .frame(width: magnifierSize, height: magnifierSize)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
                .transition(.opacity)
        } else {
            liveMagnifier.transition(.opacity)
        }
    }

    /// Grid-line path is constant for the lifetime of the app — computed once.
    private static let gridLinePath: Path = {
        let n  = 3
        let cs = CGFloat(14)
        var p  = Path()
        for i in 1..<n {
            let v = CGFloat(i) * cs
            p.move(to: CGPoint(x: v, y: 0));        p.addLine(to: CGPoint(x: v, y: CGFloat(n) * cs))
            p.move(to: CGPoint(x: 0, y: v));        p.addLine(to: CGPoint(x: CGFloat(n) * cs, y: v))
        }
        return p
    }()

    private var liveMagnifier: some View {
        ZStack {
            // Single Canvas: pixels + grid lines in one render pass.
            Canvas { [pixels = magnifier.pixels] ctx, _ in
                if pixels.isEmpty {
                    ctx.fill(Path(CGRect(x: 0, y: 0,
                                        width: CGFloat(3) * 14,
                                        height: CGFloat(3) * 14)),
                             with: .color(.white.opacity(0.07)))
                } else {
                    for row in 0..<3 {
                        guard row < pixels.count else { break }
                        for col in 0..<3 {
                            guard col < pixels[row].count else { break }
                            ctx.fill(
                                Path(CGRect(x: CGFloat(col) * 14, y: CGFloat(row) * 14,
                                           width: 14, height: 14)),
                                with: .color(Color(nsColor: pixels[row][col]))
                            )
                        }
                    }
                }
                ctx.stroke(Self.gridLinePath, with: .color(.white.opacity(0.18)), lineWidth: 0.5)
            }
            .frame(width: magnifierSize, height: magnifierSize)

            // Adaptive center-cell border — contrasts against the sampled pixel.
            Rectangle()
                .stroke(centerBorderColor, lineWidth: 1.5)
                .frame(width: cellSize, height: cellSize)
        }
        .frame(width: magnifierSize, height: magnifierSize)
        .drawingGroup()   // composite ZStack to a single GPU-backed texture at 60 fps
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.22), lineWidth: 1))
    }

    /// Border colour for the centre cell — contrasts against the sampled pixel.
    private var centerBorderColor: Color {
        guard magnifier.pixels.count > gridSize / 2,
              magnifier.pixels[gridSize / 2].count > gridSize / 2 else { return .white }
        let c = magnifier.pixels[gridSize / 2][gridSize / 2]
        guard let srgb = c.usingColorSpace(.sRGB) else { return .white }
        let lum = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        return lum > 0.5 ? Color.black.opacity(0.85) : Color.white.opacity(0.9)
    }

    @ViewBuilder private var textArea: some View {
        if isSuccess {
            successRow.transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 1.05, anchor: .leading)),
                removal: .opacity))
        } else {
            liveText.transition(.asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .leading))))
        }
    }

    private var liveText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(format.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .transaction { $0.animation = nil }
            Text(valueText)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(valueOpacity))
                .lineLimit(1).fixedSize()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.12), value: valueText)
        }
    }

    private var successRow: some View {
        HStack(spacing: 7) {
            Text("Copied").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            Image(systemName: "checkmark.circle").font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(0.8)).symbolEffect(.bounce, value: isSuccess)
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
    /// Custom mask on the blur view's layer. We use CAShapeLayer instead
    /// of cornerRadius + masksToBounds because NSVisualEffectView's
    /// corner mask does not interpolate its path during a CABasicAnimation
    /// on bounds — the freshly-uncovered region renders with sharp
    /// corners until the animation completes. Owning the mask layer lets
    /// us animate its `path` in lockstep with the panel resize.
    private weak var blurMask: CAShapeLayer?
    /// Dark fill + 1pt white border, drawn from the same path as the
    /// mask so both edges stay aligned through the resize animation.
    private weak var cardShape: CAShapeLayer?
    private let cornerRadius: CGFloat = 12

    private func roundedRectPath(size: CGSize) -> CGPath {
        CGPath(
            roundedRect: NSRect(origin: .zero, size: size),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius,
            transform: nil
        )
    }

    deinit {
        // Cancel any pending auto-hide so it can't fire into a dangling instance,
        // and tear down the panel deterministically.
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private(set) var currentFormat: HUDColorFormat = .hex
    private var currentPhase: ColorPickerHUDPhase = .hidden
    private var currentMagnifier: MagnifierData = .empty

    // Tracks the measured size of the SwiftUI content so positioning uses the
    // real visible bounds, not a hardcoded guess (content is .fixedSize() so
    // the panel has a transparent tail when the panel width > content width).
    private var hudSize = CGSize(width: 240, height: 62)

    private let sideGap:     CGFloat = 18
    private let verticalGap: CGFloat = 14
    private let hysteresis:  CGFloat = 24

    private enum HUDSide         { case right, left  }
    private enum HUDVerticalSide { case below, above }
    private var hudSide:         HUDSide         = .right
    private var hudVerticalSide: HUDVerticalSide = .below
    private var hudMagnifierOnRight = false

    // MARK: - Public API

    func setFormat(_ format: HUDColorFormat) {
        currentFormat = format
        refreshContent()
    }

    func beginSession(format: HUDColorFormat) {
        currentFormat = format
        currentPhase  = .idlePlaceholder
        currentMagnifier = .empty

        hudSide             = .right
        hudVerticalSide     = .below
        hudMagnifierOnRight = false

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

    }

    func update(color: NSColor, cursorPosition: NSPoint, magnifier: MagnifierData?) {
        let newPhase = ColorPickerHUDPhase.livePreview(color)
        let newMag   = magnifier ?? currentMagnifier
        // Only rebuild SwiftUI view tree when content actually changed.
        // moveToPosition always runs so the panel tracks the cursor.
        if newPhase != currentPhase || newMag != currentMagnifier {
            currentPhase     = newPhase
            currentMagnifier = newMag
            refreshContent()
        }
        moveToPosition(cursorPosition)
    }

    func showSuccess(color: NSColor, on screen: NSScreen?, autoHideAfter delay: TimeInterval) {

        currentPhase = .success(color)
        // Animate the resize so the blur layer and panel frame grow in sync
        // with the SwiftUI success-row transition (~spring 0.3s). Without
        // animation NSVisualEffectView flashed for one frame as the layer
        // jumped from the old hudSize straight to the new one.
        refreshContent(animatedResize: true)

        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide(animated: Bool = true) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        currentPhase = .hidden

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

        // cursorPos comes from onColorChanged and can be stale (captured at schedule
        // time, reported after an async pixel read). Use NSEvent.mouseLocation for
        // everything — thresholds, flip decisions, and frame placement.
        let live   = NSEvent.mouseLocation
        guard let screen = screenForPoint(live) ?? NSScreen.main else { return }

        let sf   = screen.visibleFrame
        let size = hudSize      // updated by refreshContent() via intrinsicContentSize
        let safe = sf.insetBy(dx: 8, dy: 8)

        let rightMaxX        = live.x + sideGap + size.width
        let rightOverflows   = rightMaxX > safe.maxX
        let rightComfortable = rightMaxX + hysteresis <= safe.maxX

        let desiredSide: HUDSide
        switch hudSide {
        case .right: desiredSide = rightOverflows   ? .left  : .right
        case .left:  desiredSide = rightComfortable ? .right : .left
        }

        let belowMinY        = live.y - size.height - verticalGap
        let belowOverflows   = belowMinY < safe.minY
        let belowComfortable = belowMinY - hysteresis >= safe.minY

        let desiredVertical: HUDVerticalSide
        switch hudVerticalSide {
        case .below: desiredVertical = belowOverflows   ? .above : .below
        case .above: desiredVertical = belowComfortable ? .below : .above
        }

        let newMagnifierOnRight = (desiredSide == .left)
        if desiredSide != hudSide || newMagnifierOnRight != hudMagnifierOnRight {
            hudSide             = desiredSide
            hudVerticalSide     = desiredVertical
            hudMagnifierOnRight = newMagnifierOnRight
            refreshContent()
        } else {
            hudSide         = desiredSide
            hudVerticalSide = desiredVertical
        }

        panel.setFrame(
            frameOnSide(hudSide, vertical: hudVerticalSide,
                        cursor: live, safe: safe, size: size),
            display: false
        )
    }

    private func frameOnSide(_ side: HUDSide, vertical: HUDVerticalSide,
                              cursor: NSPoint, safe: CGRect, size: CGSize) -> NSRect {
        var x: CGFloat = side == .right ? cursor.x + sideGap
                                        : cursor.x - size.width - sideGap
        var y: CGFloat = vertical == .below ? cursor.y - size.height - verticalGap
                                            : cursor.y + verticalGap
        x = min(max(x, safe.minX), safe.maxX - size.width)
        y = min(max(y, safe.minY), safe.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }


    // MARK: - Panel management

    private func ensurePanel() {
        guard panel == nil else { return }
        // Initial size matches hudSize default; refreshContent() will resize to
        // the actual SwiftUI intrinsicContentSize on the first call.
        let frame = NSRect(origin: .zero, size: hudSize)
        panel = makePanel(frame: frame)
    }

    private func refreshContent(animatedResize: Bool = false) {
        guard let panel else { return }
        guard let rootView = panel.contentView,
              let blur = rootView.subviews.compactMap({ $0 as? NSVisualEffectView }).first
        else { return }

        let view = ColorPickerHUDView(
            phase: currentPhase,
            format: currentFormat,
            magnifier: currentMagnifier,
            magnifierOnRight: hudMagnifierOnRight
        )
        let hosting: NSHostingView<ColorPickerHUDView>
        if let existing = blur.subviews.compactMap({ $0 as? NSHostingView<ColorPickerHUDView> }).first {
            existing.rootView = view
            hosting = existing
        } else {
            hosting = NSHostingView(rootView: view)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            blur.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.topAnchor.constraint(equalTo: blur.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
                hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            ])
        }

        // Sync panel size to the real SwiftUI content size so there is no
        // transparent tail on either side (content uses .fixedSize()).
        // layout() forces a synchronous AppKit + SwiftUI measure pass so
        // intrinsicContentSize is fresh before we read it.
        hosting.layout()
        let ic = hosting.intrinsicContentSize
        guard ic.width  > 0, ic.width  != NSView.noIntrinsicMetric,
              ic.height > 0, ic.height != NSView.noIntrinsicMetric
        else { return }

        let newSize = CGSize(width: ceil(ic.width), height: ceil(ic.height))
        guard abs(newSize.width  - hudSize.width)  > 0.5 ||
              abs(newSize.height - hudSize.height) > 0.5
        else { return }
        hudSize = newSize

        if animatedResize {
            // Anchor the panel to the cursor-facing edges so resizing only
            // grows outward from the side away from the cursor. Avoids the
            // visual jump that frameOnSide(cursor: NSEvent.mouseLocation)
            // would introduce if the mouse drifted between live preview
            // and the success click.
            //
            // - hudSide .right  ⇒ left edge stays put (panel grows right)
            // - hudSide .left   ⇒ right edge stays put (panel grows left)
            // - hudVerticalSide .below ⇒ top edge stays put (NSWindow uses
            //                            bottom-left origin, so y shifts)
            // - hudVerticalSide .above ⇒ bottom edge stays put
            let oldFrame = panel.frame
            let newX: CGFloat = (hudSide == .left)
                ? oldFrame.maxX - newSize.width
                : oldFrame.minX
            let newY: CGFloat = (hudVerticalSide == .below)
                ? oldFrame.maxY - newSize.height
                : oldFrame.minY
            let target = NSRect(x: newX, y: newY,
                                width: newSize.width, height: newSize.height)
            let duration: CFTimeInterval = 0.30
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            let newPath = roundedRectPath(size: newSize)

            // The blur layer's bounds animation is driven by AppKit when the
            // panel resizes via animator(). The mask path and the card's
            // fill/stroke path must follow in the same transaction so the
            // outer rounded edges stay aligned and rounded throughout.
            for layer in [blurMask, cardShape].compactMap({ $0 }) {
                let pathAnim = CABasicAnimation(keyPath: "path")
                pathAnim.fromValue = layer.path
                pathAnim.toValue = newPath
                pathAnim.duration = duration
                pathAnim.timingFunction = timing
                pathAnim.fillMode = .both
                layer.path = newPath
                layer.add(pathAnim, forKey: "path")
            }

            NSAnimationContext.runAnimationGroup { ctx in
                // Match the SwiftUI body's .spring(response: 0.3, ...) timing.
                ctx.duration = duration
                ctx.timingFunction = timing
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setContentSize(newSize)
            let path = roundedRectPath(size: newSize)
            blurMask?.path = path
            cardShape?.path = path
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
        // Round the blur via an explicit CAShapeLayer mask whose path we
        // can animate; cornerRadius + masksToBounds does not animate its
        // shape during NSAnimationContext-driven bounds animations.
        let mask = CAShapeLayer()
        let initialPath = roundedRectPath(size: blur.bounds.size)
        mask.path = initialPath
        blur.layer?.mask = mask
        blurMask = mask
        rootView.addSubview(blur)

        // Dark fill + 1pt border are drawn by a CAShapeLayer that shares
        // its path with the blur mask. Using a shape layer (rather than an
        // NSView with its own cornerRadius/border/shadow) avoids two
        // separate rounded shapes drifting against each other during the
        // resize animation, which manifested as edge artifacts on the
        // freshly-uncovered side.
        let card = CAShapeLayer()
        card.path = initialPath
        card.fillColor = NSColor.black.withAlphaComponent(0.82).cgColor
        card.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        card.lineWidth = 1
        blur.layer?.addSublayer(card)
        cardShape = card
        return p
    }

    private func screenForPoint(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}
