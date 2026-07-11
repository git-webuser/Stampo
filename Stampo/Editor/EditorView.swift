import AppKit
import SwiftUI

/// Editor window content: toolbar (tools, style, undo/redo, copy/save) over
/// the annotation canvas. Standard-window styling (accent color), not the
/// dark notch-panel look.
struct EditorView: View {
    var document: EditorDocument
    /// Wired by EditorWindowController in the save/copy commit; nil disables Save.
    var saveHandler: ((EditorDocument) -> Bool)?

    @State private var tool: EditorTool = .arrow
    @State private var style = ToolStyle()
    @State private var editingTextID: UUID?
    @State private var zoomFactor: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var feedback: FeedbackKind?
    @State private var feedbackTask: DispatchWorkItem?

    enum FeedbackKind { case saved, copied }

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
                panOffset: $panOffset
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
            ForEach(EditorTool.allCases, id: \.self) { t in
                Button {
                    tool = t
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
                .help(LocalizedStringKey(t.labelKey))
                .accessibilityLabel(LocalizedStringKey(t.labelKey))
            }
        }
    }

    /// Second toolbar row: settings for the active tool. A selected
    /// annotation's kind wins over the tool so restyling a selection always
    /// shows the matching controls. Fixed height — switching tools must not
    /// reflow the canvas.
    private var contextBar: some View {
        HStack(spacing: 12) {
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
            case .step:
                colorSwatches
                settingSlider("Marker Size", systemImage: "circle.circle",
                              value: stepSizeBinding, range: 24...72, step: 8)
            case .rect, .oval:
                colorSwatches
                thicknessSlider
                fillSlider
            case .arrow:
                colorSwatches
                arrowStylePicker
                thicknessSlider
            default: // select tool with nothing selected
                colorSwatches
                thicknessSlider
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    /// What the bottom row configures right now.
    private var contextKind: AnnotationKind? {
        if let selected = document.selectedAnnotation { return selected.kind }
        switch tool {
        case .select: return nil
        case .arrow:  return .arrow
        case .rect:   return .rect
        case .oval:   return .oval
        case .text:   return .text
        case .blur:   return .blur
        case .step:   return .step
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 5) {
            ForEach(Array(AnnotationColor.presets.enumerated()), id: \.offset) { _, preset in
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
            }
        }
        .accessibilityLabel("Color")
    }

    private var blurStylePicker: some View {
        Picker("Blur", selection: blurStyleBinding) {
            Text("Pixelate").tag(BlurStyle.pixelate)
            Text("Blur").tag(BlurStyle.gaussian)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 130)
    }

    private var fillSlider: some View {
        settingSlider("Fill", systemImage: "paintbrush.pointed.fill",
                      value: fillOpacityBinding, range: 0...100, step: 5,
                      ticks: false, format: { "\(Int($0))%" })
    }

    // MARK: Text formatting controls

    private var textControls: some View {
        HStack(spacing: 4) {
            formatToggle("Bold", systemImage: "bold", binding: boldBinding)
            formatToggle("Italic", systemImage: "italic", binding: italicBinding)
            formatToggle("Underline", systemImage: "underline", binding: underlineBinding)
            formatToggle("Strikethrough", systemImage: "strikethrough", binding: strikethroughBinding)
            formatToggle("Text Shadow", systemImage: "shadow", binding: textShadowBinding)
            Divider().frame(height: 18)
            Picker("Text Background", selection: textBackgroundBinding) {
                Image(systemName: "square.slash").tag(TextBackground.none)
                Image(systemName: "square.fill").tag(TextBackground.dark)
                Image(systemName: "square").tag(TextBackground.light)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 108)
            .help("Text Background")
        }
    }

    private func formatToggle(_ label: LocalizedStringKey, systemImage: String,
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
        .help(label)
        .accessibilityLabel(label)
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
        .help("Arrow Style")
    }

    private var thicknessSlider: some View {
        settingSlider("Thickness", systemImage: "lineweight",
                      value: thicknessBinding, range: 4...32, step: 4)
    }

    /// Icon + slider. `ticks` shows detents (stepped slider); when false the
    /// slider is continuous (no tick marks) and the caller's binding rounds to
    /// the step. `format` adds a trailing readout.
    private func settingSlider(
        _ label: LocalizedStringKey, systemImage: String,
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
        .help(label)
        .accessibilityLabel(label)
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
                Image(systemName: "checkmark.circle.fill")
                Text(feedback == .saved ? "Saved" : "Copied")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
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
            .help("Undo")

            Button { document.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!document.canRedo || textEditingActive)
            .help("Redo")
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
            .help("Zoom Out")

            Text("\(Int((zoomFactor * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 38)
                .accessibilityLabel("Zoom")

            Button { adjustZoom(by: 0.25) } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("+", modifiers: .command)
            .disabled(textEditingActive || zoomFactor >= 8)
            .help("Zoom In")
        }
    }

    /// Zoom-to-fit lives beside zoom, not inside it. Its label collapses to
    /// the icon alone when the toolbar runs short of width.
    private var fitButton: some View {
        Button { fitZoom() } label: {
            ViewThatFits(in: .horizontal) {
                Label("Fit", systemImage: "square.arrowtriangle.4.outward")
                Image(systemName: "square.arrowtriangle.4.outward")
                    .frame(width: 24, height: 22)
            }
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("0", modifiers: .command)
        .disabled(textEditingActive)
        .help("Zoom to Fit")
    }

    private var rotateButtons: some View {
        HStack(spacing: 2) {
            Button { document.rotate(clockwise: false) } label: {
                Image(systemName: "rotate.left").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(textEditingActive)
            .help("Rotate Left")

            Button { document.rotate(clockwise: true) } label: {
                Image(systemName: "rotate.right").frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(textEditingActive)
            .help("Rotate Right")
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                copyToClipboard()
            } label: {
                collapsibleLabel("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(textEditingActive)

            Button {
                if let saveHandler, saveHandler(document) { showFeedback(.saved) }
            } label: {
                collapsibleLabel("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveHandler == nil || textEditingActive)
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
