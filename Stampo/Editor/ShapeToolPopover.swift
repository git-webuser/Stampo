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
    /// Selection is routed through the same path the inline tool buttons use,
    /// so blur-source preparation and selection clearing stay identical.
    let select: (EditorTool) -> Void

    @State private var showPopover = false

    /// Family emblem shown while no shape tool is active. The button state
    /// mirrors the actual tool, never a remembered pick: showing the last
    /// shape would promise something a click doesn't deliver (activating a
    /// shape always goes through the popover). (circle.on.square reads the
    /// same but ships only with macOS 26; this twin exists on 15.7.)
    private static let familyGlyph = "square.on.circle"

    /// Outline shapes first; the two special-interior region tools live after a
    /// divider — the same "grid, divider, special options" idiom as macOS
    /// Markup's own popovers.
    static let outlineShapes: [EditorTool] = [
        .rect, .roundedRect, .oval, .polygon, .star, .bubble
    ]
    static let regionTools:   [EditorTool] = [.blur, .loupe]
    static var family: [EditorTool] { outlineShapes + regionTools }

    private var isActive: Bool { Self.family.contains(tool) }

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 3) {
                Image(systemName: isActive ? tool.systemImage : Self.familyGlyph)
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
        .hoverTip("Shapes")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            // Highlight only the actually active shape — nothing on first
            // open or after another tool reset the family.
            ShapePopoverContent(current: isActive ? tool : nil) { picked in
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
    /// The active shape tool, or nil when the family isn't active — then no
    /// cell is highlighted, matching the fact that picking still takes a
    /// click.
    let current: EditorTool?
    let onPick: (EditorTool) -> Void

    /// Cells per grid row. (A triangle is the 3-sided polygon, so it isn't a
    /// separate cell.)
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
