import AppKit
import SwiftUI

/// Active tool in the editor toolbar.
enum EditorTool: Equatable, CaseIterable {
    case select, line, arrow, rect, oval, text, drawing, eraser, blur, step, ocr, crop

    /// Drawing tools shown in the toolbar picker. `.ocr` and `.crop` are
    /// transient marquee modes driven by their own buttons in the actions
    /// group, not persistent drawing tools, so they're excluded here.
    static let pickerCases: [EditorTool] = [
        .select, .line, .arrow, .rect, .oval, .text, .drawing, .eraser, .blur, .step
    ]

    /// Layout-independent physical-key shortcuts used while the editor window
    /// is active. OCR and crop stay transient action modes without shortcuts.
    var shortcut: (keyCode: UInt16, label: String)? {
        switch self {
        case .select: return (9, "V")
        case .line:   return (37, "L")
        case .arrow:  return (0, "A")
        case .rect:   return (15, "R")
        case .oval:   return (31, "O")
        case .text:   return (17, "T")
        case .drawing:return (35, "P")
        case .eraser: return (14, "E")
        case .blur:   return (11, "B")
        case .step:   return (1, "S")
        case .ocr, .crop: return nil
        }
    }

    static func tool(forShortcutKeyCode keyCode: UInt16) -> EditorTool? {
        pickerCases.first { $0.shortcut?.keyCode == keyCode }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .line:   return "line.diagonal"
        case .arrow:  return "arrow.up.right"
        case .rect:   return "rectangle"
        case .oval:   return "oval"
        case .text:   return "textformat"
        case .drawing:return "pencil.tip"
        case .eraser: return "eraser"
        case .blur:   return "drop"
        case .step:   return "1.circle"
        case .ocr:    return "text.viewfinder"
        case .crop:   return "crop"
        }
    }

    var labelKey: String {
        switch self {
        case .select: return "Select"
        case .line:   return "Line"
        case .arrow:  return "Arrow"
        case .rect:   return "Rectangle"
        case .oval:   return "Oval"
        case .text:   return "Text"
        case .drawing:return "Drawing"
        case .eraser: return "Eraser"
        case .blur:   return "Blur"
        case .step:   return "Step"
        case .ocr:    return "Recognize Text"
        case .crop:   return "Crop"
        }
    }
}

/// Pure viewport math shared by drag, pinch, toolbar zoom, and tests. Keeping
/// pan normalization in the same update as zoom prevents a stale oversized
/// offset from snapping back a frame later.
enum EditorViewportGeometry {
    static func scaledPanOffset(_ offset: CGSize, from oldZoom: CGFloat,
                                to newZoom: CGFloat) -> CGSize {
        guard oldZoom > 0 else { return .zero }
        let ratio = newZoom / oldZoom
        return CGSize(width: offset.width * ratio, height: offset.height * ratio)
    }

    static func clampedPanOffset(_ offset: CGSize, baseDrawSize: CGSize,
                                 zoom: CGFloat, viewport: CGSize) -> CGSize {
        let maxX = max(0, (baseDrawSize.width * zoom - viewport.width) / 2)
        let maxY = max(0, (baseDrawSize.height * zoom - viewport.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }
}

/// The eight draggable handles of the crop rectangle (corners resize two
/// edges, side handles resize one).
enum CropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
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
    var arrowHeadPlacement: ArrowHeadPlacement = .end
    var lineStyle: LineStyle = .solid
    /// Fill opacity (0…1) for new rect/oval; 0 is outline-only.
    var fillOpacity: CGFloat = 0
    /// nil = image-relative automatic size at placement.
    var fontSize: CGFloat?
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var textShadow = false
    var textBackground: TextBackground = .none
    /// Diameter of new step markers in image pixels.
    var stepDiameter: CGFloat = 40
    var drawingMode: DrawingMode = .pen
    var penWidth: CGFloat = 6
    var markerWidth: CGFloat = 24
    var eraserDiameter: CGFloat = 32

    func width(for mode: DrawingMode) -> CGFloat {
        switch mode {
        case .pen:    return penWidth
        case .marker: return markerWidth
        }
    }

    subscript(textStyle flag: TextStyleFlag) -> Bool {
        get {
            switch flag {
            case .bold:          return bold
            case .italic:        return italic
            case .underline:     return underline
            case .strikethrough: return strikethrough
            case .shadow:        return textShadow
            }
        }
        set {
            switch flag {
            case .bold:          bold = newValue
            case .italic:        italic = newValue
            case .underline:     underline = newValue
            case .strikethrough: strikethrough = newValue
            case .shadow:        textShadow = newValue
            }
        }
    }
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
    /// Called with the marquee's image-pixel rect when the `.ocr` tool's drag
    /// ends, so the owner can OCR just that region.
    var onRecognizeRegion: (CGRect) -> Void = { _ in }
    /// The crop rectangle (image-pixel space) while the `.crop` tool is active;
    /// nil otherwise. The canvas draws it and adjusts it via drag.
    @Binding var cropRect: CGRect?
    /// Commit / cancel the pending crop (also invoked from Return / Esc).
    var onCropApply: () -> Void = {}
    var onCropCancel: () -> Void = {}

    @FocusState private var textFieldFocused: Bool
    @State private var magnificationStart: CGFloat?
    @State private var magnificationStartPan: CGSize?
    @State private var isSpaceHeld = false
    @State private var keyMonitor: Any?
    /// Last committed click, for timing-based double-click detection (the
    /// gesture layer doesn't surface a reliable OS click count).
    @State private var lastClick: (id: UUID?, time: Date, point: CGPoint)?
    @State private var drawingCursorLocation: CGPoint?

    private enum DragMode {
        case undecided(pixelPoint: CGPoint)
        case duplicatePending(sourceID: UUID, start: CGPoint)
        case creating(UUID)
        case drawing(UUID)
        case erasing(last: CGPoint)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Annotation.Handle)
        case panning(last: CGPoint)
        case ocrSelecting(start: CGPoint, current: CGPoint)
        case cropCreating(start: CGPoint)
        case cropMoving(last: CGPoint)
        case cropResizing(CropHandle)
        case ignore
    }
    @State private var dragMode: DragMode?

    /// Handle grab radius in view points (converted to pixels per gesture).
    private let handleGrabPt: CGFloat = 8
    private let hitTolerancePt: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let pixel = document.pixelSize
            // Reserve a margin around the fitted image so its edges (and a
            // crop frame snapped to them) never sit flush against the window,
            // where a drag would resize the window instead of the frame.
            let edgeInset: CGFloat = 24
            let availWidth = max(1, geo.size.width - edgeInset * 2)
            let availHeight = max(1, geo.size.height - edgeInset * 2)
            let baseFitScale = min(min(availWidth / pixel.width,
                                       availHeight / pixel.height), 1.0)
            let fitScale = baseFitScale * zoomFactor
            let baseDrawSize = CGSize(width: pixel.width * baseFitScale,
                                      height: pixel.height * baseFitScale)
            let drawSize = CGSize(width: baseDrawSize.width * zoomFactor,
                                  height: baseDrawSize.height * zoomFactor)
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

                if let diameter = drawingCursorDiameter,
                   let location = drawingCursorLocation,
                   CGRect(origin: offset, size: drawSize).contains(location) {
                    drawingCursor(at: location, diameter: diameter * fitScale)
                }
            }
            .gesture(dragGesture(fitScale: fitScale, offset: offset, pixel: pixel,
                                 viewport: geo.size, baseDrawSize: baseDrawSize))
            .simultaneousGesture(magnificationGesture(baseDrawSize: baseDrawSize,
                                                       viewport: geo.size))
            .onChange(of: zoomFactor) { oldZoom, newZoom in
                // Pinch owns its synchronous pan update below. This path
                // normalizes toolbar and keyboard zoom changes.
                guard magnificationStart == nil else { return }
                let scaled = EditorViewportGeometry.scaledPanOffset(
                    panOffset, from: oldZoom, to: newZoom
                )
                panOffset = EditorViewportGeometry.clampedPanOffset(
                    scaled, baseDrawSize: baseDrawSize,
                    zoom: newZoom, viewport: geo.size
                )
            }
            .onChange(of: geo.size) { _, newViewport in
                panOffset = EditorViewportGeometry.clampedPanOffset(
                    panOffset, baseDrawSize: baseDrawSize,
                    zoom: zoomFactor, viewport: newViewport
                )
            }
            .onChange(of: pixel) { _, _ in
                panOffset = EditorViewportGeometry.clampedPanOffset(
                    panOffset, baseDrawSize: baseDrawSize,
                    zoom: zoomFactor, viewport: geo.size
                )
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): drawingCursorLocation = location
                case .ended: drawingCursorLocation = nil
                }
            }
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

            // OCR marquee (drawn while dragging with the recognize-text tool).
            if case let .ocrSelecting(start, current) = dragMode {
                drawOCRMarquee(from: start, to: current, context: context,
                               fitScale: fitScale, offset: offset)
            }

            // Crop overlay: dim everything outside the crop rect, frame it, and
            // draw its handles.
            if tool == .crop, let cropRect {
                drawCropOverlay(cropRect, context: context, fitScale: fitScale,
                                offset: offset, drawSize: drawSize(fitScale: fitScale))
            }
        }
    }

    /// Pixel image size scaled to the view.
    private func drawSize(fitScale: CGFloat) -> CGSize {
        CGSize(width: document.pixelSize.width * fitScale,
               height: document.pixelSize.height * fitScale)
    }

    private func drawCropOverlay(_ rect: CGRect, context: GraphicsContext,
                                 fitScale: CGFloat, offset: CGPoint, drawSize: CGSize) {
        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * fitScale + offset.x, y: p.y * fitScale + offset.y)
        }
        let viewRect = CGRect(origin: toView(rect.origin),
                              size: CGSize(width: rect.width * fitScale,
                                           height: rect.height * fitScale))
        let imageRect = CGRect(origin: offset, size: drawSize)

        // Dim the four bands of image outside the crop rect.
        var outside = Path(imageRect)
        outside.addRect(viewRect)
        context.fill(outside, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

        // Frame.
        var frame = Path()
        frame.addRect(viewRect)
        context.stroke(frame, with: .color(.white.opacity(0.95)), lineWidth: 1)

        // Rule-of-thirds guides inside the frame.
        var thirds = Path()
        for i in 1...2 {
            let x = viewRect.minX + viewRect.width / 3 * CGFloat(i)
            thirds.move(to: CGPoint(x: x, y: viewRect.minY))
            thirds.addLine(to: CGPoint(x: x, y: viewRect.maxY))
            let y = viewRect.minY + viewRect.height / 3 * CGFloat(i)
            thirds.move(to: CGPoint(x: viewRect.minX, y: y))
            thirds.addLine(to: CGPoint(x: viewRect.maxX, y: y))
        }
        context.stroke(thirds, with: .color(.white.opacity(0.35)), lineWidth: 0.5)

        // Handles.
        for (_, position) in cropHandlePositions(rect) {
            let c = toView(position)
            let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            let square = Path(roundedRect: r, cornerRadius: 1.5)
            context.fill(square, with: .color(.white))
            context.stroke(square, with: .color(.black.opacity(0.5)), lineWidth: 1)
        }
    }

    private func drawOCRMarquee(from start: CGPoint, to current: CGPoint,
                                context: GraphicsContext,
                                fitScale: CGFloat, offset: CGPoint) {
        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * fitScale + offset.x, y: p.y * fitScale + offset.y)
        }
        let a = toView(start), b = toView(current)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        var path = Path()
        path.addRect(rect)
        context.fill(path, with: .color(Color.accentColor.opacity(0.15)))
        context.stroke(path, with: .color(.white.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
        context.stroke(path, with: .color(.black.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 1, dash: [5, 3], dashPhase: 4))
    }

    // MARK: Crop geometry (image-pixel space)

    private func cropHandlePositions(_ r: CGRect) -> [(CropHandle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)),
         (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)),
         (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
         (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
         (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    private func cropHandle(at p: CGPoint, rect: CGRect, tolerance: CGFloat) -> CropHandle? {
        cropHandlePositions(rect).first { hypot($0.1.x - p.x, $0.1.y - p.y) <= tolerance }?.0
    }

    /// Applies a handle drag to the crop rect, clamped to the image and to a
    /// minimum size (the moved edge is pushed back rather than crossing over).
    private func resizedCrop(_ r: CGRect, handle: CropHandle, to p: CGPoint) -> CGRect {
        let pixel = document.pixelSize
        let px = min(max(p.x, 0), pixel.width)
        let py = min(max(p.y, 0), pixel.height)
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft:     minX = px; minY = py
        case .top:         minY = py
        case .topRight:    maxX = px; minY = py
        case .right:       maxX = px
        case .bottomRight: maxX = px; maxY = py
        case .bottom:      maxY = py
        case .bottomLeft:  minX = px; maxY = py
        case .left:        minX = px
        }
        let minSize: CGFloat = 8
        if maxX - minX < minSize {
            switch handle {
            case .topLeft, .bottomLeft, .left: minX = maxX - minSize
            default:                           maxX = minX + minSize
            }
        }
        if maxY - minY < minSize {
            switch handle {
            case .topLeft, .topRight, .top: minY = maxY - minSize
            default:                        maxY = minY + minSize
            }
        }
        // The min-size push-back can nudge an edge past the border when the
        // fixed edge is within minSize of it; clamp back inside the image.
        minX = max(0, minX); minY = max(0, minY)
        maxX = min(pixel.width, maxX); maxY = min(pixel.height, maxY)
        return CGRect(x: minX, y: minY,
                      width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func movedCrop(_ r: CGRect, by d: CGPoint) -> CGRect {
        let pixel = document.pixelSize
        var moved = r.offsetBy(dx: d.x, dy: d.y)
        moved.origin.x = min(max(0, moved.origin.x), pixel.width - moved.width)
        moved.origin.y = min(max(0, moved.origin.y), pixel.height - moved.height)
        return moved
    }

    /// Decides what a mouse-down in crop mode does: grab a handle, move the
    /// rect from inside, or start a fresh rect on empty space.
    private func beginCropDrag(at p: CGPoint, fitScale: CGFloat) -> DragMode {
        let grabPx = handleGrabPt / fitScale
        if let rect = cropRect {
            if let handle = cropHandle(at: p, rect: rect, tolerance: grabPx) {
                return .cropResizing(handle)
            }
            if rect.contains(p) { return .cropMoving(last: p) }
        }
        return .cropCreating(start: p)
    }

    private func drawSelection(for a: Annotation, context: GraphicsContext,
                               fitScale: CGFloat, offset: CGPoint) {
        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * fitScale + offset.x, y: p.y * fitScale + offset.y)
        }

        // Dashed outline for area-like annotations (incl. text bounds).
        // Freehand paths use endpoint markers like lines, avoiding a bounding
        // box that visually suggests the curve itself is rectangular.
        if a.kind != .line && a.kind != .arrow && a.kind != .freehand {
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

        var selectionPoints = a.handles.map(\.1)
        if a.kind == .freehand, let first = a.freehandPoints.first {
            selectionPoints = [first]
            if let last = a.freehandPoints.last, last != first {
                selectionPoints.append(last)
            }
        }

        for position in selectionPoints {
            let c = toView(position)
            let handleRect = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
            let circle = Path(ellipseIn: handleRect)
            context.fill(circle, with: .color(.white))
            context.stroke(circle, with: .color(.blue), lineWidth: 1.5)
        }
    }

    private func drawingCursor(at location: CGPoint, diameter: CGFloat) -> some View {
        Circle()
            .stroke(Color.white.opacity(0.95), lineWidth: 2)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
            .frame(width: max(2, diameter), height: max(2, diameter))
            .position(location)
            .allowsHitTesting(false)
    }

    private var drawingCursorDiameter: CGFloat? {
        switch tool {
        case .drawing where style.drawingMode == .marker:
            return style.markerWidth
        case .eraser:
            return style.eraserDiameter
        default:
            return nil
        }
    }

    // MARK: Gesture

    private func dragGesture(fitScale: CGFloat, offset: CGPoint, pixel: CGSize,
                             viewport: CGSize, baseDrawSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Continuous-hover events pause while the mouse button is
                // down, so keep the brush/eraser indicator attached to the
                // pointer from the drag stream itself.
                if tool == .drawing || tool == .eraser {
                    drawingCursorLocation = value.location
                }
                let p = pixelPoint(value.location, fitScale: fitScale, offset: offset, pixel: pixel)

                if dragMode == nil {
                    // First event of the gesture: a click anywhere commits an
                    // in-progress text edit before anything else happens.
                    if editingTextID != nil {
                        finishTextEditing()
                        dragMode = .ignore
                        return
                    }
                    if tool == .crop {
                        // Interacting with the frame takes focus off the size
                        // fields, so arrow keys move the frame (not the caret).
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        dragMode = beginCropDrag(at: p, fitScale: fitScale)
                    } else if isSpaceHeld {
                        dragMode = .panning(last: value.location)
                    } else if tool != .ocr, beginEditingIfDoubleClick(at: p, fitScale: fitScale) {
                        // A double-click on text/step opens its inline editor
                        // instead of starting a move — detected at mouse-down
                        // so it works even on an already-selected annotation.
                        dragMode = .ignore
                    } else {
                        dragMode = beginDrag(at: p, fitScale: fitScale)
                    }
                }

                switch dragMode {
                case .duplicatePending(let sourceID, let start):
                    let viewDistance = hypot(value.translation.width, value.translation.height)
                    guard viewDistance >= 3 else { break }
                    document.beginChange()
                    let offset = CGPoint(x: p.x - start.x, y: p.y - start.y)
                    guard let duplicateID = document.appendDuplicate(
                        of: sourceID, offset: offset
                    ) else {
                        document.discardChange()
                        dragMode = .ignore
                        break
                    }
                    dragMode = .moving(duplicateID, last: p)

                case .drawing(let id):
                    let sampleDistance = max(0.5, 1 / fitScale)
                    update(id) {
                        $0.appendFreehandPoint(p, minimumDistance: sampleDistance)
                    }

                case .erasing(let last):
                    document.eraseFreehand(
                        from: last, to: p, diameter: style.eraserDiameter
                    )
                    dragMode = .erasing(last: p)

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
                    annotation.arrowHeadPlacement = style.arrowHeadPlacement
                    annotation.lineStyle = style.lineStyle
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
                        // Curve control: dragging near the straight start–end
                        // segment snaps the arrow back to straight, so bending
                        // is fully reversible without any extra UI.
                        if handle == .control, annotation.kind == .arrow {
                            let snapDistance = 4 / fitScale
                            let straightDistance = Annotation.distance(
                                from: p, toSegment: annotation.start, annotation.end
                            )
                            annotation.curveControl =
                                straightDistance <= snapDistance ? nil : p
                            return
                        }
                        if isShiftHeld,
                           annotation.kind == .line || annotation.kind == .arrow {
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

                case .ocrSelecting(let start, _):
                    dragMode = .ocrSelecting(start: start, current: p)

                case .cropCreating(let start):
                    // Ignore a stray click (or the first sub-pixel of a drag) so
                    // it doesn't collapse the existing frame; only a real drag
                    // starts a fresh rect.
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved >= 3 {
                        let raw = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                         width: abs(p.x - start.x), height: abs(p.y - start.y))
                        cropRect = raw.intersection(CGRect(origin: .zero, size: pixel))
                    }

                case .cropMoving(let last):
                    if let rect = cropRect {
                        cropRect = movedCrop(rect, by: CGPoint(x: p.x - last.x, y: p.y - last.y))
                    }
                    dragMode = .cropMoving(last: p)

                case .cropResizing(let handle):
                    if let rect = cropRect {
                        cropRect = resizedCrop(rect, handle: handle, to: p)
                    }

                case .panning(let last):
                    // Clamp so the image can't be dragged past its overflow
                    // (and stays centered when it fits — no free-floating).
                    let proposed = CGSize(
                        width: panOffset.width + value.location.x - last.x,
                        height: panOffset.height + value.location.y - last.y
                    )
                    panOffset = EditorViewportGeometry.clampedPanOffset(
                        proposed, baseDrawSize: baseDrawSize,
                        zoom: zoomFactor, viewport: viewport
                    )
                    dragMode = .panning(last: value.location)

                case .ignore, nil:
                    break
                }
            }
            .onEnded { value in
                defer { dragMode = nil }
                if tool == .drawing || tool == .eraser {
                    drawingCursorLocation = value.location
                }
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
                case .drawing(let id):
                    update(id) { $0.appendFreehandPoint(p, minimumDistance: 0.01) }
                    if let annotation = document.annotations.first(where: { $0.id == id }),
                       annotation.isDegenerate {
                        document.annotations.removeAll { $0.id == id }
                        document.selectedID = nil
                        document.discardChange()
                    } else {
                        // Finishing a stroke leaves Drawing ready for the next
                        // stroke. Keeping the old one selected makes changing
                        // Pen/Marker look like a tool switch while silently
                        // restyling the annotation that was just created.
                        document.selectedID = nil
                        document.commitChange()
                    }
                case .erasing:
                    document.commitChange()
                case .moving, .resizing:
                    document.commitChange()
                case .ocrSelecting(let start, _):
                    let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                      width: abs(p.x - start.x), height: abs(p.y - start.y))
                    if rect.width >= 4, rect.height >= 4 { onRecognizeRegion(rect) }
                case .duplicatePending, .cropCreating, .cropMoving, .cropResizing,
                     .panning, .ignore, nil:
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

        // Option-drag duplicates any annotation body under the cursor, even
        // while a regular drawing tool is active. OCR and crop keep exclusive
        // ownership of their gestures. Creation is deferred until movement
        // crosses the standard 3 pt drag threshold, so Option-click only selects.
        if tool != .ocr, tool != .crop, isOptionHeld,
           let hit = document.annotation(at: p, tolerance: tolerancePx) {
            document.selectedID = hit.id
            return .duplicatePending(sourceID: hit.id, start: p)
        }

        switch tool {
        case .ocr:
            // The recognize-text tool never touches annotations: any drag is a
            // marquee over the region to OCR.
            return .ocrSelecting(start: p, current: p)
        case .crop:
            // Crop drags are routed through beginCropDrag before reaching here.
            return .ignore
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
        case .drawing:
            document.selectedID = nil
            document.beginChange()
            let width = style.width(for: style.drawingMode)
            var annotation = Annotation(kind: .freehand, start: p, end: p,
                                        color: style.color, lineWidth: width)
            annotation.freehandStyle = style.drawingMode.freehandStyle
            annotation.appendFreehandPoint(p, minimumDistance: 0)
            document.annotations.append(annotation)
            document.selectedID = annotation.id
            return .drawing(annotation.id)
        case .eraser:
            document.selectedID = nil
            document.beginChange()
            document.eraseFreehand(from: p, to: p, diameter: style.eraserDiameter)
            return .erasing(last: p)
        case .line, .arrow, .rect, .oval, .blur, .step:
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
        case .line:  return .line
        case .arrow: return .arrow
        case .rect:  return .rect
        case .oval:  return .oval
        case .blur:  return .blur
        case .select, .text, .drawing, .eraser, .step, .ocr, .crop: return nil
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

    private var isOptionHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func constrainedEndpoint(_ point: CGPoint, from start: CGPoint,
                                     kind: AnnotationKind) -> CGPoint {
        guard isShiftHeld else { return point }
        switch kind {
        case .line, .arrow:
            return Annotation.snappedArrowEnd(from: start, to: point)
        case .rect, .oval:
            return Annotation.aspectLockedEnd(from: start, to: point)
        case .text, .freehand, .blur, .step:
            return point
        }
    }

    private func magnificationGesture(baseDrawSize: CGSize,
                                      viewport: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                if magnificationStart == nil {
                    magnificationStart = zoomFactor
                    magnificationStartPan = panOffset
                }
                let startZoom = magnificationStart ?? zoomFactor
                let newZoom = clampedZoom(startZoom * magnification)
                let scaled = EditorViewportGeometry.scaledPanOffset(
                    magnificationStartPan ?? panOffset,
                    from: startZoom, to: newZoom
                )
                zoomFactor = newZoom
                panOffset = EditorViewportGeometry.clampedPanOffset(
                    scaled, baseDrawSize: baseDrawSize,
                    zoom: newZoom, viewport: viewport
                )
            }
            .onEnded { _ in
                magnificationStart = nil
                magnificationStartPan = nil
            }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(8, max(0.25, value))
    }

    // MARK: Keyboard input

    private func activateTool(_ newTool: EditorTool) {
        tool = newTool
        cropRect = nil
        if newTool != .select { document.selectedID = nil }
        if newTool == .blur {
            document.prepareBlurSource(style: style.blurStyle,
                                       level: style.blurLevel)
        }
    }

    private func toggleTextStyle(_ flag: TextStyleFlag) {
        let editingTextID = editingTextID.flatMap { id in
            document.annotations.first(where: { $0.id == id && $0.kind == .text })?.id
        }
        let selectedTextID = document.selectedAnnotation?.kind == .text
            ? document.selectedID : nil

        if let targetID = editingTextID ?? selectedTextID,
           let newValue = document.toggleTextStyle(
               flag, annotationID: targetID, undoable: editingTextID == nil
           ) {
            style[textStyle: flag] = newValue
        } else if document.selectedID == nil {
            style[textStyle: flag].toggle()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard EditorWindowController.shared.isKeyWindow else { return event }

            let commandModifiers = event.modifierFlags
                .intersection([.command, .control, .option, .shift])
            let fieldHasFocus = NSApp.keyWindow?.firstResponder is NSText
            let isEditingText = self.editingTextID.flatMap { id in
                self.document.annotations.first(where: { $0.id == id })?.kind
            } == .text

            // Formatting applies to the whole selected/edited text annotation,
            // or configures the next label when nothing is selected. Handle it
            // before the inline-edit guard so typing can continue uninterrupted.
            if event.type == .keyDown,
               let textStyle = TextStyleFlag.shortcut(
                   keyCode: event.keyCode, modifiers: commandModifiers
               ), isEditingText || (!fieldHasFocus
                    && (self.document.selectedAnnotation?.kind == .text
                        || self.document.selectedID == nil)) {
                self.toggleTextStyle(textStyle)
                return nil
            }

            guard self.editingTextID == nil else { return event }

            if event.keyCode == 49 { // Space
                self.isSpaceHeld = event.type == .keyDown
                return nil
            }

            // Duplicate the current annotation. Exact modifiers avoid stealing
            // other Command+D variants; no selection leaves the event untouched.
            if event.type == .keyDown, event.keyCode == 2, // D
               commandModifiers == .command,
               self.document.duplicateSelected() != nil {
                return nil
            }

            // Z-order of the selection: ⌘[ backward, ⌘] forward, and the
            // ⇧⌘ variants jump straight to back/front (design-app convention).
            if event.type == .keyDown, !fieldHasFocus,
               self.document.selectedID != nil,
               event.keyCode == 33 || event.keyCode == 30 { // [ , ]
                if commandModifiers == .command {
                    event.keyCode == 30
                        ? self.document.bringSelectedForward()
                        : self.document.sendSelectedBackward()
                    return nil
                }
                if commandModifiers == [.command, .shift] {
                    event.keyCode == 30
                        ? self.document.bringSelectedToFront()
                        : self.document.sendSelectedToBack()
                    return nil
                }
            }

            // Single-letter tool shortcuts are active only when typing cannot
            // be in progress. Requiring no modifiers leaves system/menu key
            // combinations untouched.
            if event.type == .keyDown, !fieldHasFocus,
               commandModifiers.isEmpty,
               let shortcutTool = EditorTool.tool(forShortcutKeyCode: event.keyCode) {
                self.activateTool(shortcutTool)
                return nil
            }

            // Crop mode: Return applies, Esc cancels — handled before the
            // generic Esc so it doesn't just drop the tool. Skip while a text
            // field (the dimension inputs) has focus, so Return commits the
            // typed value instead of the whole crop.
            if event.type == .keyDown, self.tool == .crop, !fieldHasFocus {
                switch event.keyCode {
                case 36, 76: self.onCropApply();  return nil   // Return, keypad Enter
                case 53:     self.onCropCancel(); return nil   // Esc
                default:     break
                }
                // Nudge the crop frame with the same 1 / ⇧10 / ⌥⇧50 tiers.
                if let rect = self.cropRect, let delta = Self.nudgeDelta(for: event) {
                    self.cropRect = self.movedCrop(rect, by: delta)
                    return nil
                }
            }

            // Esc walks the interaction hierarchy. Handled here (not via
            // SwiftUI onExitCommand) because the Canvas is never first
            // responder, so the command modifier never reaches the view.
            if event.type == .keyDown, event.keyCode == 53 {
                if self.tool != .select {
                    self.tool = .select
                } else if self.document.selectedID != nil {
                    self.document.selectedID = nil
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

            // Arrow-key nudge of the selected annotation (same tiers as crop).
            guard let delta = Self.nudgeDelta(for: event) else { return event }
            self.document.nudgeSelected(by: delta)
            return nil
        }
    }

    /// Arrow-key nudge delta in native image pixels: 1, ⇧ 10, ⌥⇧ 50. Returns
    /// nil for non-arrow keys or when Command/Control is held (reserved for
    /// menu shortcuts). Shared by the annotation nudge and the crop frame.
    private static func nudgeDelta(for event: NSEvent) -> CGPoint? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        let shift = event.modifierFlags.contains(.shift)
        let option = event.modifierFlags.contains(.option)
        let amount: CGFloat = (shift && option) ? 50 : (shift ? 10 : 1)
        switch event.keyCode {
        case 123: return CGPoint(x: -amount, y: 0) // left
        case 124: return CGPoint(x: amount, y: 0)  // right
        case 125: return CGPoint(x: 0, y: amount)  // down
        case 126: return CGPoint(x: 0, y: -amount) // up
        default:  return nil
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
        // The box hugs the measured text and grows in both axes as the user
        // types (the editor never wraps — only explicit newlines add rows). A
        // little trailing slack keeps the caret visible past the last glyph.
        let caretSlack = scaledFont.pointSize * 0.6
        let boxWidth = max(measured.width * fitScale + caretSlack, scaledFont.pointSize * 3)
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
            .foregroundStyle(Color(nsColor: annotation.color.contrastingTextColor))
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
        // Never soft-wrap: the container is unbounded so a long line keeps
        // extending horizontally, and the SwiftUI frame (sized to the measured
        // text) grows to match. Only an explicit ⇧Return adds a row.
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                        height: CGFloat.greatestFiniteMagnitude)
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
