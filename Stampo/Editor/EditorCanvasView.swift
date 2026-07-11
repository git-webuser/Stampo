import AppKit
import SwiftUI

/// Active tool in the editor toolbar.
enum EditorTool: Equatable, CaseIterable {
    case select, arrow, rect, oval, text, blur, step

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow:  return "arrow.up.right"
        case .rect:   return "rectangle"
        case .oval:   return "oval"
        case .text:   return "textformat"
        case .blur:   return "drop"
        case .step:   return "1.circle"
        }
    }

    var labelKey: String {
        switch self {
        case .select: return "Select"
        case .arrow:  return "Arrow"
        case .rect:   return "Rectangle"
        case .oval:   return "Oval"
        case .text:   return "Text"
        case .blur:   return "Blur"
        case .step:   return "Step"
        }
    }
}

/// Current stroke style shared by the toolbar and the canvas.
struct ToolStyle {
    var color: AnnotationColor = .red
    /// Pixels in the image-space model. 4 px is a comfortable 2 pt stroke
    /// on a 2x screenshot while preserving native-resolution export.
    var lineWidth: CGFloat = 6
    var blurStyle: BlurStyle = .pixelate
    /// Intensity detent for new blur annotations (BlurIntensity.range).
    var blurLevel: Int = BlurIntensity.defaultLevel
    var arrowStyle: ArrowStyle = .filled
    /// Fill opacity (0…1) for new rect/oval; 0 is outline-only.
    var fillOpacity: CGFloat = 0
    /// nil = image-relative automatic size at placement.
    var fontSize: CGFloat?
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var textShadow = true
    var textBackground: TextBackground = .none
    /// Diameter of new step markers in image pixels.
    var stepDiameter: CGFloat = 40
}

// MARK: - EditorCanvasView

/// Letterboxed live preview: base image + annotations via the shared
/// renderer, selection handles on top, drag gestures for create/move/resize,
/// and a TextField overlay for inline text editing.
struct EditorCanvasView: View {
    var document: EditorDocument
    @Binding var tool: EditorTool
    @Binding var style: ToolStyle
    @Binding var editingTextID: UUID?
    @Binding var zoomFactor: CGFloat
    @Binding var panOffset: CGSize

    @FocusState private var textFieldFocused: Bool
    @State private var magnificationStart: CGFloat?
    @State private var isSpaceHeld = false
    @State private var keyMonitor: Any?
    /// Last committed click, for timing-based double-click detection (the
    /// gesture layer doesn't surface a reliable OS click count).
    @State private var lastClick: (id: UUID?, time: Date, point: CGPoint)?

    private enum DragMode {
        case undecided(pixelPoint: CGPoint)
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Annotation.Handle)
        case panning(last: CGPoint)
        case ignore
    }
    @State private var dragMode: DragMode?

    /// Handle grab radius in view points (converted to pixels per gesture).
    private let handleGrabPt: CGFloat = 8
    private let hitTolerancePt: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let pixel = document.pixelSize
            let baseFitScale = min(min(geo.size.width / pixel.width,
                                       geo.size.height / pixel.height), 1.0)
            let fitScale = baseFitScale * zoomFactor
            let drawSize = CGSize(width: pixel.width * fitScale,
                                  height: pixel.height * fitScale)
            let offset = CGPoint(x: (geo.size.width - drawSize.width) / 2 + panOffset.width,
                                 y: (geo.size.height - drawSize.height) / 2 + panOffset.height)

            ZStack(alignment: .topLeading) {
                canvas(fitScale: fitScale, offset: offset)

                if let editingID = editingTextID,
                   let annotation = document.annotations.first(where: { $0.id == editingID }) {
                    if annotation.kind == .step {
                        stepOverlay(for: annotation, fitScale: fitScale, offset: offset)
                    } else {
                        textOverlay(for: annotation, fitScale: fitScale, offset: offset)
                    }
                }
            }
            .gesture(dragGesture(fitScale: fitScale, offset: offset, pixel: pixel,
                                 viewport: geo.size, drawSize: drawSize))
            .simultaneousGesture(magnificationGesture())
            .clipped()
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    /// The annotation currently in inline editing, if any.
    private var editingAnnotation: Annotation? {
        guard let editingTextID else { return nil }
        return document.annotations.first { $0.id == editingTextID }
    }

    // MARK: Canvas

    private func canvas(fitScale: CGFloat, offset: CGPoint) -> some View {
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.saveGState()
                cg.translateBy(x: offset.x, y: offset.y)
                cg.scaleBy(x: fitScale, y: fitScale)
                // Only hide a text annotation while its TextField overlays it;
                // a step keeps its circle drawn under the label editor.
                let skipID = editingAnnotation?.kind == .text ? editingTextID : nil
                AnnotationRenderer.draw(
                    in: cg,
                    base: document.baseImage,
                    blurSources: document.blurSources,
                    annotations: document.annotations,
                    skipping: skipID
                )
                cg.restoreGState()
            }

            // Selection chrome in view space (crisp at any zoom).
            if let selected = document.selectedAnnotation, selected.id != editingTextID {
                drawSelection(for: selected, context: context, fitScale: fitScale, offset: offset)
            }
        }
    }

    private func drawSelection(for a: Annotation, context: GraphicsContext,
                               fitScale: CGFloat, offset: CGPoint) {
        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * fitScale + offset.x, y: p.y * fitScale + offset.y)
        }

        // Dashed outline for area-like annotations (incl. text bounds).
        if a.kind != .arrow {
            let r = a.rect
            let viewRect = CGRect(origin: toView(r.origin),
                                  size: CGSize(width: r.width * fitScale, height: r.height * fitScale))
                .insetBy(dx: -3, dy: -3)
            var path = Path()
            if a.kind == .step {
                path.addEllipse(in: viewRect)
            } else {
                path.addRect(viewRect)
            }
            context.stroke(path, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.stroke(path, with: .color(.black.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3], dashPhase: 3.5))
        }

        for (_, position) in a.handles {
            let c = toView(position)
            let handleRect = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            let circle = Path(ellipseIn: handleRect)
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(.blue), lineWidth: 1.5)
        }
    }

    // MARK: Gesture

    private func dragGesture(fitScale: CGFloat, offset: CGPoint, pixel: CGSize,
                             viewport: CGSize, drawSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = pixelPoint(value.location, fitScale: fitScale, offset: offset, pixel: pixel)

                if dragMode == nil {
                    // First event of the gesture: a click anywhere commits an
                    // in-progress text edit before anything else happens.
                    if editingTextID != nil {
                        finishTextEditing()
                        dragMode = .ignore
                        return
                    }
                    if isSpaceHeld {
                        dragMode = .panning(last: value.location)
                    } else if beginEditingIfDoubleClick(at: p, fitScale: fitScale) {
                        // A double-click on text/step opens its inline editor
                        // instead of starting a move — detected at mouse-down
                        // so it works even on an already-selected annotation.
                        dragMode = .ignore
                    } else {
                        dragMode = beginDrag(at: p, fitScale: fitScale)
                    }
                }

                switch dragMode {
                case .undecided(let startPixel):
                    let viewDistance = hypot(value.translation.width, value.translation.height)
                    guard viewDistance >= 3 else { break }
                    // The select tool has nothing to create on empty space, so
                    // an empty-space drag pans the (zoomed) image instead.
                    guard let kind = shapeKind(for: tool) else {
                        if tool == .select { dragMode = .panning(last: value.location) }
                        break
                    }
                    document.beginChange()
                    var annotation = Annotation(kind: kind, start: startPixel, end: p,
                                                color: style.color, lineWidth: style.lineWidth)
                    annotation.blurStyle = style.blurStyle
                    annotation.blurLevel = style.blurLevel
                    annotation.arrowStyle = style.arrowStyle
                    annotation.fillOpacity = style.fillOpacity
                    annotation.end = constrainedEndpoint(p, from: startPixel, kind: kind)
                    document.annotations.append(annotation)
                    document.selectedID = annotation.id
                    dragMode = .creating(annotation.id)

                case .creating(let id):
                    update(id) {
                        $0.end = constrainedEndpoint(p, from: $0.start, kind: $0.kind)
                    }

                case .moving(let id, let last):
                    let delta = CGPoint(x: p.x - last.x, y: p.y - last.y)
                    update(id) { $0.move(by: delta) }
                    dragMode = .moving(id, last: p)

                case .resizing(let id, let handle):
                    update(id) { annotation in
                        if isShiftHeld, annotation.kind == .arrow {
                            switch handle {
                            case .start:
                                annotation.start = Annotation.snappedArrowEnd(from: annotation.end, to: p)
                            case .end:
                                annotation.end = Annotation.snappedArrowEnd(from: annotation.start, to: p)
                            default:
                                break
                            }
                        } else {
                            annotation.apply(handle: handle, to: p, aspectLocked: isShiftHeld)
                        }
                    }

                case .panning(let last):
                    // Clamp so the image can't be dragged past its overflow
                    // (and stays centered when it fits — no free-floating).
                    let maxX = max(0, (drawSize.width - viewport.width) / 2)
                    let maxY = max(0, (drawSize.height - viewport.height) / 2)
                    panOffset.width = min(maxX, max(-maxX, panOffset.width + value.location.x - last.x))
                    panOffset.height = min(maxY, max(-maxY, panOffset.height + value.location.y - last.y))
                    dragMode = .panning(last: value.location)

                case .ignore, nil:
                    break
                }
            }
            .onEnded { value in
                defer { dragMode = nil }
                let p = pixelPoint(value.location, fitScale: fitScale, offset: offset, pixel: pixel)

                switch dragMode {
                case .undecided:
                    handleClick(at: p, fitScale: fitScale)
                case .creating(let id):
                    if let a = document.annotations.first(where: { $0.id == id }), a.isDegenerate {
                        document.annotations.removeAll { $0.id == id }
                        document.selectedID = nil
                        document.discardChange()
                    } else {
                        document.commitChange()
                    }
                case .moving, .resizing:
                    document.commitChange()
                case .panning, .ignore, nil:
                    break
                }
            }
    }

    /// Decides what a fresh mouse-down does, before we know if it's a click
    /// or a drag.
    private func beginDrag(at p: CGPoint, fitScale: CGFloat) -> DragMode {
        let grabPx = handleGrabPt / fitScale
        let tolerancePx = hitTolerancePt / fitScale

        // Resize handles of the current selection win over everything.
        if let selected = document.selectedAnnotation,
           let handle = selected.handle(at: p, tolerance: grabPx) {
            document.beginChange()
            return .resizing(selected.id, handle)
        }

        switch tool {
        case .select:
            if let hit = document.annotation(at: p, tolerance: tolerancePx) {
                document.selectedID = hit.id
                document.beginChange()
                return .moving(hit.id, last: p)
            }
            // Empty space: a click deselects (in handleClick), a drag pans.
            return .undecided(pixelPoint: p)
        case .text:
            // Drag the selected text's body to move it; otherwise a click
            // places or edits (handled in onEnded).
            if let selected = document.selectedAnnotation,
               selected.kind == .text, selected.hitTest(p, tolerance: tolerancePx) {
                document.beginChange()
                return .moving(selected.id, last: p)
            }
            return .undecided(pixelPoint: p)
        case .arrow, .rect, .oval, .blur, .step:
            // Dragging the selected annotation's body moves it even with a
            // shape tool active; empty space starts a new shape on drag.
            if let selected = document.selectedAnnotation,
               selected.hitTest(p, tolerance: tolerancePx) {
                document.beginChange()
                return .moving(selected.id, last: p)
            }
            return .undecided(pixelPoint: p)
        }
    }

    /// A single click that never became a drag: select what's under it, or
    /// place a new text/step marker on empty space. (Double-click editing is
    /// handled up front at mouse-down.)
    private func handleClick(at p: CGPoint, fitScale: CGFloat) {
        let tolerancePx = hitTolerancePt / fitScale
        let hit = document.annotation(at: p, tolerance: tolerancePx)

        switch tool {
        case .text:
            if let hit, hit.kind == .text { document.selectedID = hit.id }
            else { placeText(at: p) }        // new text opens straight into editing
        case .step:
            if let hit, hit.kind == .step { document.selectedID = hit.id }
            else { placeStep(at: p) }
        default:
            document.selectedID = hit?.id
        }
    }

    /// Records the mouse-down and, if it's the second click of a double-click
    /// on a text or step annotation, opens that annotation's inline editor.
    /// Returns true when it started editing (so the caller skips the drag).
    private func beginEditingIfDoubleClick(at p: CGPoint, fitScale: CGFloat) -> Bool {
        let tolerancePx = hitTolerancePt / fitScale
        let hit = document.annotation(at: p, tolerance: tolerancePx)
        let double = isDoubleClick(on: hit?.id, at: p)
        lastClick = (hit?.id, Date(), p)

        guard double, let hit else { return false }
        switch hit.kind {
        case .text: startEditingText(hit.id); return true
        case .step: startEditingStep(hit.id); return true
        default:    return false
        }
    }

    /// True when this mouse-down lands on the same target as the previous one
    /// within the double-click window and distance.
    private func isDoubleClick(on id: UUID?, at p: CGPoint) -> Bool {
        guard let id, let last = lastClick, last.id == id else { return false }
        return Date().timeIntervalSince(last.time) < 0.5
            && hypot(p.x - last.point.x, p.y - last.point.y) < 12
    }

    private func shapeKind(for tool: EditorTool) -> AnnotationKind? {
        switch tool {
        case .arrow: return .arrow
        case .rect:  return .rect
        case .oval:  return .oval
        case .blur:  return .blur
        case .select, .text, .step: return nil
        }
    }

    private func update(_ id: UUID, _ mutate: (inout Annotation) -> Void) {
        guard let idx = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&document.annotations[idx])
    }

    private func pixelPoint(_ viewPoint: CGPoint, fitScale: CGFloat,
                            offset: CGPoint, pixel: CGSize) -> CGPoint {
        CGPoint(x: max(0, min(pixel.width, (viewPoint.x - offset.x) / fitScale)),
                y: max(0, min(pixel.height, (viewPoint.y - offset.y) / fitScale)))
    }

    private var isShiftHeld: Bool {
        NSEvent.modifierFlags.contains(.shift)
    }

    private func constrainedEndpoint(_ point: CGPoint, from start: CGPoint,
                                     kind: AnnotationKind) -> CGPoint {
        guard isShiftHeld else { return point }
        switch kind {
        case .arrow:
            return Annotation.snappedArrowEnd(from: start, to: point)
        case .rect, .oval:
            return Annotation.aspectLockedEnd(from: start, to: point)
        case .text, .blur, .step:
            return point
        }
    }

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                if magnificationStart == nil { magnificationStart = zoomFactor }
                zoomFactor = clampedZoom((magnificationStart ?? zoomFactor) * magnification)
            }
            .onEnded { _ in magnificationStart = nil }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(8, max(0.25, value))
    }

    // MARK: Keyboard input

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard EditorWindowController.shared.isKeyWindow,
                  self.editingTextID == nil
            else { return event }

            if event.keyCode == 49 { // Space
                self.isSpaceHeld = event.type == .keyDown
                return nil
            }

            // Esc walks the interaction hierarchy. Handled here (not via
            // SwiftUI onExitCommand) because the Canvas is never first
            // responder, so the command modifier never reaches the view.
            if event.type == .keyDown, event.keyCode == 53 {
                if self.tool != .select {
                    self.tool = .select
                } else if self.document.selectedID != nil {
                    self.document.selectedID = nil
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
                return nil
            }

            guard event.type == .keyDown, self.document.selectedID != nil else { return event }

            // Delete / Backspace removes the selection. SwiftUI's
            // onDeleteCommand never fires because the Canvas isn't first
            // responder, so the monitor owns this.
            if event.keyCode == 51 || event.keyCode == 117,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                self.document.deleteSelected()
                return nil
            }

            // Arrow-key nudge in native image pixels: 1, ⇧ 10, ⌥⇧ 50.
            // Command/Control are reserved for menu shortcuts.
            guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return event }
            let shift = event.modifierFlags.contains(.shift)
            let option = event.modifierFlags.contains(.option)
            let amount: CGFloat = (shift && option) ? 50 : (shift ? 10 : 1)
            let delta: CGPoint
            switch event.keyCode {
            case 123: delta = CGPoint(x: -amount, y: 0) // left
            case 124: delta = CGPoint(x: amount, y: 0)  // right
            case 125: delta = CGPoint(x: 0, y: amount)  // down
            case 126: delta = CGPoint(x: 0, y: -amount) // up
            default: return event
            }
            self.document.nudgeSelected(by: delta)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        isSpaceHeld = false
    }

    // MARK: Text editing

    private func placeText(at p: CGPoint) {
        document.beginChange()
        var annotation = Annotation(kind: .text, start: p, end: p,
                                    color: style.color, lineWidth: style.lineWidth)
        annotation.fontSize = style.fontSize ?? document.autoFontSize
        annotation.bold = style.bold
        annotation.italic = style.italic
        annotation.underline = style.underline
        annotation.strikethrough = style.strikethrough
        annotation.textShadow = style.textShadow
        annotation.textBackground = style.textBackground
        document.annotations.append(annotation)
        document.selectedID = annotation.id
        startEditingText(annotation.id, isNew: true)
    }

    private func placeStep(at p: CGPoint) {
        document.beginChange()
        var annotation = Annotation(kind: .step, start: p, end: p,
                                    color: style.color, lineWidth: style.lineWidth)
        annotation.stepLabel = document.nextStepLabel
        annotation.stepDiameter = style.stepDiameter
        document.annotations.append(annotation)
        document.selectedID = annotation.id
        document.commitChange()
    }

    private func startEditingText(_ id: UUID, isNew: Bool = false) {
        if !isNew { document.beginChange() }
        editingTextID = id
        textFieldFocused = true
    }

    /// Relabeling an existing step is one undoable edit; the same
    /// `editingTextID` state drives the overlay, branching on kind.
    private func startEditingStep(_ id: UUID) {
        document.selectedID = id
        document.beginChange()
        editingTextID = id
        textFieldFocused = true
    }

    func finishTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        textFieldFocused = false
        if document.annotations.first(where: { $0.id == id })?.kind == .step {
            document.finishStepEditing(id)
        } else {
            document.finishTextEditing(id)
        }
    }

    private func textOverlay(for annotation: Annotation, fitScale: CGFloat,
                             offset: CGPoint) -> some View {
        let origin = CGPoint(x: min(annotation.start.x, annotation.end.x) * fitScale + offset.x,
                             y: min(annotation.start.y, annotation.end.y) * fitScale + offset.y)
        let binding = Binding<String>(
            get: { document.annotations.first(where: { $0.id == annotation.id })?.text ?? "" },
            set: { newValue in update(annotation.id) { $0.text = newValue } }
        )

        let overlayBackground: Color = {
            switch annotation.textBackground {
            case .none:  return Color.black.opacity(0.25)   // faint scrim aids editing
            case .dark:  return Color.black.opacity(0.55)
            case .light: return Color.white.opacity(0.75)
            }
        }()

        // Screen-space font that preserves bold/italic traits, plus the box
        // sized to the measured text (Return commits, ⇧Return adds a line).
        let baseFont = AnnotationRenderer.textFont(for: annotation)
        let scaledFont = NSFont(descriptor: baseFont.fontDescriptor,
                                size: annotation.fontSize * fitScale) ?? baseFont
        let inset = AnnotationRenderer.textInset(for: annotation) * fitScale
        let measured = AnnotationRenderer.measureText(annotation)
        let boxWidth = max(measured.width * fitScale, scaledFont.pointSize * 3)
        let boxHeight = max(measured.height * fitScale, scaledFont.pointSize * 1.4)

        return InlineTextView(
            text: binding, font: scaledFont, color: annotation.color.nsColor,
            underline: annotation.underline, strikethrough: annotation.strikethrough,
            inset: inset, onCommit: { finishTextEditing() }
        )
        .frame(width: boxWidth, height: boxHeight, alignment: .topLeading)
        .background(overlayBackground)
        .offset(x: origin.x, y: origin.y)
    }

    /// Small centered field over a step marker for editing its label.
    private func stepOverlay(for annotation: Annotation, fitScale: CGFloat,
                             offset: CGPoint) -> some View {
        let diameter = annotation.stepDiameter * fitScale
        let center = CGPoint(x: annotation.start.x * fitScale + offset.x,
                             y: annotation.start.y * fitScale + offset.y)
        let binding = Binding<String>(
            get: { document.annotations.first(where: { $0.id == annotation.id })?.stepLabel ?? "" },
            set: { newValue in update(annotation.id) { $0.stepLabel = newValue } }
        )

        let fontSize = AnnotationRenderer.stepFontSize(
            label: annotation.stepLabel, diameter: annotation.stepDiameter) * fitScale
        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: max(diameter, 32), height: diameter)
            .background(Circle().fill(Color(nsColor: annotation.color.nsColor)))
            .focused($textFieldFocused)
            .onSubmit { finishTextEditing() }
            .onExitCommand { finishTextEditing() }
            .offset(x: center.x - max(diameter, 32) / 2, y: center.y - diameter / 2)
    }
}

// MARK: - Inline multi-line text editor

/// A minimal `NSTextView` wrapper for editing a text annotation inline:
/// **Return commits**, **⇧Return inserts a newline**, **Esc commits**. The
/// annotation renderer already lays out embedded newlines, so multi-line
/// labels round-trip to the exported image.
private struct InlineTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var color: NSColor
    var underline: Bool
    var strikethrough: Bool
    var inset: CGFloat
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CommitTextView {
        let tv = CommitTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainer?.lineFragmentPadding = 0
        tv.string = text
        tv.onCommit = onCommit
        apply(to: tv)
        // Take focus once the view is in a window.
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return tv
    }

    func updateNSView(_ tv: CommitTextView, context: Context) {
        if tv.string != text { tv.string = text }
        tv.onCommit = onCommit
        apply(to: tv)
    }

    private func apply(to tv: NSTextView) {
        tv.textContainerInset = CGSize(width: inset, height: inset)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        tv.typingAttributes = attrs
        tv.textStorage?.setAttributes(
            attrs, range: NSRange(location: 0, length: (tv.string as NSString).length))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: InlineTextView
        init(_ parent: InlineTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

/// NSTextView that commits on Return / Esc and inserts a newline on ⇧Return.
final class CommitTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return, keypad Enter
            if event.modifierFlags.contains(.shift) { insertNewline(self) }
            else { onCommit?() }
        case 53:       // Esc
            onCommit?()
        default:
            super.keyDown(with: event)
        }
    }
}
