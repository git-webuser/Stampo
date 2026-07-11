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
    @State private var feedback: FeedbackKind?
    @State private var feedbackTask: DispatchWorkItem?

    enum FeedbackKind { case saved, copied }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            EditorCanvasView(
                document: document,
                tool: $tool,
                style: $style,
                editingTextID: $editingTextID
            )
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(minWidth: 560, minHeight: 360)
        .onExitCommand { handleEscape() }
    }

    private var textEditingActive: Bool { editingTextID != nil }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            toolPicker
            Divider().frame(height: 20)
            stylePicker
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

    @ViewBuilder private var stylePicker: some View {
        // Color swatches.
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

        // Stroke thickness.
        Picker("Thickness", selection: thicknessBinding) {
            Text("2").tag(CGFloat(2))
            Text("4").tag(CGFloat(4))
            Text("6").tag(CGFloat(6))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 100)
        .help("Thickness")

        // Blur style, only relevant for the blur tool / a selected blur.
        if tool == .blur || document.selectedAnnotation?.kind == .blur {
            Picker("Blur", selection: blurStyleBinding) {
                Text("Pixelate").tag(BlurStyle.pixelate)
                Text("Blur").tag(BlurStyle.gaussian)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
        }
    }

    private var thicknessBinding: Binding<CGFloat> {
        Binding(
            get: { style.lineWidth },
            set: { newValue in
                style.lineWidth = newValue
                applyToSelection { $0.lineWidth = newValue }
            }
        )
    }

    private var blurStyleBinding: Binding<BlurStyle> {
        Binding(
            get: { document.selectedAnnotation?.kind == .blur
                ? (document.selectedAnnotation?.blurStyle ?? style.blurStyle)
                : style.blurStyle },
            set: { newValue in
                style.blurStyle = newValue
                applyToSelection { if $0.kind == .blur { $0.blurStyle = newValue } }
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

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(textEditingActive)

            Button {
                if let saveHandler, saveHandler(document) { showFeedback(.saved) }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(saveHandler == nil || textEditingActive)
        }
        .controlSize(.small)
    }

    // MARK: Actions

    private func copyToClipboard() {
        guard let rep = AnnotationRenderer.renderBitmap(
            base: document.baseImage,
            blurred: document.blurredBase,
            pixelated: document.pixelatedBase,
            annotations: document.annotations
        ) else { return }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showFeedback(.copied)
    }

    /// Esc walks down the editor's interaction hierarchy: leave inline text
    /// editing, clear the selection, then ask AppKit to close (which invokes
    /// EditorWindowController's unsaved-changes guard).
    private func handleEscape() {
        if let editingTextID {
            document.finishTextEditing(editingTextID)
            self.editingTextID = nil
        } else if document.selectedID != nil {
            document.selectedID = nil
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
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
