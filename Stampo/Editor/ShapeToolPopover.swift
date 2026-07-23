import SwiftUI

/// Prototype: collapses the shape-family tools — rectangle, oval, blur, loupe —
/// behind one toolbar button that opens a Markup-style popover.
///
/// The four share the same closed-region geometry (corner handles, resize,
/// undo, z-order); they differ only along two axes the popover exposes:
///   • outline shape   — rectangle vs oval
///   • interior fill    — color (rect/oval) · redaction (blur) · magnification (loupe)
///
/// Following the family principle used across the editor rework, the shape
/// family is low-frequency, so it hides behind a popover; the high-frequency
/// line/arrow tool stays visible on the toolbar. Keyboard shortcuts (R/O/B/M)
/// are handled in the canvas independently, so collapsing these buttons only
/// declutters the toolbar — it does not remove direct access.
struct ShapeToolButton: View {
    @Binding var tool: EditorTool
    /// Remembers the last shape chosen so the button emblem still reflects the
    /// family's current pick while an unrelated tool is active.
    @Binding var lastShape: EditorTool
    /// Selection is routed through the same path the inline tool buttons use,
    /// so blur-source preparation and selection clearing stay identical.
    let select: (EditorTool) -> Void

    @State private var showPopover = false

    /// Outline shapes first; the two special-interior region tools live after a
    /// divider — the same "grid, divider, special options" idiom as macOS
    /// Markup's own popovers.
    static let outlineShapes: [EditorTool] = [
        .rect, .roundedRect, .oval, .triangle, .polygon, .star, .bubble
    ]
    static let regionTools:   [EditorTool] = [.blur, .loupe]
    static var family: [EditorTool] { outlineShapes + regionTools }

    private var isActive: Bool { Self.family.contains(tool) }
    /// While a shape tool is active the button shows it; otherwise it shows the
    /// last shape, so the emblem always says what a click-through would draw.
    private var displayed: EditorTool { isActive ? tool : lastShape }

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 3) {
                Image(systemName: displayed.systemImage)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.45)
            }
            .frame(width: 34, height: 22)
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        .hoverTip("Shapes")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ShapePopoverContent(current: displayed) { picked in
                lastShape = picked
                select(picked)
                showPopover = false
            }
        }
    }
}

/// Popover body: two rows of icon-only shape cells split by a divider. Cell
/// names surface as hover tooltips (the same `hoverTip` the toolbar uses), and
/// the current pick is highlighted.
private struct ShapePopoverContent: View {
    let current: EditorTool
    let onPick: (EditorTool) -> Void

    /// Cells per grid row. The odd outline count leaves one empty slot at the
    /// end — reserved for the family's next shape.
    private static let columns = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            grid(ShapeToolButton.outlineShapes)
            Divider()
            grid(ShapeToolButton.regionTools)
        }
        .padding(10)
    }

    private func grid(_ tools: [EditorTool]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: tools.count, by: Self.columns)),
                    id: \.self) { rowStart in
                HStack(spacing: 6) {
                    ForEach(tools[rowStart..<min(rowStart + Self.columns, tools.count)],
                            id: \.self) { cell($0) }
                }
            }
        }
    }

    private func cell(_ t: EditorTool) -> some View {
        Button { onPick(t) } label: {
            Image(systemName: t.systemImage)
                .font(.system(size: 17, weight: .regular))
                .frame(width: 44, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(t == current ? Color.accentColor.opacity(0.18)
                                           : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(t == current ? Color.accentColor : .clear, lineWidth: 1.5)
                )
                .foregroundStyle(t == current ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .hoverTip(t.labelKey, shortcut: t.shortcut?.label)
    }
}
