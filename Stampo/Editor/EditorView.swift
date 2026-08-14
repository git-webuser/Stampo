import AppKit
import OSLog
import SwiftUI
import Vision

/// Editor window content: toolbar (tools, style, undo/redo, copy/save) over
/// the annotation canvas. Standard-window styling (accent color), not the
/// dark notch-panel look.
struct EditorView: View {
    /// Keeps every fixed toolbar control visible while allowing Copy/Save
    /// labels to use their compact icon-only variants. The widest context
    /// rows (text with its alignment picker, loupe with its shape picker and
    /// source toggle) set the floor.
    static let minimumContentSize = CGSize(width: 900, height: 360)

    var document: EditorDocument
    /// Wired by EditorWindowController in the save/copy commit; nil disables Save.
    var saveHandler: ((EditorDocument) async -> Bool)?
    /// Save As: runs a save panel, so it reports back through its own sheet
    /// rather than a return value (the toast is shown by the controller).
    var saveAsHandler: ((EditorDocument) async -> Void)?
    /// Delete: the file this document was opened from goes to the Trash and the
    /// window closes. The controller owns both halves; anything the user wanted
    /// to keep out of it (the clipboard copy) happens here first.
    var deleteHandler: ((EditorDocument) -> Void)?

    @State private var tool: EditorTool = .select
    @State private var style = ToolStyle()
    @State private var editingTextID: UUID?
    @State private var zoomFactor: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    /// Pending crop rectangle (image-pixel space) while the crop tool is active.
    @State private var cropRect: CGRect?
    /// ⌥ held over the rotate button — flips its icon to preview direction.
    @State private var rotateOptionHeld = false
    @State private var isPreparingArtifact = false
    /// Where the image sits on screen, reported by the canvas. The scanner
    /// needs it both to place its overlay and to read the selection back.
    @State private var imageScreenGeometry: ImageScreenGeometry?
    /// The very overlay the scan hotkey opens, bounded to the image.
    @State private var scanOverlay = SelectionOverlay()
    /// Whether that overlay is on screen. The completion path dismisses itself,
    /// so this keeps `tool` changing back to `.select` from dismissing it twice.
    @State private var scanOverlayActive = false
    /// The overlay's armed mode, mirrored here so the context bar can follow it.
    @State private var scanMode: ScanSelectionMode = .plain

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contextBar
            Divider()
            EditorCanvasView(
                document: document,
                tool: $tool,
                style: $style,
                editingTextID: $editingTextID,
                zoomFactor: $zoomFactor,
                panOffset: $panOffset,
                cropRect: $cropRect,
                onCropApply: applyCrop,
                onCropCancel: cancelCrop,
                imageScreenGeometry: $imageScreenGeometry
            )
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onChange(of: tool) { _, newTool in
            if newTool == .scan {
                beginScanSelection()
            } else if scanOverlayActive {
                // Left the tool while the overlay was up — the toolbar stays
                // reachable behind it on purpose, so this is a real path.
                scanOverlayActive = false
                scanOverlay.cancel()
            }
        }
        .frame(minWidth: Self.minimumContentSize.width,
               minHeight: Self.minimumContentSize.height)
    }

    private var textEditingActive: Bool { editingTextID != nil }

    // MARK: Toolbar (top row: what you do; bottom row: how it looks)

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolPicker
            Divider().frame(height: 20)
            zoomControls
            fitButton
            Divider().frame(height: 20)
            rotateButtons
            Divider().frame(height: 20)
            cropButton
            Divider().frame(height: 20)
            scanButton
            Spacer(minLength: 8)
            undoRedoButtons
            Divider().frame(height: 20)
            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Toolbar tools, left to right. Two low-frequency families are collapsed
    /// behind popover buttons — shapes (rectangle, oval, polygon, star,
    /// bubble, blur, loupe) and drawing (pen, marker, eraser) — the rest stay
    /// inline. Their keyboard shortcuts still work through the canvas
    /// handler, so this only declutters the row.
    private var toolPicker: some View {
        HStack(spacing: 2) {
            toolButton(.select)
            toolButton(.line)
            toolButton(.arrow)
            ShapeToolButton(tool: $tool, select: selectTool)
            toolButton(.text)
            DrawingToolButton(tool: $tool, drawingMode: $style.drawingMode,
                              strokeColor: Color(nsColor: style.color.nsColor),
                              markerTip: style.markerTip,
                              select: selectTool)
            toolButton(.step)
        }
    }

    private func toolButton(_ t: EditorTool) -> some View {
        Button { selectTool(t) } label: {
            Image(systemName: t.systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: ToolButtonMetrics.width, height: ToolButtonMetrics.height)
        }
        .buttonStyle(.borderless)
        .activeToolChrome(tool == t)
        .hoverTip(t.labelKey, shortcut: t.shortcut?.label)
    }

    /// Shared tool-activation path for the inline buttons and the shape
    /// popover: switches tool, clears any crop frame and selection, and warms
    /// the blur source when entering the blur tool.
    private func selectTool(_ t: EditorTool) {
        tool = t
        cropRect = nil
        if t != .select { document.selectedID = nil }
        if t == .blur {
            document.prepareBlurSource(style: style.blurStyle, level: style.blurLevel)
        }
    }

    /// Second toolbar row: settings for the active tool. A selected
    /// annotation's kind wins over the tool so restyling a selection always
    /// shows the matching controls. Fixed height — switching tools must not
    /// reflow the canvas.
    ///
    /// Every row keeps one order, so the eye finds the same class of control
    /// in the same place whatever the tool: **color, then the discrete
    /// controls** (buttons, segmented pickers, steppers), **then sliders**.
    /// A row that leads with a control and ends in a hint puts a divider
    /// between the two.
    private var contextBar: some View {
        HStack(spacing: 12) {
            if tool == .scan, document.selectedAnnotation == nil {
                // Control first, hint after the divider — the same shape as the
                // select row, where snapping leads and the hint follows.
                lineBreaksPicker
                Divider().frame(height: 18)
                scanHint
            } else if tool == .crop {
                cropSizeControls
            } else if tool == .eraser, document.selectedAnnotation == nil {
                eraseAllButton
                Divider().frame(height: 18)
                settingSlider("Eraser Size", systemImage: "eraser",
                              value: eraserDiameterBinding,
                              range: 8...80, step: 4)
            } else {
                contextControls
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder private var contextControls: some View {
        switch contextKind {
            case .blur:
                blurStylePicker
                settingSlider("Intensity", systemImage: "aqi.medium",
                              value: blurLevelBinding,
                              range: CGFloat(BlurIntensity.range.lowerBound)
                                  ... CGFloat(BlurIntensity.range.upperBound),
                              step: 1)
            case .text:
                colorSwatches
                fontPicker
                settingStepper("Text Size", systemImage: "textformat.size",
                               value: fontSizeBinding, range: 16...96, step: 2)
                Divider().frame(height: 18)
                textControls
            case .freehand:
                // The pen/marker choice lives in the drawing popover — one
                // parameter, one home; the row keeps the per-brush settings.
                colorSwatches
                if effectiveDrawingMode == .marker {
                    markerTipPicker
                }
                let range: ClosedRange<CGFloat> = effectiveDrawingMode == .marker
                    ? 8...64 : 2...32
                settingSlider("Brush Size", systemImage: "lineweight",
                              value: drawingWidthBinding,
                              range: range,
                              step: effectiveDrawingMode == .marker ? 4 : 2)
            case .step:
                colorSwatches
                fontPicker
                settingStepper("Text Size", systemImage: "textformat.size",
                               value: stepLabelSizeBinding,
                               range: 8...stepLabelSizeCap, step: 2)
                settingSlider("Marker Size", systemImage: "circle.circle",
                              value: stepSizeBinding, range: 24...72, step: 8)
            case .loupe:
                colorSwatches
                loupeShapePicker
                loupeModePicker
                // Grouped with the other segmented pickers, ahead of the
                // sliders; only offered while the document has a blur.
                if documentHasBlur {
                    loupeSourcePicker
                }
                thicknessSlider
                settingSlider("Magnification", systemImage: "plus.magnifyingglass",
                              value: loupeScaleBinding, range: 1.5...4, step: 0.5,
                              format: { String(format: "×%.1f", $0) })
            case .line:
                colorSwatches
                lineStylePicker
                thicknessSlider
            case .rect, .oval, .roundedRect:
                colorSwatches
                thicknessSlider
                fillSlider
            case .polygon:
                colorSwatches
                settingStepper("Sides", systemImage: "hexagon",
                               value: polygonSidesBinding,
                               range: CGFloat(ShapeCounts.polygonSides.lowerBound)
                                   ... CGFloat(ShapeCounts.polygonSides.upperBound),
                               step: 1)
                thicknessSlider
                fillSlider
            case .star:
                colorSwatches
                settingStepper("Points", systemImage: "star",
                               value: starPointsBinding,
                               range: CGFloat(ShapeCounts.starPoints.lowerBound)
                                   ... CGFloat(ShapeCounts.starPoints.upperBound),
                               step: 1)
                thicknessSlider
                fillSlider
            case .bubble:
                colorSwatches
                bubbleTailPicker
                thicknessSlider
                fillSlider
            case .arrow:
                colorSwatches
                arrowRoutePicker
                arrowStylePicker
                arrowHeadPlacementPicker
                thicknessSlider
                arrowHeadSizeSlider
            default:
                // Select tool with nothing selected: there is nothing to
                // restyle, so the row offers a hint instead of orphaned
                // controls.
                // `cursorarrow.rays` (a pointer with selection rays) reads as
                // "select", distinct from the arrow tool's plain arrow.
                // pointer.arrow.rays would be closer but is macOS 26-only.
                // Snapping is a document-wide rule (it governs every tool but
                // freehand drawing), so it lives with the cursor rather than
                // in any one annotation's controls.
                snapPicker
                Divider().frame(height: 18)
                Label("Select an annotation to edit its style",
                      systemImage: "cursorarrow.rays")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
        }
    }

    /// What the bottom row configures right now.
    private var contextKind: AnnotationKind? {
        if let selected = document.selectedAnnotation { return selected.kind }
        switch tool {
        case .select, .eraser, .scan, .crop: return nil
        case .line:   return .line
        case .arrow:  return .arrow
        case .rect:   return .rect
        case .oval:   return .oval
        case .roundedRect: return .roundedRect
        case .polygon:  return .polygon
        case .star:     return .star
        case .bubble:   return .bubble
        case .text:   return .text
        case .drawing:return .freehand
        case .blur:   return .blur
        case .step:   return .step
        case .loupe:  return .loupe
        }
    }

    /// String-catalog keys for the preset names, aligned with
    /// `AnnotationColor.presets`.
    private let colorNames: [String] =
        ["Red", "Orange", "Yellow", "Green", "Blue", "Black", "White"]

    /// Which swatch is ringed: the selected annotation's own colour, falling
    /// back to the tool's.
    ///
    /// Reading straight from `style` showed the tool's colour over a selection
    /// painted in another one — a red shape under a ring on blue, and a first
    /// click on blue that appeared to do nothing because the ring was already
    /// there. Every other control in this bar already resolves through the
    /// selection this way (see `lineWidthBinding` and friends); this one was
    /// the exception.
    private var activeColor: AnnotationColor {
        document.selectedAnnotation?.color ?? style.color
    }

    private var colorSwatches: some View {
        HStack(spacing: 5) {
            ForEach(Array(AnnotationColor.presets.enumerated()), id: \.offset) { index, preset in
                Button {
                    style.color = preset
                    applyToSelection { $0.color = preset }
                } label: {
                    Circle()
                        .fill(Color(nsColor: preset.nsColor))
                        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                        .overlay {
                            if activeColor == preset {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                            }
                        }
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .hoverTip(colorNames[index])
                // The accent ring is the only thing marking the current
                // colour, and a ring is not a thing VoiceOver reads.
                .accessibilityAddTraits(activeColor == preset ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityLabel("Color")
    }

    private var blurStylePicker: some View {
        IconSegmentedPicker(
            segments: [
                .init("Pixelate", systemImage: "square.grid.3x3.fill",
                      value: BlurStyle.pixelate),
                .init("Blur", systemImage: "drop.fill",
                      value: BlurStyle.gaussian)
            ],
            selection: blurStyleBinding
        )
        .fixedSize()
        .accessibilityLabel("Blur")
        .hoverTip("Blur Style")
    }

    /// Whether the loupe magnifies the redacted image (default) or the raw
    /// original. Only offered while the document actually has a blur — without
    /// one, the two modes render identically. Icon-only, like the loupe's
    /// other pickers, so the row fits the minimum window width.
    private var loupeSourcePicker: some View {
        Picker("Loupe Source", selection: loupeRevealsOriginalBinding) {
            Image(systemName: "eye.slash").tag(false)
            Image(systemName: "eye").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Loupe Source")
    }

    /// In-place magnifier vs callout (source marker + detached magnifier
    /// joined by a connector).
    private var loupeModePicker: some View {
        Picker("Loupe Mode", selection: loupeCalloutBinding) {
            Image(systemName: "smallcircle.filled.circle").tag(false)
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Loupe Mode")
    }

    /// Which side of a bubble carries the tail — the same icon-only segmented
    /// pattern as the loupe pickers.
    /// Default (right) first, like every other segmented control here. The
    /// segments show which side the tail lands on, so the icons no longer run
    /// left-to-right — consistency of "default leads" won that trade.
    private var bubbleTailPicker: some View {
        Picker("Tail Side", selection: bubbleTailBinding) {
            Image(systemName: "bubble.right").tag(BubbleTailDirection.right)
            Image(systemName: "bubble.left").tag(BubbleTailDirection.left)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Tail Side")
    }

    private var documentHasBlur: Bool {
        document.annotations.contains { $0.kind == .blur }
    }

    /// Marker nib shape — the same icon-only segmented pattern as the loupe
    /// pickers. Offered only while the marker is the effective brush.
    private var markerTipPicker: some View {
        Picker("Marker Tip", selection: markerTipBinding) {
            Image(systemName: "circle.fill").tag(MarkerTip.round)
            Image(systemName: "square.fill").tag(MarkerTip.square)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Marker Tip")
    }

    /// Deletes every freehand stroke as one undo step; the eraser only ever
    /// touches freehand, so the button scope matches the tool's. Icon-only
    /// and sized to sit level with the row's segmented controls.
    /// (`eraser.badge.xmark` reads best but ships only with macOS 26;
    /// `eraser.line.dashed` is the closest glyph on 15.7.)
    private var eraseAllButton: some View {
        Button {
            document.eraseAllFreehand()
        } label: {
            Image(systemName: "eraser.line.dashed")
                .font(.system(size: 12))
                .frame(width: 34, height: 22)
        }
        .buttonStyle(.bordered)
        .disabled(!document.annotations.contains { $0.kind == .freehand })
        .accessibilityLabel("Erase All")
        .hoverTip("Erase All")
    }

    /// Whether the scanner glues the text back into paragraphs or keeps the
    /// line breaks the scanned layout happened to put in it. Two states with
    /// names, so the same icon-only segmented pattern the rest of the row uses
    /// — a lit/unlit single control would leave "lit means what?" unanswered.
    ///
    /// Joining leads and is selected by default: the breaks belong to the page
    /// the text was read off, not to the text, so keeping them means cleaning
    /// them out by hand wherever it gets pasted. Keeping them is the deliberate
    /// choice, for the blocks where the breaks *are* the content — verse, code,
    /// a column of a table.
    ///
    /// `text.justify` draws a block of text solid; `text.append` draws a line
    /// break inside one. (`text.alignleft` reads as the same shape as justify
    /// but already means left alignment one row over, in the text controls.)
    ///
    /// This row used to be the only way to choose, and said so: the editor drew
    /// its own marquee, so ⌥ would have duplicated a control already on screen.
    /// The editor now opens the same overlay the scan hotkey does, and ⌥ comes
    /// with it whether this row wants it or not. So the two are one setting
    /// seen twice — the overlay opens on what the picker holds, and the picker
    /// follows what ⌥ does. Its selection moving on its own is the point, not
    /// the cost: it is showing what the badge over the pointer already says.
    ///
    /// Disabled while translating, because translation rejoins the lines this
    /// picks regardless. Leaving it live would offer a choice with no outcome.
    private var lineBreaksPicker: some View {
        Picker("Line Breaks", selection: $style.scanJoinsLines) {
            Image(systemName: "text.justify").tag(true)
            Image(systemName: "text.append").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .disabled(scanOverlayActive && scanMode == .translate)
        .hoverTip("Line Breaks")
    }

    /// The scanner's instruction line, which spells out the outcome of the
    /// drag it is describing rather than naming the control again — the
    /// picker's two icons say which state is chosen, not what it produces.
    private var scanHint: some View {
        Label(style.scanJoinsLines
                  ? "Drag to select an area — line breaks removed"
                  : "Drag to select an area — line breaks kept",
              systemImage: "doc.viewfinder")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private var fillSlider: some View {
        settingSlider("Fill", systemImage: "paintbrush.pointed.fill",
                      value: fillOpacityBinding, range: 0...100, step: 5,
                      format: { "\(Int($0))%" })
    }

    /// Outline of the loupe — same segmented pattern as the text background.
    /// A circle is the shift-locked case of the oval, so it isn't a segment.
    private var loupeShapePicker: some View {
        Picker("Loupe Shape", selection: loupeShapeBinding) {
            Image(systemName: "oval").tag(LoupeShape.oval)
            Image(systemName: "rectangle").tag(LoupeShape.roundedRect)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Loupe Shape")
    }

    // MARK: Text formatting controls

    /// Compact menu whose rows are rendered with the font they select — the
    /// name alone is the sample, keeping the menu visually quiet.
    private var fontPicker: some View {
        Picker("Font", selection: fontPresetBinding) {
            ForEach(AnnotationFontPreset.allCases) { preset in
                Text(verbatim: preset.displayName)
                    .font(Font(preset.nsFont(ofSize: 13)))
                    .tag(preset)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 142)
        .hoverTip("Font")
    }

    private var textControls: some View {
        HStack(spacing: 4) {
            formatToggle("Bold", systemImage: "bold", shortcut: "⌘B", binding: boldBinding)
            formatToggle("Italic", systemImage: "italic", shortcut: "⌘I", binding: italicBinding)
            formatToggle("Underline", systemImage: "underline", shortcut: "⌘U",
                         binding: underlineBinding)
            formatToggle("Strikethrough", systemImage: "strikethrough", shortcut: "⇧⌘X",
                         binding: strikethroughBinding)
            formatToggle("Text Shadow", systemImage: "shadow", shortcut: "⇧⌘H",
                         binding: textShadowBinding)
            Divider().frame(height: 18)
            Picker("Text Background", selection: textBackgroundBinding) {
                Image(systemName: "square.slash").tag(TextBackground.none)
                Image(systemName: "square.fill").tag(TextBackground.dark)
                Image(systemName: "square").tag(TextBackground.light)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)
            .hoverTip("Text Background")
            Picker("Text Alignment", selection: textAlignmentBinding) {
                Image(systemName: "text.alignleft").tag(TextAlign.left)
                Image(systemName: "text.aligncenter").tag(TextAlign.center)
                Image(systemName: "text.alignright").tag(TextAlign.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)
            .hoverTip("Text Alignment")
        }
    }

    private func formatToggle(_ label: String, systemImage: String, shortcut: String,
                              binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: {
            Image(systemName: systemImage).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(binding.wrappedValue ? Color.accentColor.opacity(0.22) : .clear)
        )
        .foregroundStyle(binding.wrappedValue ? Color.accentColor : Color.primary)
        .hoverTip(label, shortcut: shortcut)
    }

    private var arrowStylePicker: some View {
        Picker("Arrow Style", selection: arrowStyleBinding) {
            Text(verbatim: "→").tag(ArrowStyle.filled)
            Text(verbatim: "⇢").tag(ArrowStyle.dashed)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Arrow Style")
    }

    /// Free placement vs. snapping to the layout grid. Elbowed arrows put
    /// their legs and endpoints on this grid; free mode drops the quantization
    /// for pixel-exact placement.
    /// Grid first, free second: every other segmented control in this row puts
    /// its default in the leading segment, and snapping is on by default.
    private var snapPicker: some View {
        Picker("Snapping", selection: $style.snapsToGrid) {
            Image(systemName: "grid").tag(true)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Snapping")
    }

    /// How the arrow travels — a bendable shaft or an axis-aligned run. A
    /// separate axis from the stroke's appearance, so it gets its own control.
    private var arrowRoutePicker: some View {
        Picker("Arrow Route", selection: arrowRouteBinding) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .tag(ArrowRoute.curved)
            Image(systemName: "arrow.turn.right.down").tag(ArrowRoute.elbowed)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Arrow Route")
    }

    private var arrowHeadPlacementPicker: some View {
        Picker("Arrow Heads", selection: arrowHeadPlacementBinding) {
            Text(verbatim: "←").tag(ArrowHeadPlacement.start)
            Text(verbatim: "→").tag(ArrowHeadPlacement.end)
            Text(verbatim: "↔").tag(ArrowHeadPlacement.both)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 108)
        .hoverTip("Arrow Heads")
    }

    private var lineStylePicker: some View {
        Picker("Line Style", selection: lineStyleBinding) {
            Text(verbatim: "━").tag(LineStyle.solid)
            Text(verbatim: "┅").tag(LineStyle.dashed)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 76)
        .hoverTip("Line Style")
    }

    /// Arrowhead size as a multiplier on what the stroke width already gives.
    /// A multiplier rather than a length: the head is meant to stay
    /// proportionate to the shaft, and this only says by how much.
    private var arrowHeadSizeSlider: some View {
        settingSlider("Head Size", systemImage: "arrowtriangle.right",
                      value: arrowHeadScaleBinding, range: 0.5...2, step: 0.25,
                      // %g, not %.2g: two significant digits would print the
                      // ×1.25 detent as "×1.2".
                      format: { String(format: "×%g", $0) })
    }

    private var thicknessSlider: some View {
        settingSlider("Thickness", systemImage: "lineweight",
                      value: thicknessBinding, range: 4...32, step: 4)
    }

    /// Icon + slider. Visually continuous (no tick marks), but the knob still
    /// lands on discrete detents: the set path snaps every raw value to the
    /// step grid. `format` adds a trailing readout.
    private func settingSlider(
        _ label: String, systemImage: String,
        value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat,
        format: ((CGFloat) -> String)? = nil
    ) -> some View {
        let snapped = Binding<CGFloat>(
            get: { value.wrappedValue },
            set: { raw in
                let detents = ((raw - range.lowerBound) / step).rounded()
                value.wrappedValue = min(range.upperBound,
                                         range.lowerBound + detents * step)
            }
        )
        return HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: snapped, in: range, onEditingChanged: sliderEditingChanged)
                .controlSize(.small)
                .frame(width: 140)
            if let format {
                Text(format(value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .hoverTip(label)
    }

    /// Icon + minus/value/plus — the discrete counterpart of `settingSlider`
    /// for values adjusted in a few labelled steps.
    private func settingStepper(
        _ label: String, systemImage: String,
        value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat,
        format: ((CGFloat) -> String)? = nil
    ) -> some View {
        SettingStepper(label: label, systemImage: systemImage, value: value,
                       range: range, step: step, format: format,
                       bracket: sliderEditingChanged)
    }

    /// Minus/value/plus control. Buttons repeat while held; a double-click on
    /// the value swaps it for a field to type an exact number (Return or
    /// clicking away commits, non-numeric input is discarded). Each tick or
    /// typed commit is bracketed into one undo step via `bracket`.
    private struct SettingStepper: View {
        let label: String
        let systemImage: String
        @Binding var value: CGFloat
        let range: ClosedRange<CGFloat>
        let step: CGFloat
        var format: ((CGFloat) -> String)?
        var bracket: (Bool) -> Void

        @State private var draft: String?
        @FocusState private var draftFocused: Bool

        var body: some View {
            HStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
                stepButton("minus", enabled: value > range.lowerBound) {
                    commit(value - step)
                }
                valueReadout
                stepButton("plus", enabled: value < range.upperBound) {
                    commit(value + step)
                }
            }
            .hoverTip(label)
        }

        @ViewBuilder private var valueReadout: some View {
            if draft != nil {
                TextField("", text: Binding(get: { draft ?? "" },
                                            set: { draft = $0 }))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 34)
                    .focused($draftFocused)
                    .onSubmit { commitDraft() }
                    .onChange(of: draftFocused) { _, focused in
                        if !focused { commitDraft() }   // click-away commits
                    }
            } else {
                Text((format ?? { "\(Int($0.rounded()))" })(value))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 34)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        draft = "\(Int(value.rounded()))"
                        draftFocused = true
                    }
            }
        }

        private func stepButton(_ symbol: String, enabled: Bool,
                                action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .buttonRepeatBehavior(.enabled)
            .disabled(!enabled)
        }

        private func commitDraft() {
            guard let text = draft else { return }
            draft = nil
            guard let typed = Double(text.replacingOccurrences(of: ",", with: "."))
            else { return }
            commit(CGFloat(typed))
        }

        private func commit(_ raw: CGFloat) {
            let clamped = min(range.upperBound, max(range.lowerBound, raw))
            bracket(true)
            value = clamped
            bracket(false)
        }
    }

    /// One undo step per slider gesture when it restyles a selection: the
    /// bindings mutate the document directly; begin/commit bracket the drag.
    private func sliderEditingChanged(_ began: Bool) {
        guard document.selectedID != nil else { return }
        if began { document.beginChange() } else { document.commitChange() }
    }

    private var arrowHeadScaleBinding: Binding<CGFloat> {
        Binding(
            get: { document.selectedAnnotation?.arrowHeadScale ?? style.arrowHeadScale },
            set: { newValue in
                style.arrowHeadScale = newValue
                document.updateSelected { $0.arrowHeadScale = newValue }
            }
        )
    }

    private var thicknessBinding: Binding<CGFloat> {
        Binding(
            get: { document.selectedAnnotation?.lineWidth ?? style.lineWidth },
            set: { newValue in
                style.lineWidth = newValue
                document.updateSelected { $0.lineWidth = newValue }
            }
        )
    }

    private var effectiveDrawingMode: DrawingMode {
        if let selected = document.selectedAnnotation, selected.kind == .freehand {
            return DrawingMode(selected.freehandStyle)
        }
        return style.drawingMode
    }

    /// Like the width slider, the tip applies to the style and to a selected
    /// marker stroke — it's a stroke attribute, not an instrument switch.
    private var markerTipBinding: Binding<MarkerTip> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation,
                   selected.kind == .freehand, selected.freehandStyle == .marker {
                    return selected.markerTip
                }
                return style.markerTip
            },
            set: { newValue in
                style.markerTip = newValue
                document.updateSelected {
                    if $0.kind == .freehand, $0.freehandStyle == .marker {
                        $0.markerTip = newValue
                    }
                }
            }
        )
    }

    private var drawingWidthBinding: Binding<CGFloat> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .freehand {
                    return selected.lineWidth
                }
                return style.width(for: effectiveDrawingMode)
            },
            set: { newValue in
                switch effectiveDrawingMode {
                case .pen:    style.penWidth = newValue
                case .marker: style.markerWidth = newValue
                }
                document.updateSelected {
                    if $0.kind == .freehand { $0.lineWidth = newValue }
                }
            }
        )
    }

    private var eraserDiameterBinding: Binding<CGFloat> {
        Binding(
            get: { style.eraserDiameter },
            set: { style.eraserDiameter = $0 }
        )
    }

    private var effectiveBlurStyle: BlurStyle {
        document.selectedAnnotation?.kind == .blur
            ? (document.selectedAnnotation?.blurStyle ?? style.blurStyle)
            : style.blurStyle
    }

    private var effectiveBlurLevel: Int {
        document.selectedAnnotation?.kind == .blur
            ? (document.selectedAnnotation?.blurLevel ?? style.blurLevel)
            : style.blurLevel
    }

    private var blurStyleBinding: Binding<BlurStyle> {
        Binding(
            get: { effectiveBlurStyle },
            set: { newValue in
                style.blurStyle = newValue
                document.prepareBlurSource(style: newValue, level: effectiveBlurLevel)
                applyToSelection { if $0.kind == .blur { $0.blurStyle = newValue } }
            }
        )
    }

    private var blurLevelBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(effectiveBlurLevel) },
            set: { newValue in
                let level = BlurIntensity.clamped(Int(newValue.rounded()))
                style.blurLevel = level
                document.prepareBlurSource(style: effectiveBlurStyle, level: level)
                document.updateSelected { if $0.kind == .blur { $0.blurLevel = level } }
            }
        )
    }

    private var fontSizeBinding: Binding<CGFloat> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .text {
                    return selected.fontSize
                }
                return style.fontSize ?? document.autoFontSize
            },
            set: { raw in
                let newValue = (raw / 2).rounded() * 2   // continuous slider, 2pt detents
                style.fontSize = newValue
                document.updateSelected {
                    guard $0.kind == .text else { return }
                    $0.fontSize = newValue
                    resizeTextBounds(&$0)
                }
            }
        )
    }

    private var fontPresetBinding: Binding<AnnotationFontPreset> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation,
                   selected.kind == .text || selected.kind == .step {
                    return selected.fontPreset
                }
                return style.fontPreset
            },
            set: { newValue in
                style.fontPreset = newValue
                applyToSelection {
                    guard $0.kind == .text || $0.kind == .step else { return }
                    $0.fontPreset = newValue
                    if $0.kind == .text { resizeTextBounds(&$0) }
                }
            }
        )
    }

    /// Re-fits a text annotation's export bounds to its current content and
    /// style. Called after any change that affects glyph metrics.
    private func resizeTextBounds(_ a: inout Annotation) {
        let size = AnnotationRenderer.measureText(a)
        a.end = CGPoint(x: a.start.x + size.width, y: a.start.y + size.height)
    }

    /// Toggles one text style flag on the current style and selection, as a
    /// single undoable step, keeping bounds in sync.
    private func textFlagBinding(_ keyPath: WritableKeyPath<ToolStyle, Bool>,
                                 _ annotationPath: WritableKeyPath<Annotation, Bool>)
        -> Binding<Bool>
    {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .text {
                    return selected[keyPath: annotationPath]
                }
                return style[keyPath: keyPath]
            },
            set: { newValue in
                style[keyPath: keyPath] = newValue
                applyToSelection {
                    guard $0.kind == .text else { return }
                    $0[keyPath: annotationPath] = newValue
                    resizeTextBounds(&$0)
                }
            }
        )
    }

    private var boldBinding: Binding<Bool> { textFlagBinding(\.bold, \.bold) }
    private var italicBinding: Binding<Bool> { textFlagBinding(\.italic, \.italic) }
    private var underlineBinding: Binding<Bool> { textFlagBinding(\.underline, \.underline) }
    private var strikethroughBinding: Binding<Bool> { textFlagBinding(\.strikethrough, \.strikethrough) }
    private var textShadowBinding: Binding<Bool> { textFlagBinding(\.textShadow, \.textShadow) }

    private var textBackgroundBinding: Binding<TextBackground> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .text {
                    return selected.textBackground
                }
                return style.textBackground
            },
            set: { newValue in
                style.textBackground = newValue
                applyToSelection {
                    guard $0.kind == .text else { return }
                    $0.textBackground = newValue
                    resizeTextBounds(&$0)
                }
            }
        )
    }

    private var textAlignmentBinding: Binding<TextAlign> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .text {
                    return selected.textAlignment
                }
                return style.textAlignment
            },
            set: { newValue in
                style.textAlignment = newValue
                applyToSelection {
                    if $0.kind == .text { $0.textAlignment = newValue }
                }
            }
        )
    }

    /// Largest label size that still fits the current step context — the
    /// stepper's ceiling, and the automatic size while no override is set.
    private var stepLabelSizeCap: CGFloat {
        let selected = document.selectedAnnotation?.kind == .step
            ? document.selectedAnnotation : nil
        return AnnotationRenderer.stepFontSize(
            label: selected?.stepLabel ?? document.nextStepLabel,
            diameter: selected?.stepDiameter ?? style.stepDiameter,
            fontPreset: selected?.fontPreset ?? style.fontPreset
        )
    }

    private var stepLabelSizeBinding: Binding<CGFloat> {
        Binding(
            get: {
                let cap = stepLabelSizeCap
                if let selected = document.selectedAnnotation, selected.kind == .step {
                    return min(selected.stepLabelSize ?? cap, cap)
                }
                return min(style.stepLabelSize ?? cap, cap)
            },
            set: { newValue in
                let clamped = min(newValue, stepLabelSizeCap)
                style.stepLabelSize = clamped
                document.updateSelected {
                    if $0.kind == .step { $0.stepLabelSize = clamped }
                }
            }
        )
    }

    private var stepSizeBinding: Binding<CGFloat> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .step {
                    return selected.stepDiameter
                }
                return style.stepDiameter
            },
            set: { newValue in
                style.stepDiameter = newValue
                document.updateSelected { if $0.kind == .step { $0.stepDiameter = newValue } }
            }
        )
    }

    private var loupeScaleBinding: Binding<CGFloat> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .loupe {
                    return selected.loupeScale
                }
                return style.loupeScale
            },
            set: { rawValue in
                let newValue = (rawValue * 2).rounded() / 2   // 0.5× detents
                style.loupeScale = newValue
                // Magnification is the content zoom only — neither the marker
                // nor the magnifier frame moves.
                document.updateSelected { if $0.kind == .loupe { $0.loupeScale = newValue } }
            }
        )
    }

    private var loupeShapeBinding: Binding<LoupeShape> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .loupe {
                    return selected.loupeShape
                }
                return style.loupeShape
            },
            set: { newValue in
                style.loupeShape = newValue
                applyToSelection {
                    if $0.kind == .loupe { $0.loupeShape = newValue }
                }
            }
        )
    }

    private var loupeCalloutBinding: Binding<Bool> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .loupe {
                    return selected.loupeSource != nil
                }
                return style.loupeCallout
            },
            set: { newValue in
                style.loupeCallout = newValue
                let pixel = document.pixelSize
                applyToSelection {
                    guard $0.kind == .loupe else { return }
                    guard newValue else {
                        $0.loupeSource = nil; $0.loupeSourceSize = nil; return
                    }
                    guard $0.loupeSource == nil else { return }
                    // The marker stays put where the loupe was aimed, sized to
                    // frame the magnified region (display ÷ scale); the
                    // magnifier jumps diagonally aside (clamped to the image)
                    // so the split into two bodies is immediately visible.
                    let r = $0.rect
                    let k = max(1, $0.loupeScale)
                    $0.loupeSource = CGPoint(x: r.midX, y: r.midY)
                    $0.loupeSourceSize = CGSize(width: r.width / k, height: r.height / k)
                    var moved = r.offsetBy(dx: r.width * 0.9, dy: -r.height * 0.9)
                    moved.origin.x = min(max(0, moved.origin.x), pixel.width - moved.width)
                    moved.origin.y = min(max(0, moved.origin.y), pixel.height - moved.height)
                    $0.moveLoupePart(.display, by: CGPoint(x: moved.minX - r.minX,
                                                           y: moved.minY - r.minY))
                }
            }
        )
    }

    private var loupeRevealsOriginalBinding: Binding<Bool> {
        Binding(
            get: {
                if let selected = document.selectedAnnotation, selected.kind == .loupe {
                    return selected.loupeRevealsOriginal
                }
                return style.loupeRevealsOriginal
            },
            set: { newValue in
                style.loupeRevealsOriginal = newValue
                applyToSelection {
                    if $0.kind == .loupe { $0.loupeRevealsOriginal = newValue }
                }
            }
        )
    }

    /// Closed shapes with a colorable interior — the whole outline family.
    private static func isFillable(_ kind: AnnotationKind) -> Bool {
        kind == .rect || kind == .oval || kind.isPathShape
    }

    private var isFillableSelection: Bool {
        document.selectedAnnotation.map { Self.isFillable($0.kind) } ?? false
    }

    /// Fill opacity as a 0…100 percentage for the slider; model stores 0…1.
    private var fillOpacityBinding: Binding<CGFloat> {
        Binding(
            get: {
                let opacity = isFillableSelection
                    ? (document.selectedAnnotation?.fillOpacity ?? 0)
                    : style.fillOpacity
                return opacity * 100
            },
            set: { rawPercent in
                let percent = (rawPercent / 5).rounded() * 5   // continuous slider, 5% detents
                let opacity = percent / 100
                style.fillOpacity = opacity
                document.updateSelected {
                    if Self.isFillable($0.kind) { $0.fillOpacity = opacity }
                }
            }
        )
    }

    /// Stepper bridge: the sides of a `.polygon` as CGFloat detents.
    private var polygonSidesBinding: Binding<CGFloat> {
        Binding(
            get: {
                CGFloat(document.selectedAnnotation?.kind == .polygon
                    ? (document.selectedAnnotation?.polygonSides ?? style.polygonSides)
                    : style.polygonSides)
            },
            set: { newValue in
                let sides = min(ShapeCounts.polygonSides.upperBound,
                                max(ShapeCounts.polygonSides.lowerBound, Int(newValue)))
                style.polygonSides = sides
                applyToSelection { if $0.kind == .polygon { $0.polygonSides = sides } }
            }
        )
    }

    /// Stepper bridge: the points of a `.star` as CGFloat detents.
    private var starPointsBinding: Binding<CGFloat> {
        Binding(
            get: {
                CGFloat(document.selectedAnnotation?.kind == .star
                    ? (document.selectedAnnotation?.starPoints ?? style.starPoints)
                    : style.starPoints)
            },
            set: { newValue in
                let points = min(ShapeCounts.starPoints.upperBound,
                                 max(ShapeCounts.starPoints.lowerBound, Int(newValue)))
                style.starPoints = points
                applyToSelection { if $0.kind == .star { $0.starPoints = points } }
            }
        )
    }

    private var bubbleTailBinding: Binding<BubbleTailDirection> {
        Binding(
            get: {
                document.selectedAnnotation?.kind == .bubble
                    ? (document.selectedAnnotation?.bubbleTail ?? style.bubbleTail)
                    : style.bubbleTail
            },
            set: { newValue in
                style.bubbleTail = newValue
                applyToSelection { if $0.kind == .bubble { $0.bubbleTail = newValue } }
            }
        )
    }

    private var arrowStyleBinding: Binding<ArrowStyle> {
        Binding(
            get: {
                document.selectedAnnotation?.kind == .arrow
                    ? (document.selectedAnnotation?.arrowStyle ?? style.arrowStyle)
                    : style.arrowStyle
            },
            set: { newValue in
                style.arrowStyle = newValue
                applyToSelection { if $0.kind == .arrow { $0.arrowStyle = newValue } }
            }
        )
    }

    private var arrowRouteBinding: Binding<ArrowRoute> {
        Binding(
            get: {
                document.selectedAnnotation?.kind == .arrow
                    ? (document.selectedAnnotation?.arrowRoute ?? style.arrowRoute)
                    : style.arrowRoute
            },
            set: { newValue in
                style.arrowRoute = newValue
                applyToSelection {
                    guard $0.kind == .arrow else { return }
                    $0.arrowRoute = newValue
                    // Switching into elbowed squares up a near-aligned arrow so
                    // it can be straight instead of jogging between its ends.
                    $0.alignForElbow()
                }
            }
        )
    }

    private var arrowHeadPlacementBinding: Binding<ArrowHeadPlacement> {
        Binding(
            get: {
                document.selectedAnnotation?.kind == .arrow
                    ? (document.selectedAnnotation?.arrowHeadPlacement
                       ?? style.arrowHeadPlacement)
                    : style.arrowHeadPlacement
            },
            set: { newValue in
                style.arrowHeadPlacement = newValue
                applyToSelection {
                    if $0.kind == .arrow { $0.arrowHeadPlacement = newValue }
                }
            }
        )
    }

    private var lineStyleBinding: Binding<LineStyle> {
        Binding(
            get: {
                document.selectedAnnotation?.kind == .line
                    ? (document.selectedAnnotation?.lineStyle ?? style.lineStyle)
                    : style.lineStyle
            },
            set: { newValue in
                style.lineStyle = newValue
                applyToSelection { if $0.kind == .line { $0.lineStyle = newValue } }
            }
        )
    }

    /// Restyling the selected annotation is undoable as a single step.
    private func applyToSelection(_ mutate: (inout Annotation) -> Void) {
        guard document.selectedID != nil else { return }
        document.beginChange()
        document.updateSelected(mutate)
        document.commitChange()
    }

    private var undoRedoButtons: some View {
        HStack(spacing: 2) {
            Button { document.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!document.canUndo || textEditingActive)
            .hoverTip("Undo")

            Button { document.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!document.canRedo || textEditingActive)
            .hoverTip("Redo")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { adjustZoom(by: -0.25) } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("-", modifiers: .command)
            .disabled(textEditingActive || zoomFactor <= 0.25)
            .hoverTip("Zoom Out")

            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 38)
                .hoverTip("Zoom")

            Button { adjustZoom(by: 0.25) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("+", modifiers: .command)
            .disabled(textEditingActive || zoomFactor >= 8)
            .hoverTip("Zoom In")
        }
    }

    /// Zoom-to-fit lives beside zoom, not inside it. Its label collapses to
    /// the icon alone when the toolbar runs short of width.
    private var fitButton: some View {
        Button { fitZoom() } label: {
            Image(systemName: "square.arrowtriangle.4.outward")
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("0", modifiers: .command)
        .disabled(textEditingActive)
        .hoverTip("Zoom to Fit")
    }

    /// One rotate button instead of a mirrored pair: plain click rotates
    /// right, ⌥-click rotates left. The modifier is read at click time, the
    /// same way the canvas reads shift/option during drags; while ⌥ is held
    /// over the button, the icon and tooltip flip to preview the direction —
    /// a local SwiftUI observation, so no Input Monitoring involved.
    private var rotateButtons: some View {
        Button {
            rotate(clockwise: !NSEvent.modifierFlags.contains(.option))
        } label: {
            Image(systemName: rotateOptionHeld ? "rotate.left" : "rotate.right")
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(textEditingActive)
        .onModifierKeysChanged(mask: .option) { _, new in
            rotateOptionHeld = !new.isEmpty
        }
        .hoverTip(rotateOptionHeld ? "Rotate Left" : "Rotate Right",
                  shortcut: rotateOptionHeld
                      ? nil
                      : "⌥ — " + LocaleManager.shared.string("Rotate Left"))
    }

    /// Rotates the image, and — if a crop frame is active — rotates that frame
    /// with it so it keeps framing the same region and stays within the new
    /// (swapped) bounds.
    private func rotate(clockwise: Bool) {
        let oldSize = document.pixelSize
        document.rotate(clockwise: clockwise)
        if let rect = cropRect {
            let p1 = EditorDocument.rotatePoint(CGPoint(x: rect.minX, y: rect.minY),
                                                in: oldSize, clockwise: clockwise)
            let p2 = EditorDocument.rotatePoint(CGPoint(x: rect.maxX, y: rect.maxY),
                                                in: oldSize, clockwise: clockwise)
            cropRect = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y),
                              width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
        }
    }

    private var cropButton: some View {
        Button {
            if tool == .crop { cancelCrop() } else { enterCropMode() }
        } label: {
            Image(systemName: "crop")
                .frame(width: ToolButtonMetrics.width, height: ToolButtonMetrics.height)
        }
        .buttonStyle(.borderless)
        .activeToolChrome(tool == .crop)
        .disabled(textEditingActive)
        .hoverTip("Crop")
    }

    /// Own group past the crop divider: the scanner is a marquee like the
    /// drawing tools, but what it produces is text on the clipboard, not an
    /// annotation — so it sits with crop and rotate, the operations that act
    /// on the image itself, rather than in the tool picker. Toggles, matching
    /// crop: a second click leaves the mode. One entry point covers text and
    /// codes — the drag is identical either way, so what the pixels contain is
    /// decided after the drag (see scanRegion), not by a button picked up
    /// front.
    private var scanButton: some View {
        Button {
            if tool == .scan { tool = .select } else { selectTool(.scan) }
        } label: {
            Image(systemName: "doc.viewfinder")
                .frame(width: ToolButtonMetrics.width, height: ToolButtonMetrics.height)
        }
        .buttonStyle(.borderless)
        .activeToolChrome(tool == .scan)
        .disabled(textEditingActive)
        .hoverTip("Scan")
    }

    /// In crop mode the Copy/Save actions are replaced by Cancel/Apply.
    @ViewBuilder private var actionButtons: some View {
        if tool == .crop {
            cropActionButtons
        } else {
            standardActionButtons
        }
    }

    private var cropActionButtons: some View {
        HStack(spacing: 8) {
            Button { cancelCrop() } label: {
                collapsibleLabel("Cancel", systemImage: "xmark")
            }
            .hoverTip("Cancel")

            Button { applyCrop() } label: {
                collapsibleLabel("Apply", systemImage: "checkmark")
            }
            .disabled(cropRect == nil)
            .hoverTip("Apply")
        }
        // Same size as the standard group it replaces in this slot.
        .controlSize(.regular)
    }

    /// The whole action group collapses as a unit: labels on Copy and Save
    /// together, or icons on both. Per-button `collapsibleLabel` can't be used
    /// here — the Save control is a button-styled `Menu`, which accepts any
    /// width it is offered and would eat the toolbar's slack unless pinned with
    /// `.fixedSize()`, and a fixed-size label never gets the chance to collapse.
    /// Choosing at the group level restores that: the toolbar proposes a real
    /// width to the group, so the labelled variant wins whenever it fits.
    private var standardActionButtons: some View {
        ViewThatFits(in: .horizontal) {
            actionGroup(labelled: true)
            actionGroup(labelled: false)
        }
        // As a background, not a sibling: zero-size views in an HStack still
        // get the row's spacing on both sides, and three of them pushed the
        // group 24 pt off the toolbar's trailing edge.
        .background(shortcutCarriers)
    }

    private func actionGroup(labelled: Bool) -> some View {
        HStack(spacing: 8) {
            // Share stays icon-only in both variants: it has no keyboard
            // shortcut to advertise and its glyph is unambiguous.
            EditorShareButton(prepareItems: shareItems) {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(textEditingActive || isPreparingArtifact)
            .hoverTip("Share")

            Button {
                copyToClipboard()
            } label: {
                actionLabel("Copy", systemImage: "doc.on.doc", labelled: labelled)
            }
            .disabled(textEditingActive || isPreparingArtifact)
            .hoverTip("Copy", shortcut: "⌘C")

            // Split control rather than a fourth button: clicking saves
            // straight to the configured folder (the flow this app is built
            // around), and the variant that asks where and in what format
            // lives one chevron away instead of widening the row.
            Menu {
                Button("Save As…") { saveAs() }
                    .disabled(saveAsHandler == nil || isPreparingArtifact)
                Divider()
                // The other way a capture can end: it was only ever wanted on
                // the clipboard, and the file the app wrote on its own way out
                // is litter. Copy renders the annotated composite exactly as
                // the Copy button does — what leaves is what is on screen.
                //
                // Both are red, and by hand: on macOS a destructive role
                // changes nothing about how a row is drawn, and the colour only
                // survives into the NSMenuItem when the Text itself carries it.
                // Both throw the file away, so colouring only one of them would
                // read as an oversight rather than a distinction — and the
                // warning is earned: the file comes back from the Trash, its
                // place in the archive does not. The archive drops an entry
                // when its file goes, and Finder's Put Back tells nobody.
                Button(role: .destructive) {
                    copyToClipboard()
                    delete()
                } label: {
                    Text("Copy and Delete").foregroundStyle(.red)
                }
                    .disabled(deleteHandler == nil || isPreparingArtifact)
                Button(role: .destructive) { delete() } label: {
                    Text("Delete").foregroundStyle(.red)
                }
                .disabled(deleteHandler == nil || isPreparingArtifact)
            } label: {
                actionLabel("Save", systemImage: "square.and.arrow.down", labelled: labelled)
            } primaryAction: {
                save()
            }
            .menuStyle(.button)
            // A button-styled Menu sizes 2 pt shorter than a plain Button at
            // the same control size, which reads as a thinner control next to
            // Copy; maxHeight lets the row's own height drive it instead.
            // fixedSize stays horizontal-only — the group's fixedSize already
            // keeps the menu from growing into the toolbar's slack.
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .disabled(saveHandler == nil || textEditingActive || isPreparingArtifact)
            .hoverTip("Save", shortcut: "⌘S")
        }
        // .regular, not .small: a button-styled Menu draws a shorter bezel than
        // a plain Button at .mini (−1.6 pt) and .small (−3.2 pt), and no style,
        // font or padding changes that — the two only agree at .regular, which
        // is what keeps Save from looking thinner than Copy beside it.
        .controlSize(.regular)
        .fixedSize()
    }

    @ViewBuilder
    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, labelled: Bool) -> some View {
        if labelled {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
    }

    /// Zero-size buttons carrying the group's shortcuts. They sit outside the
    /// ViewThatFits so each shortcut is declared exactly once no matter which
    /// variant is on screen (ViewThatFits builds every candidate to measure it),
    /// and because a Menu's `primaryAction` does not reliably adopt
    /// `.keyboardShortcut` — ⌘S must not depend on the toolbar's shape.
    private var shortcutCarriers: some View {
        Group {
            Button("") { copyToClipboard() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(textEditingActive || isPreparingArtifact)
            Button("") { save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(saveHandler == nil || textEditingActive || isPreparingArtifact)
            Button("") { saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(saveAsHandler == nil || textEditingActive || isPreparingArtifact)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func save() {
        guard !isPreparingArtifact, let saveHandler else { return }
        isPreparingArtifact = true
        Task { @MainActor in
            let didSave = await saveHandler(document)
            isPreparingArtifact = false
            if didSave { showCaptureHUD(.saved) }
        }
    }

    private func saveAs() {
        guard !isPreparingArtifact, let saveAsHandler else { return }
        isPreparingArtifact = true
        Task { @MainActor in
            await saveAsHandler(document)
            isPreparingArtifact = false
        }
    }

    private func delete() {
        deleteHandler?(document)
    }

    /// Text+icon when there's room, icon-only when the row is tight.
    private func collapsibleLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: systemImage)
            Image(systemName: systemImage)
        }
    }

    // MARK: Actions

    private func copyToClipboard() {
        guard !isPreparingArtifact else { return }
        isPreparingArtifact = true
        let format = EditorExportFormat.fromSettings()
        let snapshot = document.makeRenderSnapshot(format: format.rawValue)
        Task { @MainActor in
            defer { isPreparingArtifact = false }
            guard let artifact = await Task.detached(priority: .userInitiated, operation: {
                AnnotationRenderer.renderEncoded(snapshot: snapshot)
            }).value else { return }
            // In the format the captures are saved in, not the TIFF an NSImage
            // on the pasteboard turns into.
            NSPasteboard.general.writeImage(artifact.data, as: format)
            showCaptureHUD(.copied)
        }
    }

    /// Payload for the share sheet: the annotated image written to a temp file
    /// in the configured format, so the receiving service gets a real name and
    /// extension. Falls back to the in-memory image if the file can't be
    /// written — sharing still works, just unnamed. Sharing never saves: an
    /// unsaved document stays unsaved.
    private func shareItems() async -> PreparedSharePayload? {
        let snapshot = document.makeRenderSnapshot(format: AppSettings.fileFormat)
        guard let artifact = await Task.detached(priority: .userInitiated, operation: {
            AnnotationRenderer.renderEncoded(snapshot: snapshot)
        }).value else { return nil }
        let name = document.sourceURL.deletingPathExtension().lastPathComponent
        let store = ScreenshotFileStore()
        if let url = try? await Task.detached(priority: .utility, operation: {
            try store.writeTemporaryExport(artifact.data, named: name, format: artifact.format)
        }).value {
            return PreparedSharePayload(fileURL: url, data: nil)
        }
        Log.capture.error("editor: share export failed, sharing in-memory image")
        return PreparedSharePayload(fileURL: nil, data: artifact.data)
    }

    /// Unified scanner over the marquee region: the same one-pass barcode+text
    /// recognition as the panel's Scan action. Everything found lands on the
    /// clipboard in visual order and each finding joins the archive; the shared
    /// capture HUD reports the outcome. Runs off the main thread so a large
    /// crop doesn't stall the UI. Leaving scan mode after a scan matches the
    /// "select once, then copy" flow.
    /// Opens the same overlay the scan hotkey does — same crosshair, same mode
    /// badge, same ⌥/⌃/⇥ — bounded to the rect the image occupies rather than
    /// to a whole display. The editor's own controls stay reachable because the
    /// overlay never reaches them, and a selection cannot leave the image
    /// because the panel is the image.
    private func beginScanSelection() {
        guard let geometry = imageScreenGeometry,
              let screen = NSScreen.screens.first(where: {
                  $0.frame.intersects(geometry.screenRect)
              }) ?? NSScreen.main
        else {
            tool = .select
            return
        }

        let bounds = CGRect(origin: .zero, size: document.pixelSize)
        scanOverlay.showsScanModes = true
        // The picker and ⌥ are two ways of saying the same thing: the overlay
        // opens on whatever the picker holds, and ⌥ writes back so the picker
        // follows the badge. Translation is deliberately not written back —
        // it outranks line breaks rather than choosing between them, so it has
        // nothing to say about the picker's value.
        scanMode = style.scanJoinsLines ? .plain : .keepLineBreaks
        scanOverlay.initialScanMode = scanMode
        scanOverlay.onScanModeChanged = { mode in
            scanMode = mode
            switch mode {
            case .plain:          style.scanJoinsLines = true
            case .keepLineBreaks: style.scanJoinsLines = false
            case .translate:      break
            }
        }
        scanOverlay.onSelected = { cgRect in
            scanOverlayActive = false
            // Clamped: the overlay works in points and the document in pixels,
            // so a selection flush against an edge can round a hair outside it.
            let pixels = geometry.imagePixelRect(from: cgRect, screen: screen)
                .intersection(bounds)
            guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else {
                tool = .select
                return
            }
            scanRegion(pixels, mode: scanOverlay.selectionMode,
                       language: scanOverlay.translationTarget)
        }
        scanOverlay.onCancelled = {
            scanOverlayActive = false
            tool = .select
        }
        scanOverlayActive = true
        scanOverlay.start(over: geometry.screenRect, on: screen)
    }

    private func scanRegion(_ pixelRect: CGRect,
                            mode: ScanSelectionMode,
                            language: Locale.Language?) {
        // Translation outranks line breaks rather than choosing between them:
        // it rejoins the lines ⌥ exists to preserve, so a translating scan
        // always reads prose. Same precedence as the panel's scan.
        let translates = mode == .translate
        let joinsLines = translates ? true : style.scanJoinsLines
        tool = .select
        guard let cropped = croppedBaseImage(pixelRect) else { showCaptureHUD(.nothingRecognized); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = (try? ScanRecognition.scan(in: cropped, joinsLines: joinsLines))
                ?? ScanRecognition.Result(codePayloads: [], text: "", clipboardText: "")
            DispatchQueue.main.async {
                guard !result.isEmpty else { showCaptureHUD(.nothingRecognized); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.clipboardText, forType: .string)
                // The archive inserts each entry at the top, so post in reverse:
                // the visually-topmost finding ends up as the topmost archive entry.
                for entry in result.archiveEntries.reversed() {
                    NotificationCenter.default.post(name: .editorDidScan, object: entry)
                }
                // The scan toast is skipped when translating: the translation
                // has its own outcome, and two toasts for one gesture read as
                // something having gone wrong. Same rule as the panel's scan.
                if translates, !result.text.isEmpty {
                    NotificationCenter.default.post(
                        name: .editorDidScanForTranslation,
                        object: EditorScanTranslation(text: result.text, language: language)
                    )
                } else {
                    showCaptureHUD(ScanCaptureCoordinator.outcome(for: result))
                }
            }
        }
    }

    /// Routes recognition outcomes through the same toast the notch flows use,
    /// on the screen hosting the editor window.
    private func showCaptureHUD(_ outcome: TextCaptureHUD.Outcome) {
        let controller = EditorWindowController.shared
        controller.captureHUD.show(outcome, on: controller.screen)
    }

    /// Crops the base image to an image-pixel rect (top-left origin, matching
    /// the annotation coordinate space and `CGImage.cropping`), clamped to the
    /// image bounds. Returns nil for a degenerate selection.
    private func croppedBaseImage(_ pixelRect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0,
                            width: CGFloat(document.baseImage.width),
                            height: CGFloat(document.baseImage.height))
        let region = pixelRect.integral.intersection(bounds)
        guard region.width >= 1, region.height >= 1 else { return nil }
        return document.baseImage.cropping(to: region)
    }

    // MARK: Crop

    /// Live pixel dimensions of the crop rect, typed in for an exact size. The
    /// frame stays within the image: an over-large value clamps to the image
    /// and shifts the origin inward to fit rather than spilling over.
    private var cropSizeControls: some View {
        HStack(spacing: 6) {
            Image(systemName: "crop")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("", value: cropDimensionBinding(\.width), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56).multilineTextAlignment(.center)
                .hoverTip("Crop Width")
            Text(verbatim: "×").foregroundStyle(.secondary)
            TextField("", value: cropDimensionBinding(\.height), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56).multilineTextAlignment(.center)
                .hoverTip("Crop Height")
            Text(verbatim: "px").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    /// Rounds the crop rect's width or height to an integer for the field, and
    /// on entry resizes that axis (clamped, origin nudged to keep it on-image).
    private func cropDimensionBinding(_ axis: WritableKeyPath<CGSize, CGFloat>) -> Binding<Int> {
        Binding(
            get: { Int((cropRect?.size[keyPath: axis] ?? 0).rounded()) },
            set: { newValue in setCropDimension(axis, to: CGFloat(newValue)) }
        )
    }

    private func setCropDimension(_ axis: WritableKeyPath<CGSize, CGFloat>, to value: CGFloat) {
        guard var rect = cropRect else { return }
        let isWidth = axis == \CGSize.width
        let limit = isWidth ? document.pixelSize.width : document.pixelSize.height
        let size = min(max(8, value), limit)                 // 8px floor, image ceiling
        var origin = isWidth ? rect.origin.x : rect.origin.y
        if origin + size > limit { origin = limit - size }   // slide inward to fit
        origin = max(0, origin)
        if isWidth {
            rect.origin.x = origin; rect.size.width = size
        } else {
            rect.origin.y = origin; rect.size.height = size
        }
        cropRect = rect
    }

    /// Enters crop mode with the frame initialized to the whole image, so the
    /// user drags the edges inward (or draws a new rect).
    private func enterCropMode() {
        document.selectedID = nil
        cropRect = CGRect(origin: .zero, size: document.pixelSize)
        tool = .crop
    }

    private func applyCrop() {
        if let cropRect { document.crop(to: cropRect) }
        cropRect = nil
        tool = .select
    }

    private func cancelCrop() {
        cropRect = nil
        tool = .select
    }

    private func adjustZoom(by amount: CGFloat) {
        zoomFactor = min(8, max(0.25, zoomFactor + amount))
    }

    private func fitZoom() {
        zoomFactor = 1
        panOffset = .zero
    }
}

// MARK: - Active tool chrome

/// The footprint every tool button shares.
///
/// Crop and Scan were built at 24pt, the size of the image actions they stand
/// among — rotate, fit, zoom. But standing among them is where they are, not
/// what they are: they are tools, the only two outside the picker that can be
/// on. So they take the picker's size, and it lives here beside the plate and
/// the colour, because all three are the same fact about the same buttons.
private enum ToolButtonMetrics {
    static let width: CGFloat = 26
    static let height: CGFloat = 22
}

/// How a tool button says its tool is on: a tinted plate behind it and the
/// accent colour in front.
///
/// The tool picker's buttons are built by one function and wore this already.
/// Crop and Scan are toggles rather than picker entries, so they build their
/// own buttons — and had only half of it, colouring the icon while staying
/// flat. "This tool is on" has to look the same wherever it is said, so the
/// look lives here and all three ask for it.
private struct ActiveToolChrome: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
    }
}

private extension View {
    func activeToolChrome(_ isActive: Bool) -> some View {
        modifier(ActiveToolChrome(isActive: isActive))
    }
}
