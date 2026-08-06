import SwiftUI

/// Collapses the freehand family — pen and marker brushes plus the eraser —
/// behind one toolbar popover button, following the shape-family pattern:
/// the emblem and cell highlights mirror the actual tool state, never a
/// remembered pick.
///
/// Cell anatomy: an instrument image (flat art from the asset catalog when
/// present, an SF Symbol placeholder until then) followed by a live stroke
/// trace rendered with the same midpoint-quadratic smoothing the canvas'
/// freehand renderer uses, tinted with the current tool color — the trace
/// cannot lie about what the brush lays down. The eraser is pinned below a
/// divider: it erases freehand strokes only, so its trace fades away.
struct DrawingToolButton: View {
    @Binding var tool: EditorTool
    @Binding var drawingMode: DrawingMode
    /// Current tool color; tints the brush traces in the popover.
    let strokeColor: Color
    /// Current marker nib — the marker's trace renders with its real cap.
    let markerTip: MarkerTip
    /// Selection is routed through the same path the inline tool buttons use.
    let select: (EditorTool) -> Void

    @State private var showPopover = false

    /// Family emblem shown while neither drawing nor eraser is active.
    private static let familyGlyph = "scribble"

    private var isActive: Bool { tool == .drawing || tool == .eraser }

    private var emblem: String {
        guard isActive else { return Self.familyGlyph }
        if tool == .eraser { return "eraser" }
        return drawingMode == .pen ? "pencil.tip" : "highlighter"
    }

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 3) {
                Image(systemName: emblem)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.45)
            }
            .frame(width: 34, height: 22)
        }
        .buttonStyle(.borderless)
        .toolbarKeyboardFocus { showPopover = true }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .hoverTip("Drawing")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            DrawingPopoverContent(
                activeBrush: tool == .drawing ? drawingMode : nil,
                eraserActive: tool == .eraser,
                strokeColor: strokeColor,
                markerTip: markerTip
            ) { picked in
                switch picked {
                case .brush(let mode):
                    drawingMode = mode
                    select(.drawing)
                case .eraser:
                    select(.eraser)
                }
                showPopover = false
            }
        }
    }

    enum Pick {
        case brush(DrawingMode)
        case eraser
    }
}

/// Popover body: one wide row per brush (instrument + live trace), the
/// eraser pinned below a divider. Only the actually active row is
/// highlighted — nothing on first open.
private struct DrawingPopoverContent: View {
    let activeBrush: DrawingMode?
    let eraserActive: Bool
    let strokeColor: Color
    let markerTip: MarkerTip
    let onPick: (DrawingToolButton.Pick) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            brushRow(.pen)
            brushRow(.marker)
            Divider()
            eraserRow
        }
        .padding(10)
    }

    private func brushRow(_ mode: DrawingMode) -> some View {
        let labelKey = mode == .pen ? "Pen" : "Marker"
        return row(active: activeBrush == mode, labelKey: labelKey) {
            onPick(.brush(mode))
        } content: {
            InstrumentImage(assetName: mode == .pen ? "ToolBrushPen"
                                                    : "ToolBrushMarker",
                            fallbackSymbol: mode == .pen ? "pencil.tip"
                                                         : "highlighter")
            StrokeTrace(style: mode.freehandStyle, color: strokeColor,
                        tip: markerTip)
        }
    }

    private var eraserRow: some View {
        row(active: eraserActive, labelKey: "Eraser",
            shortcut: EditorTool.eraser.shortcut?.label) {
            onPick(.eraser)
        } content: {
            InstrumentImage(assetName: "ToolBrushEraser",
                            fallbackSymbol: "eraser")
            StrokeTrace(style: .pen, color: .secondary, fadesOut: true)
        }
    }

    private func row(active: Bool, labelKey: String, shortcut: String? = nil,
                     onTap: @escaping () -> Void,
                     @ViewBuilder content: () -> some View) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 8)
            .frame(width: 148, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.18)
                                 : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Color.accentColor : .clear,
                                  lineWidth: 1.5)
            )
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .hoverTip(labelKey, shortcut: shortcut)
    }
}

/// Flat instrument art from the asset catalog — a drop-in from Figma:
/// template-rendered vector named ToolBrushPen / ToolBrushMarker /
/// ToolBrushEraser, drawn horizontally with the working tip pointing right,
/// toward the trace. Until the asset exists, an SF Symbol stands in, so
/// swapping in the art needs no code change.
private struct InstrumentImage: View {
    let assetName: String
    let fallbackSymbol: String

    var body: some View {
        if NSImage(named: assetName) != nil {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 20)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 14))
                .frame(width: 28)
        }
    }
}

/// A live sample stroke drawn with the brush's real characteristics — the
/// same midpoint-quadratic smoothing `AnnotationRenderer.drawFreehand`
/// uses — so the preview shows exactly what the brush lays down: solid for
/// the pen, translucent for the marker. `fadesOut` renders the eraser's
/// "trace": a stroke dissolving to nothing.
struct StrokeTrace: View {
    let style: FreehandStyle
    let color: Color
    /// Marker nib; pens always draw round.
    var tip: MarkerTip = .round
    var fadesOut = false

    var body: some View {
        Canvas { context, size in
            let points = Self.samplePoints(in: size)
            var path = Path()
            path.move(to: points[0])
            for index in 1..<(points.count - 1) {
                let control = points[index]
                let next = points[index + 1]
                let midpoint = CGPoint(x: (control.x + next.x) / 2,
                                       y: (control.y + next.y) / 2)
                path.addQuadCurve(to: midpoint, control: control)
            }
            path.addLine(to: points[points.count - 1])

            let width: CGFloat = style == .marker ? 8 : 3.5
            let squareTip = style == .marker && tip == .square
            let base = color.opacity(style.opacity)
            let shading: GraphicsContext.Shading = fadesOut
                ? .linearGradient(Gradient(colors: [base, base.opacity(0)]),
                                  startPoint: .zero,
                                  endPoint: CGPoint(x: size.width, y: 0))
                : .color(base)
            context.stroke(path, with: shading,
                           style: StrokeStyle(lineWidth: width,
                                              lineCap: squareTip ? .square : .round,
                                              lineJoin: .round))
        }
        .frame(height: 18)
    }

    /// Gentle S-curve spanning the cell, inset so round caps stay inside.
    static func samplePoints(in size: CGSize) -> [CGPoint] {
        let steps = 12
        let inset: CGFloat = 6
        return (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            return CGPoint(x: inset + (size.width - inset * 2) * t,
                           y: size.height / 2 - sin(t * .pi * 2) * size.height * 0.28)
        }
    }
}
