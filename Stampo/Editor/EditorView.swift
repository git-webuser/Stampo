import AppKit
import SwiftUI
import Vision

/// Editor window content: toolbar (tools, style, undo/redo, copy/save) over
/// the annotation canvas. Standard-window styling (accent color), not the
/// dark notch-panel look.
struct EditorView: View {
    var document: EditorDocument
    /// Wired by EditorWindowController in the save/copy commit; nil disables Save.
    var saveHandler: ((EditorDocument) -> Bool)?

    @State private var tool: EditorTool = .select
    @State private var style = ToolStyle()
    @State private var editingTextID: UUID?
    @State private var zoomFactor: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    /// Pending crop rectangle (image-pixel space) while the crop tool is active.
    @State private var cropRect: CGRect?
    @State private var feedback: FeedbackKind?
    @State private var feedbackTask: DispatchWorkItem?

    enum FeedbackKind {
        case saved, copied, textCopied, noText

        var message: LocalizedStringKey {
            switch self {
            case .saved:      return "Saved"
            case .copied:     return "Copied"
            case .textCopied: return "Text Copied"
            case .noText:     return "No Text Found"
            }
        }

        var isWarning: Bool { self == .noText }
    }

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
                onRecognizeRegion: { recognizeRegion($0) },
                cropRect: $cropRect,
                onCropApply: applyCrop,
                onCropCancel: cancelCrop
            )
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 360)
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
            Spacer(minLength: 8)
            feedbackLabel
            undoRedoButtons
            Divider().frame(height: 20)
            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var toolPicker: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.pickerCases, id: \.self) { t in
                Button {
                    tool = t
                    cropRect = nil
                    if t != .select { document.selectedID = nil }
                    if t == .blur {
                        document.prepareBlurSource(style: style.blurStyle,
                                                   level: style.blurLevel)
                    }
                } label: {
                    Image(systemName: t.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tool == t ? Color.accentColor.opacity(0.22) : .clear)
                )
                .foregroundStyle(tool == t ? Color.accentColor : Color.primary)
                .hoverTip(t.labelKey, shortcut: t.shortcut?.label)
            }
        }
    }

    /// Second toolbar row: settings for the active tool. A selected
    /// annotation's kind wins over the tool so restyling a selection always
    /// shows the matching controls. Fixed height — switching tools must not
    /// reflow the canvas.
    private var contextBar: some View {
        HStack(spacing: 12) {
            if tool == .ocr, document.selectedAnnotation == nil {
                Label("Drag to select an area to recognize", systemImage: "text.viewfinder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if tool == .crop {
                cropSizeControls
            } else if tool == .eraser, document.selectedAnnotation == nil {
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
                    .padding(.horizontal, 6)
                settingSlider("Intensity", systemImage: "aqi.medium",
                              value: blurLevelBinding,
                              range: CGFloat(BlurIntensity.range.lowerBound)
                                  ... CGFloat(BlurIntensity.range.upperBound),
                              step: 1)
            case .text:
                colorSwatches
                settingSlider("Text Size", systemImage: "textformat.size",
                              value: fontSizeBinding, range: 16...96, step: 2,
                              ticks: false, format: { "\(Int($0))pt" })
                Divider().frame(height: 18)
                textControls
            case .freehand:
                drawingModePicker
                colorSwatches
                let range: ClosedRange<CGFloat> = effectiveDrawingMode == .marker
                    ? 8...64 : 2...32
                settingSlider("Brush Size", systemImage: "lineweight",
                              value: drawingWidthBinding,
                              range: range,
                              step: effectiveDrawingMode == .marker ? 4 : 2)
            case .step:
                colorSwatches
                settingSlider("Marker Size", systemImage: "circle.circle",
                              value: stepSizeBinding, range: 24...72, step: 8)
            case .line:
                colorSwatches
                lineStylePicker
                thicknessSlider
            case .rect, .oval:
                colorSwatches
                thicknessSlider
                fillSlider
            case .arrow:
                colorSwatches
                arrowStylePicker
                arrowHeadPlacementPicker
                thicknessSlider
            default: // select tool with nothing selected
                colorSwatches
                thicknessSlider
        }
    }

    /// What the bottom row configures right now.
    private var contextKind: AnnotationKind? {
        if let selected = document.selectedAnnotation { return selected.kind }
        switch tool {
        case .select, .eraser, .ocr, .crop: return nil
        case .line:   return .line
        case .arrow:  return .arrow
        case .rect:   return .rect
        case .oval:   return .oval
        case .text:   return .text
        case .drawing:return .freehand
        case .blur:   return .blur
        case .step:   return .step
        }
    }

    /// String-catalog keys for the preset names, aligned with
    /// `AnnotationColor.presets`.
    private let colorNames: [String] =
        ["Red", "Orange", "Yellow", "Green", "Blue", "Black", "White"]

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
                            if style.color == preset {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                            }
                        }
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .hoverTip(colorNames[index])
            }
        }
        .accessibilityLabel("Color")
    }

    private var blurStylePicker: some View {
        Picker("Blur", selection: blurStyleBinding) {
            segmentLabel("Pixelate", systemImage: "square.grid.3x3.fill")
                .tag(BlurStyle.pixelate)
            segmentLabel("Blur", systemImage: "drop.fill")
                .tag(BlurStyle.gaussian)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
        .hoverTip("Blur Style")
    }

    private var drawingModePicker: some View {
        Picker("Drawing Instrument", selection: drawingModeBinding) {
            segmentLabel("Pen", systemImage: "pencil.tip")
                .tag(DrawingMode.pen)
            segmentLabel("Marker", systemImage: "highlighter")
                .tag(DrawingMode.marker)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 180)
        .hoverTip("Drawing Instrument")
    }

    /// A single `Text` value with an inline SF Symbol survives SwiftUI's
    /// native NSSegmentedControl bridge, unlike a composite `Label` view.
    private func segmentLabel(_ title: LocalizedStringKey,
                              systemImage: String) -> Text {
        Text(Image(systemName: systemImage)) + Text(verbatim: " ") + Text(title)
    }

    private var fillSlider: some View {
        settingSlider("Fill", systemImage: "paintbrush.pointed.fill",
                      value: fillOpacityBinding, range: 0...100, step: 5,
                      ticks: false, format: { "\(Int($0))%" })
    }

    // MARK: Text formatting controls

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
            Text(verbatim: "⇨").tag(ArrowStyle.bold)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 108)
        .hoverTip("Arrow Style")
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

    private var thicknessSlider: some View {
        settingSlider("Thickness", systemImage: "lineweight",
                      value: thicknessBinding, range: 4...32, step: 4)
    }

    /// Icon + slider. `ticks` shows detents (stepped slider); when false the
    /// slider is continuous (no tick marks) and the caller's binding rounds to
    /// the step. `format` adds a trailing readout.
    private func settingSlider(
        _ label: String, systemImage: String,
        value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat,
        ticks: Bool = true, format: ((CGFloat) -> String)? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Group {
                if ticks {
                    Slider(value: value, in: range, step: step,
                           onEditingChanged: sliderEditingChanged)
                } else {
                    Slider(value: value, in: range, onEditingChanged: sliderEditingChanged)
                }
            }
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

    /// One undo step per slider gesture when it restyles a selection: the
    /// bindings mutate the document directly; begin/commit bracket the drag.
    private func sliderEditingChanged(_ began: Bool) {
        guard document.selectedID != nil else { return }
        if began { document.beginChange() } else { document.commitChange() }
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

    private var drawingModeBinding: Binding<DrawingMode> {
        Binding(
            get: { effectiveDrawingMode },
            set: { newValue in
                style.drawingMode = newValue
                tool = .drawing
                cropRect = nil
                // Pen and Marker choose the next drawing gesture. Switching
                // instruments must not mutate a previously selected stroke or
                // register an unexpected undo operation.
                document.selectedID = nil
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

    private var isFillableSelection: Bool {
        document.selectedAnnotation?.kind == .rect || document.selectedAnnotation?.kind == .oval
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
                    if $0.kind == .rect || $0.kind == .oval { $0.fillOpacity = opacity }
                }
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

    @ViewBuilder private var feedbackLabel: some View {
        if let feedback {
            HStack(spacing: 4) {
                Image(systemName: feedback.isWarning
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(feedback.message)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(feedback.isWarning ? Color.orange : Color.green)
            .transition(.opacity)
        }
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

    private var rotateButtons: some View {
        HStack(spacing: 2) {
            Button { rotate(clockwise: false) } label: {
                Image(systemName: "rotate.left").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(textEditingActive)
            .hoverTip("Rotate Left")

            Button { rotate(clockwise: true) } label: {
                Image(systemName: "rotate.right").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(textEditingActive)
            .hoverTip("Rotate Right")
        }
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
                .frame(width: 24, height: 22)
                .foregroundStyle(tool == .crop ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .disabled(textEditingActive)
        .hoverTip("Crop")
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
        .controlSize(.small)
    }

    private var standardActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                tool = (tool == .ocr) ? .select : .ocr
                document.selectedID = nil
            } label: {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(tool == .ocr ? Color.accentColor : Color.primary)
            }
            .disabled(textEditingActive)
            .hoverTip("Recognize Text")

            Button {
                copyToClipboard()
            } label: {
                collapsibleLabel("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(textEditingActive)
            .hoverTip("Copy")

            Button {
                if let saveHandler, saveHandler(document) { showFeedback(.saved) }
            } label: {
                collapsibleLabel("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveHandler == nil || textEditingActive)
            .hoverTip("Save")
        }
        .controlSize(.small)
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
        guard let rep = AnnotationRenderer.renderBitmap(
            base: document.baseImage,
            blurSources: document.blurSources,
            annotations: document.annotations
        ) else { return }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showFeedback(.copied)
    }

    /// OCRs just the marquee region the user dragged and copies the recognized
    /// text to the clipboard. Runs off the main thread so a large crop doesn't
    /// stall the UI; feedback reports success or "no text found". Leaving OCR
    /// mode after a scan matches the "select once, then copy" flow.
    private func recognizeRegion(_ pixelRect: CGRect) {
        tool = .select
        guard let cropped = croppedBaseImage(pixelRect) else { showFeedback(.noText); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let request = TextRecognition.makeRequest()
            let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
            var recognized = ""
            do {
                try handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                recognized = lines.joined(separator: "\n")
            } catch {
                recognized = ""
            }
            DispatchQueue.main.async {
                let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { showFeedback(.noText); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recognized, forType: .string)
                showFeedback(.textCopied)
            }
        }
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

    private func showFeedback(_ kind: FeedbackKind) {
        feedbackTask?.cancel()
        withAnimation(.easeIn(duration: 0.12)) { feedback = kind }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) { feedback = nil }
        }
        feedbackTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
