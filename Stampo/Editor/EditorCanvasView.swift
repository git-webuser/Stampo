import SwiftUI

/// Active tool in the editor toolbar.
enum EditorTool: Equatable, CaseIterable {
    case select, arrow, rect, oval, text, blur

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow:  return "arrow.up.right"
        case .rect:   return "rectangle"
        case .oval:   return "oval"
        case .text:   return "textformat"
        case .blur:   return "drop"
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
        }
    }
}

/// Current stroke style shared by the toolbar and the canvas.
struct ToolStyle {
    var color: AnnotationColor = .red
    var lineWidth: CGFloat = 8
    var blurStyle: BlurStyle = .pixelate
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

    @FocusState private var textFieldFocused: Bool

    private enum DragMode {
        case undecided(pixelPoint: CGPoint)
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Annotation.Handle)
        case ignore
    }
    @State private var dragMode: DragMode?

    /// Handle grab radius in view points (converted to pixels per gesture).
    private let handleGrabPt: CGFloat = 8
    private let hitTolerancePt: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let pixel = document.pixelSize
            let fitScale = min(min(geo.size.width / pixel.width,
                                   geo.size.height / pixel.height), 1.0)
            let drawSize = CGSize(width: pixel.width * fitScale,
                                  height: pixel.height * fitScale)
            let offset = CGPoint(x: (geo.size.width - drawSize.width) / 2,
                                 y: (geo.size.height - drawSize.height) / 2)

            ZStack(alignment: .topLeading) {
                canvas(fitScale: fitScale, offset: offset)

                if let editingID = editingTextID,
                   let annotation = document.annotations.first(where: { $0.id == editingID }) {
                    textOverlay(for: annotation, fitScale: fitScale, offset: offset)
                }
            }
            .gesture(dragGesture(fitScale: fitScale, offset: offset, pixel: pixel))
        }
        .onDeleteCommand {
            guard editingTextID == nil else { return }
            document.deleteSelected()
        }
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
            path.addRect(viewRect)
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
                    dragMode = beginDrag(at: p, fitScale: fitScale)
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
                    document.annotations.append(annotation)
                    document.selectedID = annotation.id
                    dragMode = .creating(annotation.id)

                case .creating(let id):
                    update(id) { $0.end = p }

                case .moving(let id, let last):
                    let delta = CGPoint(x: p.x - last.x, y: p.y - last.y)
                    update(id) { $0.move(by: delta) }
                    dragMode = .moving(id, last: p)

                case .resizing(let id, let handle):
                    update(id) { $0.apply(handle: handle, to: p) }

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
                case .ignore, nil:
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
        case .arrow, .rect, .oval, .blur:
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
        case .select, .text: return nil
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
