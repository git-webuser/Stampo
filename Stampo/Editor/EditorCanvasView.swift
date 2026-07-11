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
    var lineWidth: CGFloat = 4
    var blurStyle: BlurStyle = .pixelate
    var fillEnabled = false
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
            let fitSize = CGSize(width: pixel.width * baseFitScale,
                                 height: pixel.height * baseFitScale)
            let offset = CGPoint(x: (geo.size.width - fitSize.width) / 2 + panOffset.width,
                                 y: (geo.size.height - fitSize.height) / 2 + panOffset.height)

            ZStack(alignment: .topLeading) {
                canvas(fitScale: fitScale, offset: offset)

                if let editingID = editingTextID,
                   let annotation = document.annotations.first(where: { $0.id == editingID }) {
                    textOverlay(for: annotation, fitScale: fitScale, offset: offset)
                }
            }
            .gesture(dragGesture(fitScale: fitScale, offset: offset, pixel: pixel))
            .simultaneousGesture(magnificationGesture())
            .clipped()
        }
        .onDeleteCommand {
            guard editingTextID == nil else { return }
            document.deleteSelected()
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: Canvas

    private func canvas(fitScale: CGFloat, offset: CGPoint) -> some View {
        Canvas { context, _ in
            context.withCGContext { cg in
                cg.saveGState()
                cg.translateBy(x: offset.x, y: offset.y)
                cg.scaleBy(x: fitScale, y: fitScale)
                AnnotationRenderer.draw(
                    in: cg,
                    base: document.baseImage,
                    blurred: document.blurredBase,
                    pixelated: document.pixelatedBase,
                    annotations: document.annotations,
                    skipping: editingTextID
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

    private func dragGesture(fitScale: CGFloat, offset: CGPoint, pixel: CGSize) -> some Gesture {
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
                    dragMode = isSpaceHeld
                        ? .panning(last: value.location)
                        : beginDrag(at: p, fitScale: fitScale)
                }

                switch dragMode {
                case .undecided(let startPixel):
                    // Promote to creation once the user actually drags.
                    let viewDistance = hypot(value.translation.width, value.translation.height)
                    guard viewDistance >= 3, let kind = shapeKind(for: tool) else { break }
                    document.beginChange()
                    var annotation = Annotation(kind: kind, start: startPixel, end: p,
                                                color: style.color, lineWidth: style.lineWidth)
                    annotation.blurStyle = style.blurStyle
                    annotation.fillOpacity = style.fillEnabled ? 0.2 : 0
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
                    panOffset.width += value.location.x - last.x
                    panOffset.height += value.location.y - last.y
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
            document.selectedID = nil
            return .ignore
        case .text:
            // Text places on click (handled in onEnded), never by drag.
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

    /// A click that never became a drag.
    private func handleClick(at p: CGPoint, fitScale: CGFloat) {
        let tolerancePx = hitTolerancePt / fitScale

        if tool == .text {
            if let hit = document.annotation(at: p, tolerance: tolerancePx), hit.kind == .text {
                startEditingText(hit.id)
            } else {
                placeText(at: p)
            }
            return
        }

        if tool == .step {
            placeStep(at: p)
            return
        }

        if let hit = document.annotation(at: p, tolerance: tolerancePx) {
            if hit.kind == .text, document.selectedID == hit.id {
                // Second click on an already-selected text = edit it.
                startEditingText(hit.id)
            } else {
                document.selectedID = hit.id
            }
        } else {
            document.selectedID = nil
        }
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

            guard event.type == .keyDown,
                  self.document.selectedID != nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }

            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
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
        annotation.fontSize = max(24, document.pixelSize.width / 60)
        document.annotations.append(annotation)
        document.selectedID = annotation.id
        startEditingText(annotation.id, isNew: true)
    }

    private func placeStep(at p: CGPoint) {
        document.beginChange()
        var annotation = Annotation(kind: .step, start: p, end: p,
                                    color: style.color, lineWidth: style.lineWidth)
        annotation.stepNumber = document.nextStepNumber
        document.annotations.append(annotation)
        document.selectedID = annotation.id
        document.commitChange()
    }

    private func startEditingText(_ id: UUID, isNew: Bool = false) {
        if !isNew { document.beginChange() }
        editingTextID = id
        textFieldFocused = true
    }

    func finishTextEditing() {
        guard let id = editingTextID else { return }
        editingTextID = nil
        textFieldFocused = false
        document.finishTextEditing(id)
    }

    private func textOverlay(for annotation: Annotation, fitScale: CGFloat,
                             offset: CGPoint) -> some View {
        let origin = CGPoint(x: min(annotation.start.x, annotation.end.x) * fitScale + offset.x,
                             y: min(annotation.start.y, annotation.end.y) * fitScale + offset.y)
        let binding = Binding<String>(
            get: { document.annotations.first(where: { $0.id == annotation.id })?.text ?? "" },
            set: { newValue in update(annotation.id) { $0.text = newValue } }
        )

        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: annotation.fontSize * fitScale, weight: .semibold))
            .foregroundStyle(Color(nsColor: annotation.color.nsColor))
            .background(Color.black.opacity(0.25))
            .frame(minWidth: 120)
            .fixedSize()
            .focused($textFieldFocused)
            .onSubmit { finishTextEditing() }
            .onExitCommand { finishTextEditing() }
            .offset(x: origin.x, y: origin.y)
    }
}
