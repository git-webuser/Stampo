import SwiftUI

/// The page's shape, in the toolbar's second row.
///
/// It lives here rather than in the inspector because a format is a decision
/// about the scene — like fit, zoom and rotate, which the top row has always
/// carried — and because it is taken first, before anything worth putting in a
/// panel. The row's rule is unchanged and only stated more precisely: it shows
/// the settings of whatever is selected, and the page is what is selected when
/// nothing else is.
struct CanvasRatioBar: View {
    let document: EditorDocument

    /// Chips carry the ratio as text. An icon set was measured and rejected:
    /// `rectangle.ratio.*` exists only for 16:9, 9:16, 4:3 and 3:4, so half the
    /// row would have had to be faked — and a 16pt rectangle does not tell 3:4
    /// from 4:5 anyway, which is exactly why the inspector's proportional tiles
    /// were dropped.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(chips: chipRow)
            row(chips: collapsedChips)
        }
    }

    private func row(chips: some View) -> some View {
        HStack(spacing: 8) {
            chips
            if !isAuto {
                swapButton
            }
            Divider().frame(height: 18)
            sizeFields
        }
    }

    // MARK: Chips

    private var chipRow: some View {
        HStack(spacing: 4) {
            chip(title: LocaleManager.shared.string("Auto"),
                 tooltip: "Auto",
                 isSelected: isAuto) {
                document.setAutoPage()
            }
            ForEach(Array(CanvasRatio.presets.enumerated()), id: \.offset) { _, preset in
                let shown = asShown(preset)
                chip(title: CanvasRatio.label(for: CGSize(width: shown.width,
                                                          height: shown.height)),
                     tooltip: preset.titleKey,
                     tooltipDetail: pageSizeLabel(for: shown),
                     isSelected: !isAuto && isCurrent(preset)) {
                    document.setCanvasRatio(shown)
                }
            }
        }
    }

    /// Everything the wide row has, behind one button — for a window too narrow
    /// to lay the chips out. Same grid, same order, in the idiom the shapes
    /// tool already uses: a button that shows the current pick and opens a
    /// popover of the rest.
    private var collapsedChips: some View {
        CanvasRatioMenuButton(document: document,
                              current: currentLabel,
                              isAuto: isAuto,
                              canvasSize: canvasSize)
    }

    private func chip(title: String,
                      tooltip: String,
                      tooltipDetail: String? = nil,
                      isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .hoverTip(tooltip, shortcut: tooltipDetail)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Swap

    /// Not a rotation and not a rotation glyph. The top row already turns the
    /// *picture*; a second rotate one row below would leave the user guessing
    /// which of the two turns what. Swapping the sides is a different verb and
    /// wears a different mark — and it is why the row needs one chip per ratio
    /// instead of the two every other tool prints (4:3 *and* 3:4).
    private var swapButton: some View {
        Button {
            guard let ratio = CanvasRatio.typed(width: canvasSize.height, height: canvasSize.width)
            else { return }
            document.setCanvasRatio(ratio)
        } label: {
            Image(systemName: "arrow.down.left.arrow.up.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .hoverTip("Swap Sides")
    }

    // MARK: Size

    /// The page's two numbers — the same pair that used to sit in the
    /// inspector's Canvas section, and the same behaviour: on an auto page the
    /// margins take up the difference, on a fixed page the size simply becomes
    /// what you typed. Only their address changed.
    ///
    /// 70 points wide, not 54: a bezeled field spends about 26 points on its
    /// own insets, so a four-digit number asks for ~58 and a narrower frame
    /// silently drops the last digit — measured on screen, where the field
    /// truncates without an ellipsis and reads as a different number.
    private var sizeFields: some View {
        let size = canvasSize
        return HStack(spacing: 6) {
            NumberField(value: .constant(Double(max(1, size.width.rounded()))),
                        alignment: .center) { typed in
                document.setCanvasDimension(.width, to: Int(typed))
            }
            .frame(width: 70)
            .hoverTip("Width")
            Text(verbatim: "×").foregroundStyle(.secondary).fixedSize()
            NumberField(value: .constant(Double(max(1, size.height.rounded()))),
                        alignment: .center) { typed in
                document.setCanvasDimension(.height, to: Int(typed))
            }
            .frame(width: 70)
            .hoverTip("Height")
        }
    }

    // MARK: Reading the page

    private var canvasSize: CGSize {
        PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                   document.presentation).canvasSize
    }

    private var isAuto: Bool {
        guard let presentation = document.presentation else { return true }
        if case .auto = presentation.canvas { return true }
        return false
    }

    /// What the collapsed button prints. A derived page rarely reduces to the
    /// ratio that made it — 5:4 comes out as 2736×2189, which reduces to
    /// nothing and reads as "1.25:1" — so the format's own numbers win whenever
    /// the page is in one.
    private var currentLabel: String {
        if isAuto { return LocaleManager.shared.string("Auto") }
        if let preset = CanvasRatio.preset(matching: canvasSize) {
            let shown = CanvasRatio.shown(preset, matching: canvasSize)
            return CanvasRatio.label(for: CGSize(width: shown.width, height: shown.height))
        }
        return CanvasRatio.label(for: canvasSize)
    }

    /// A turned format is still that format, so the chip stays lit either way
    /// round.
    private func isCurrent(_ preset: CanvasRatio) -> Bool {
        preset.matches(canvasSize) || preset.swapped.matches(canvasSize)
    }

    /// The lit chip tells the truth about the page; the rest stay as written —
    /// see `CanvasRatio.shown`.
    private func asShown(_ preset: CanvasRatio) -> CanvasRatio {
        isAuto ? preset : CanvasRatio.shown(preset, matching: canvasSize)
    }

    /// The size this chip would actually make out of *this* picture — the one
    /// fact a ratio cannot tell you, and the one the old pixel presets got
    /// wrong by imposing 1080.
    private func pageSizeLabel(for ratio: CanvasRatio) -> String? {
        guard let presentation = document.presentation else { return nil }
        let layout = PresentationLayout.resolve(imagePixelSize: document.pixelSize, presentation)
        let page = CanvasRatio.page(for: ratio, in: layout)
        guard page.width > 0, page.height > 0 else { return nil }
        return "\(Int(page.width.rounded()))×\(Int(page.height.rounded()))"
    }
}

/// The collapsed chips: current pick plus a popover with the whole set.
private struct CanvasRatioMenuButton: View {
    let document: EditorDocument
    let current: String
    let isAuto: Bool
    let canvasSize: CGSize

    @State private var showPopover = false

    var body: some View {
        Button { showPopover = true } label: {
            HStack(spacing: 3) {
                Text(verbatim: current)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.45)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .hoverTip("Canvas")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                cell(title: LocaleManager.shared.string("Auto"),
                     tooltip: "Auto",
                     isSelected: isAuto) {
                    document.setAutoPage()
                }
                Divider()
                ForEach(Array(CanvasRatio.presets.enumerated()), id: \.offset) { _, preset in
                    let selected = !isAuto && (preset.matches(canvasSize)
                                               || preset.swapped.matches(canvasSize))
                    let shown = isAuto ? preset : CanvasRatio.shown(preset, matching: canvasSize)
                    cell(title: CanvasRatio.label(for: CGSize(width: shown.width,
                                                              height: shown.height)),
                         tooltip: preset.titleKey,
                         isSelected: selected) {
                        document.setCanvasRatio(shown)
                    }
                }
            }
            .padding(10)
        }
    }

    private func cell(title: String,
                      tooltip: String,
                      isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            action()
            showPopover = false
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 12)
                Text(LocalizedStringKey(tooltip))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(width: 200, height: 26, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
