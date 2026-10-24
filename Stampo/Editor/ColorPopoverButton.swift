import SwiftUI

/// The annotation colour in the settings line: the row of swatches, or — once
/// the Arc card is too narrow for the widest line — the one button that opens
/// the same row in a popover. The environment decides, so every tool shows
/// the same form in a given window.
struct AnnotationColorControl: View {
    @Environment(\.settingsRowCompact) private var compact
    /// The selected annotation's colour, else the tool's.
    let active: AnnotationColor
    let pick: (AnnotationColor) -> Void

    var body: some View {
        if compact {
            ColorPopoverButton(active: active, pick: pick)
        } else {
            ColorSwatchRow(active: active, pick: pick)
        }
    }
}

/// The seven preset colours as 24pt targets. Shown inline in the settings
/// line and again inside `ColorPopoverButton`'s popover, with one behaviour.
struct ColorSwatchRow: View {
    let active: AnnotationColor
    let pick: (AnnotationColor) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(AnnotationColor.presets.enumerated()), id: \.offset) { index, preset in
                Button {
                    pick(preset)
                } label: {
                    // 18pt of colour in a 24pt target: at 14pt the chips were
                    // easy to miss, and the space between them caught nothing.
                    Circle()
                        .fill(Color(nsColor: preset.nsColor))
                        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                        .overlay {
                            if active == preset {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTip(EditorView.annotationColorNames[index])
                // The accent ring is the only thing marking the current
                // colour, and a ring is not a thing VoiceOver reads.
                .accessibilityAddTraits(active == preset ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityLabel("Color")
    }
}

/// The current colour as a dot and a chevron. A click opens the swatch row, a
/// pick closes it — the same shape as `ShapeToolButton`, whose popover this
/// follows.
struct ColorPopoverButton: View {
    let active: AnnotationColor
    let pick: (AnnotationColor) -> Void

    @State private var showPopover = false

    /// The preset's name in the in-app language, for VoiceOver: the dot says
    /// nothing to it. A colour outside the presets has no name to give.
    private var activeName: String {
        AnnotationColor.presets.firstIndex(of: active)
            .map { tooltipText(EditorView.annotationColorNames[$0]) } ?? ""
    }

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(nsColor: active.nsColor))
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                    .frame(width: 16, height: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.45)
            }
            // The bordered style adds 4pt above and below: 24pt in all, the
            // height of the pickers beside it in the row.
            .frame(width: 34, height: 16)
        }
        .buttonStyle(.bordered)
        .accessibilityValue(Text(verbatim: activeName))
        .hoverTip("Color")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ColorSwatchRow(active: active) { preset in
                pick(preset)
                showPopover = false
            }
            .padding(8)
        }
    }
}
