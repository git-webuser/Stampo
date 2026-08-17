import AppKit
import SwiftUI

/// Active tool in the editor toolbar.
enum EditorTool: Equatable, CaseIterable {
    case select, line, arrow, rect, oval, roundedRect, polygon, star,
         bubble, text, drawing, eraser, blur, step, loupe, scan, crop

    /// Drawing tools shown in the toolbar picker — the set the keyboard
    /// shortcuts resolve against. Scan and Crop are transient modes driven by
    /// their own toolbar buttons, not persistent drawing tools, so they're
    /// excluded here.
    static let pickerCases: [EditorTool] = [
        .select, .line, .arrow, .rect, .oval, .text, .drawing, .eraser, .blur, .step, .loupe
    ]

    /// Layout-independent physical-key shortcuts used while the editor window
    /// is active. Recognition and crop stay transient modes without shortcuts.
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
        case .loupe:  return (46, "M")
        // Popover-only shapes are low-frequency and stay shortcut-free;
        // recognition and crop stay transient modes without shortcuts.
        case .roundedRect, .polygon, .star, .bubble,
             .scan, .crop: return nil
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
        case .roundedRect: return "app"
        case .polygon:  return "hexagon"
        case .star:     return "star"
        case .bubble:   return "bubble.right"
        case .text:   return "textformat"
        case .drawing:return "pencil.tip"
        case .eraser: return "eraser"
        case .blur:   return "drop"
        case .step:   return "1.circle"
        case .loupe:  return "magnifyingglass"
        case .scan:   return "doc.viewfinder"
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
        case .roundedRect: return "Rounded Rectangle"
        case .polygon:  return "Polygon"
        case .star:     return "Star"
        case .bubble:   return "Bubble"
        case .text:   return "Text"
        case .drawing:return "Drawing"
        case .eraser: return "Eraser"
        case .blur:   return "Blur"
        case .step:   return "Numbering"
        case .loupe:  return "Loupe"
        case .scan:   return "Scan"
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

    /// The zoom range, in one place.
    ///
    /// The pinch gesture, the toolbar's ±, and the scan overlay's forwarded
    /// pinch all have to agree about how far the canvas may zoom, and the
    /// bounds were written out twice before this existed.
    static func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(8, max(0.25, value))
    }

    static func clampedPanOffset(_ offset: CGSize, baseDrawSize: CGSize,
                                 zoom: CGFloat, viewport: CGSize) -> CGSize {
        let maxX = max(0, (baseDrawSize.width * zoom - viewport.width) / 2)
        let maxY = max(0, (baseDrawSize.height * zoom - viewport.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }

    /// Zoom and pan that bring `content` fully into view, where zoom 1 means
    /// "the canvas exactly fits".
    ///
    /// Fit is how a user finds something they have lost. If it only ever framed
    /// the canvas, an annotation dragged outside would stay off screen and the
    /// one command meant to reveal everything would be the one that hides it.
    static func fitAll(canvasSize: CGSize, content: CGRect,
                       canvasBaseDrawSize: CGSize) -> (zoom: CGFloat, pan: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0,
              content.width > 0, content.height > 0,
              canvasBaseDrawSize.width > 0
        else { return (1, .zero) }
        let zoom = clampedZoom(min(1, min(canvasSize.width / content.width,
                                          canvasSize.height / content.height)))
        let baseScale = canvasBaseDrawSize.width / canvasSize.width
        let dx = content.midX - canvasSize.width / 2
        let dy = content.midY - canvasSize.height / 2
        return (zoom, CGSize(width: -dx * baseScale * zoom,
                             height: -dy * baseScale * zoom))
    }
}

/// The pointer, expressed in both spaces the editor works in.
///
/// Blur and loupe are measured in image pixels; every other annotation in
/// canvas pixels. Which one a gesture needs depends on what it is touching, and
/// what it is touching is only known after the hit test — so both are carried
/// and each annotation is asked for its own. Without a presentation the two are
/// the same point and the same scale.
struct SpacedPoint {
    let image: CGPoint
    let canvas: CGPoint
    let imageScale: CGFloat
    let canvasScale: CGFloat

    func point(imageSpace: Bool) -> CGPoint { imageSpace ? image : canvas }
    func scale(imageSpace: Bool) -> CGFloat { imageSpace ? imageScale : canvasScale }
    func point(for a: Annotation) -> CGPoint { point(imageSpace: a.livesInImageSpace) }
    func scale(for a: Annotation) -> CGFloat { scale(imageSpace: a.livesInImageSpace) }
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
    /// Routing of new arrows (bendable shaft vs. elbowed run).
    var arrowRoute: ArrowRoute = .curved
    /// Whether elbowed arrows quantize their legs and endpoints to the grid.
    var snapsToGrid = true
    var arrowHeadPlacement: ArrowHeadPlacement = .end
    var arrowHeadScale: CGFloat = 1
    var lineStyle: LineStyle = .solid
    /// Fill opacity (0…1) for new rect/oval; 0 is outline-only.
    var fillOpacity: CGFloat = 0
    /// Sides for new polygons (ShapeCounts.polygonSides).
    var polygonSides: Int = ShapeCounts.defaultPolygonSides
    /// Points for new stars (ShapeCounts.starPoints).
    var starPoints: Int = ShapeCounts.defaultStarPoints
    /// Tail side for new bubbles.
    var bubbleTail: BubbleTailDirection = .right
    /// nil = image-relative automatic size at placement.
    var fontSize: CGFloat?
    var fontPreset: AnnotationFontPreset = .system
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var textShadow = false
    var textBackground: TextBackground = .none
    /// Paragraph alignment of new text annotations.
    var textAlignment: TextAlign = .left
    /// Diameter of new step markers in image pixels.
    var stepDiameter: CGFloat = 40
    /// Explicit label size for new step markers; nil auto-fits the diameter.
    var stepLabelSize: CGFloat? = nil
    /// Magnification factor of new loupes.
    var loupeScale: CGFloat = 2
    /// Outline of new loupes.
    var loupeShape: LoupeShape = .oval
    /// Whether new loupes are callouts (source marker + detached magnifier).
    var loupeCallout = false
    /// Whether new loupes reveal the original (unredacted) pixels.
    var loupeRevealsOriginal = false
    var drawingMode: DrawingMode = .pen
    /// Nib shape for new marker strokes.
    var markerTip: MarkerTip = .round
    var penWidth: CGFloat = 6
    var markerWidth: CGFloat = 24
    var eraserDiameter: CGFloat = 32
    /// Whether the scanner glues recognized lines back into paragraphs instead
    /// of keeping every line break the scanned layout happened to produce.
    /// On by default: the breaks belong to the page the text was read off,
    /// not to the text, and pasting them somewhere else means cleaning them
    /// out by hand.
    var scanJoinsLines = true

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
    /// The crop rectangle (image-pixel space) while the `.crop` tool is active;
    /// nil otherwise. The canvas draws it and adjusts it via drag.
    @Binding var cropRect: CGRect?
    /// Commit / cancel the pending crop (also invoked from Return / Esc).
    var onCropApply: () -> Void = {}
    var onCropCancel: () -> Void = {}
    /// Where the fitted image currently sits on screen. The scanner opens its
    /// overlay over exactly this rect, so it follows zoom and pan for free.
    @Binding var imageScreenGeometry: ImageScreenGeometry?

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
        case movingLoupePart(UUID, Annotation.LoupePart, last: CGPoint)
        case resizing(UUID, Annotation.Handle)
        /// Sliding one leg of an elbow arrow's route parallel to itself. The
        /// route as it was when the drag began travels with the mode: deriving
        /// it afresh each frame would feed the gesture its own output, and
        /// since the move adds or removes corners, the leg `index` refers to
        /// would shift under it and the leg would oscillate.
        case routeSegment(UUID, index: Int, baseline: [CGPoint])
        case panning(last: CGPoint)
        case cropCreating(start: CGPoint)
        case cropMoving(last: CGPoint)
        case cropResizing(CropHandle)
        /// The picture is an object too: it drags and resizes like everything
        /// else on the canvas, in canvas pixels.
        case movingImage(last: CGPoint)
        case resizingImage(ImageCorner)
        case ignore
    }
    @State private var dragMode: DragMode?
    /// The picture is selected. Kept apart from `document.selectedID`, which
    /// names an annotation — the picture is not one, it is what they sit on.
    @State private var imageSelected = false

    /// Handle grab radius in view points (converted to pixels per gesture).
    private let handleGrabPt: CGFloat = 8
    private let hitTolerancePt: CGFloat = 6
    /// Catch distance (view points) for snapping an arrow endpoint to a shape:
    /// the reach of the reference anchors and the outline magnet, plus how far
    /// outside a shape the magnet still grabs.
    private let bindMagnetPt: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let pixel = document.pixelSize
            // Crop stays in image-pixel space while it is active. Hiding the
            // presentation there keeps the existing crop interaction safe;
            // the styled canvas returns as soon as the crop is committed.
            let renderPresentation = tool == .crop ? nil : document.presentation
            let geometry = EditorCanvasGeometry.resolve(
                viewport: geo.size,
                imagePixelSize: pixel,
                presentation: renderPresentation,
                zoom: zoomFactor,
                pan: panOffset
            )
            let fitScale = geometry.imageFitScale
            let baseDrawSize = geometry.canvasBaseDrawSize
            let drawSize = geometry.imageDrawSize
            let offset = geometry.imageOffset

            ZStack(alignment: .topLeading) {
                canvas(
                    presentation: renderPresentation,
                    layout: geometry.presentationLayout,
                    canvasScale: geometry.canvasScale,
                    canvasOffset: geometry.canvasOffset,
                    fitScale: fitScale,
                    offset: offset
                )

                if let editingID = editingTextID,
                   let annotation = document.annotations.first(where: { $0.id == editingID }) {
                    if annotation.kind == .step {
                        stepOverlay(for: annotation,
                                    fitScale: geometry.canvasScale,
                                    offset: geometry.canvasOffset)
                    } else {
                        textOverlay(for: annotation,
                                    fitScale: geometry.canvasScale,
                                    offset: geometry.canvasOffset)
                    }
                }

                if let diameter = drawingCursorDiameter,
                   let location = drawingCursorLocation,
                   CGRect(origin: offset, size: drawSize).contains(location) {
                    drawingCursor(at: location, diameter: diameter * fitScale)
                }

                // Sits exactly over the drawn image and only measures it.
                ImageScreenFrameReporter { rect in
                    let next = rect.map {
                        ImageScreenGeometry(
                            screenRect: $0,
                            fitScale: fitScale,
                            baseDrawSize: baseDrawSize,
                            viewport: geo.size,
                            visibleScreenRect: ImageScreenGeometry.visibleScreenRect(
                                image: $0,
                                imageViewRect: CGRect(origin: offset, size: drawSize),
                                viewport: geo.size
                            )
                        )
                    }
                    // `@State` publishes on assignment, not on change, so an
                    // identical value would schedule the render that computes
                    // it again.
                    if next != imageScreenGeometry { imageScreenGeometry = next }
                }
                .frame(width: drawSize.width, height: drawSize.height)
                .position(x: offset.x + drawSize.width / 2,
                          y: offset.y + drawSize.height / 2)
                .allowsHitTesting(false)
            }
            .gesture(dragGesture(fitScale: fitScale, offset: offset, pixel: pixel,
                                 annotationBounds: reachableAnnotationBounds(
                                    pixel: pixel,
                                    layout: geometry.presentationLayout,
                                    hasPresentation: renderPresentation != nil
                                 ),
                                 canvasScale: geometry.canvasScale,
                                 canvasOffset: geometry.canvasOffset,
                                 canvasBounds: reachableCanvasBounds(
                                    layout: geometry.presentationLayout,
                                    hasPresentation: renderPresentation != nil
                                 ),
                                 canvasSize: geometry.presentationLayout.canvasSize,
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
            .onChange(of: document.presentation) { _, _ in
                panOffset = EditorViewportGeometry.clampedPanOffset(
                    panOffset, baseDrawSize: baseDrawSize,
                    zoom: zoomFactor, viewport: geo.size
                )
            }
            .onChange(of: tool) { _, _ in
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

    /// Id of a callout loupe still being drawn — the rect the user is dragging
    /// is the source marker, shown as a plain outline until release turns it
    /// into a magnifier. nil for in-place loupes and every other tool.
    private var calloutMarkerPreviewID: UUID? {
        guard style.loupeCallout, case .creating(let id) = dragMode,
              document.annotations.first(where: { $0.id == id })?.kind == .loupe
        else { return nil }
        return id
    }

    // MARK: Canvas

    private func canvas(presentation: Presentation?,
                        layout: PresentationLayout.Resolved,
                        canvasScale: CGFloat,
                        canvasOffset: CGPoint,
                        fitScale: CGFloat,
                        offset: CGPoint) -> some View {
        Canvas { context, _ in
            let markerPreviewID = calloutMarkerPreviewID
            context.withCGContext { cg in
                cg.saveGState()
                cg.translateBy(x: canvasOffset.x, y: canvasOffset.y)
                cg.scaleBy(x: canvasScale, y: canvasScale)
                // Skip the magnifier for: a text annotation being edited (its
                // TextField overlays it) and a callout loupe still being drawn
                // — the marker region is defined without magnification, which
                // only appears once the drag ends.
                let skipID = editingAnnotation?.kind == .text ? editingTextID
                    : markerPreviewID
                if let presentation {
                    PresentationRenderer.draw(
                        in: cg,
                        base: document.baseImage,
                        blurSources: document.blurSources,
                        annotations: document.annotations,
                        presentation: presentation,
                        layout: layout,
                        skipping: skipID
                    )
                    // Editor only: show what the canvas cropped away, so it can
                    // still be selected and moved back in.
                    PresentationRenderer.drawGhostOutsideCanvas(
                        in: cg,
                        base: document.baseImage,
                        blurSources: document.blurSources,
                        annotations: document.annotations,
                        layout: layout,
                        skipping: skipID
                    )
                } else {
                    // Match the export contract: without presentation the
                    // bitmap is exactly the image bounds, so annotation ink
                    // beyond those bounds must be clipped in the live preview
                    // as well. Selection chrome is drawn below in view space
                    // and intentionally remains outside this clip.
                    cg.saveGState()
                    cg.addRect(layout.imageRect)
                    cg.clip()
                    AnnotationRenderer.draw(
                        in: cg,
                        base: document.baseImage,
                        blurSources: document.blurSources,
                        annotations: document.annotations,
                        skipping: skipID
                    )
                    cg.restoreGState()
                }
                cg.restoreGState()
            }

            // While drawing a callout, preview only the plain marker outline
            // (in the annotation color and shape) — no magnified content yet.
            if let id = markerPreviewID,
               let a = document.annotations.first(where: { $0.id == id }) {
                drawMarkerPreview(a, context: context, fitScale: fitScale, offset: offset)
            }

            // Selection chrome in view space (crisp at any zoom).
            if let selected = document.selectedAnnotation, selected.id != editingTextID {
                // Chrome follows the space of what it decorates: a blur's
                // handles ride the image, an arrow's ride the canvas.
                drawSelection(for: selected, context: context,
                              fitScale: selected.livesInImageSpace ? fitScale : canvasScale,
                              offset: selected.livesInImageSpace ? offset : canvasOffset)
            }

            // The picture's own selection frame, in canvas space.
            if imageSelected, presentation != nil {
                drawImageSelection(layout.imageRect, context: context,
                                   fitScale: canvasScale, offset: canvasOffset,
                                   showsHandles: true)
            }

            // While dragging an arrow/line endpoint — either resizing an
            // existing one or drawing a new one — show the shape's magnetic
            // anchors and highlight the one the drop will snap to (none
            // highlighted = releasing here leaves the endpoint free).
            if let (id, tip) = bindingDragEndpoint {
                // Arrows and the shapes they bind to are canvas-space.
                drawBindingCandidates(near: tip, excluding: id, context: context,
                                      fitScale: canvasScale, offset: canvasOffset)
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

    /// The picture's frame and corner grips — the same vocabulary an annotation
    /// uses, so it reads as the object it now is.
    private func drawImageSelection(_ rect: CGRect, context: GraphicsContext,
                                    fitScale: CGFloat, offset: CGPoint,
                                    showsHandles: Bool) {
        func view(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + p.x * fitScale, y: offset.y + p.y * fitScale)
        }
        let frame = CGRect(origin: view(rect.origin),
                           size: CGSize(width: rect.width * fitScale,
                                        height: rect.height * fitScale))
        context.stroke(Path(frame), with: .color(.accentColor), lineWidth: 1.5)
        guard showsHandles else { return }
        for corner in ImageCorner.allCases {
            let c = view(corner.point(in: rect))
            let box = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(.white))
            context.stroke(Path(roundedRect: box, cornerRadius: 2),
                           with: .color(.accentColor), lineWidth: 1.5)
        }
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

    /// Plain outline of the source marker while a callout is being drawn — the
    /// loupe's shape in its color, no magnified content. The magnifier appears
    /// only when the drag ends.
    private func drawMarkerPreview(_ a: Annotation, context: GraphicsContext,
                                   fitScale: CGFloat, offset: CGPoint) {
        let r = a.rect
        let viewRect = CGRect(x: r.minX * fitScale + offset.x,
                              y: r.minY * fitScale + offset.y,
                              width: r.width * fitScale, height: r.height * fitScale)
        var path = Path()
        if a.loupeShape == .roundedRect {
            let radius = min(viewRect.width, viewRect.height) * 0.2
            path.addRoundedRect(in: viewRect,
                                cornerSize: CGSize(width: radius, height: radius))
        } else {
            path.addEllipse(in: viewRect)
        }
        context.stroke(path, with: .color(Color(nsColor: a.color.nsColor)),
                       lineWidth: max(1, a.lineWidth * fitScale))
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
            // A callout loupe's source marker is part of the selection too.
            var outlineRects = [a.rect]
            if let sourceRect = a.loupeSourceRect { outlineRects.append(sourceRect) }
            var path = Path()
            for r in outlineRects {
                let viewRect = CGRect(origin: toView(r.origin),
                                      size: CGSize(width: r.width * fitScale,
                                                   height: r.height * fitScale))
                    .insetBy(dx: -3, dy: -3)
                if a.kind == .step || (a.kind == .loupe && a.loupeShape != .roundedRect) {
                    path.addEllipse(in: viewRect)
                } else {
                    path.addRect(viewRect)
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.stroke(path, with: .color(.black.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3], dashPhase: 3.5))
        }

        // An elbow arrow shows a slider on each leg: a short bar lying across
        // the leg, dragged to slide that leg parallel to itself.
        if a.isElbowed {
            let route = a.elbowRoute(in: document.annotations)
            for (index, midpoint) in Annotation.routeSegmentMidpoints(route).enumerated() {
                let leg = (route[index], route[index + 1])
                let isVertical = abs(leg.0.x - leg.1.x) < 0.01
                let c = toView(midpoint)
                let long = Self.routeSliderLength / 2
                let thin = Self.routeSliderThickness / 2
                let bar = isVertical
                    ? CGRect(x: c.x - thin, y: c.y - long,
                             width: Self.routeSliderThickness, height: Self.routeSliderLength)
                    : CGRect(x: c.x - long, y: c.y - thin,
                             width: Self.routeSliderLength, height: Self.routeSliderThickness)
                let shape = Path(roundedRect: bar, cornerRadius: thin)
                context.fill(shape, with: .color(.blue))
                context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
        }

        var selectionPoints = a.handles(in: document.annotations).map(\.1)
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

    /// Length and thickness of an elbow leg's slider bar, in view points.
    private static let routeSliderLength: CGFloat = 18
    private static let routeSliderThickness: CGFloat = 7

    /// The editor's layout grid, in **image pixels** — deliberately not view
    /// points, so the lattice is the same at every zoom and objects snapped at
    /// different magnifications still line up with each other. A multiple of
    /// the 4 pt layout unit.
    static let gridStep: CGFloat = 24     // 6 × 4 pt

    /// The grid step to quantize with right now; 1 disables quantization.
    private var activeGrid: CGFloat {
        style.snapsToGrid ? Self.gridStep : 1
    }

    /// A gesture point quantized to the layout grid, when snapping is on.
    /// Freehand drawing and erasing never snap — a quantized brush is useless —
    /// so those paths call this nowhere.
    private func snapped(_ p: CGPoint) -> CGPoint {
        guard style.snapsToGrid else { return p }
        return Annotation.snappedToGrid(p, origin: .zero, grid: Self.gridStep)
    }

    /// Index of the elbow-route leg whose slider is within `tolerance` of `p`,
    /// or nil. Endpoint legs included — dragging one buds a new corner.
    private func routeSegmentSlider(of a: Annotation, at p: CGPoint,
                                    tolerance: CGFloat) -> Int? {
        guard a.isElbowed else { return nil }
        let route = a.elbowRoute(in: document.annotations)
        guard route.count >= 2 else { return nil }
        return Annotation.routeSegmentMidpoints(route).firstIndex {
            hypot($0.x - p.x, $0.y - p.y) <= tolerance
        }
    }

    /// The moving endpoint whose binding candidates should be shown, if a drag
    /// is placing an arrow/line endpoint (resizing an existing one or drawing a
    /// new one). nil for every other drag.
    private var bindingDragEndpoint: (id: UUID, tip: CGPoint)? {
        func endpoint(_ id: UUID, _ handle: Annotation.Handle?) -> (UUID, CGPoint)? {
            guard let a = document.annotations.first(where: { $0.id == id }),
                  a.kind == .arrow || a.kind == .line else { return nil }
            return (id, handle == .start ? a.start : a.end)
        }
        switch dragMode {
        case let .resizing(id, handle) where handle == .start || handle == .end:
            return endpoint(id, handle)
        case let .creating(id):
            return endpoint(id, .end)
        default:
            return nil
        }
    }

    /// The magnetic anchors of the shape under a dragged endpoint. The dot the
    /// drop would snap to is filled; visible ones are hollow. Nothing draws when
    /// the endpoint isn't near a bindable shape.
    private func drawBindingCandidates(near tip: CGPoint, excluding id: UUID,
                                       context: GraphicsContext,
                                       fitScale: CGFloat, offset: CGPoint) {
        let tolerancePx = hitTolerancePt / fitScale
        let magnetPx = bindMagnetPt / fitScale
        guard let shape = document.annotations.last(where: {
            $0.id != id && $0.isBindableTarget
                && ($0.hitTest(tip, tolerance: tolerancePx, in: document.annotations)
                    || $0.nearestBindingAnchor(to: tip, magnet: magnetPx) != nil)
        }) else { return }
        let snapped = shape.nearestBindingAnchor(to: tip, magnet: magnetPx)

        func draw(_ point: CGPoint, active: Bool) {
            let c = CGPoint(x: point.x * fitScale + offset.x,
                            y: point.y * fitScale + offset.y)
            let radius: CGFloat = active ? 6 : 4.5
            let dot = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                             width: radius * 2, height: radius * 2))
            if active {
                context.fill(dot, with: .color(.blue))
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            } else {
                context.fill(dot, with: .color(.white))
                context.stroke(dot, with: .color(.blue.opacity(0.7)), lineWidth: 1.5)
            }
        }

        // Visible anchors (edge midpoints) always show; the vertex anchors stay
        // hidden unless one is the active snap target.
        for candidate in shape.referenceAnchors() where candidate.isVisible {
            draw(candidate.point, active: candidate == snapped)
        }
        if let snapped, !snapped.isVisible {
            draw(snapped.point, active: true)
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
                             annotationBounds: CGRect,
                             canvasScale: CGFloat, canvasOffset: CGPoint,
                             canvasBounds: CGRect, canvasSize: CGSize,
                             viewport: CGSize, baseDrawSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                // Continuous-hover events pause while the mouse button is
                // down, so keep the brush/eraser indicator attached to the
                // pointer from the drag stream itself.
                if tool == .drawing || tool == .eraser {
                    drawingCursorLocation = value.location
                }
                let sp = SpacedPoint(
                    image: pixelPoint(value.location, fitScale: fitScale,
                                      offset: offset, bounds: annotationBounds),
                    canvas: pixelPoint(value.location, fitScale: canvasScale,
                                       offset: canvasOffset, bounds: canvasBounds),
                    imageScale: fitScale, canvasScale: canvasScale
                )
                // Most gestures act on one known annotation, so the point is
                // resolved in *its* space; the ones that create act in the
                // space their kind will live in.
                let point = { (id: UUID) -> CGPoint in
                    document.annotations.first { $0.id == id }
                        .map(sp.point(for:)) ?? sp.canvas
                }
                let scaleOf = { (id: UUID) -> CGFloat in
                    document.annotations.first { $0.id == id }
                        .map(sp.scale(for:)) ?? sp.canvasScale
                }
                let p = sp.canvas

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
                        dragMode = beginCropDrag(at: sp.image, fitScale: fitScale)
                    } else if isSpaceHeld {
                        dragMode = .panning(last: value.location)
                    } else if tool != .scan,
                              beginEditingIfDoubleClick(at: sp) {
                        // A double-click on text/step opens its inline editor
                        // instead of starting a move — detected at mouse-down
                        // so it works even on an already-selected annotation.
                        dragMode = .ignore
                    } else {
                        dragMode = beginDrag(at: sp)
                    }
                }

                switch dragMode {
                case .duplicatePending(let sourceID, let start):
                    let viewDistance = hypot(value.translation.width, value.translation.height)
                    guard viewDistance >= 3 else { break }
                    document.beginChange()
                    let here = point(sourceID)
                    let offset = CGPoint(x: here.x - start.x, y: here.y - start.y)
                    guard let duplicateID = document.appendDuplicate(
                        of: sourceID, offset: offset
                    ) else {
                        document.discardChange()
                        dragMode = .ignore
                        break
                    }
                    dragMode = .moving(duplicateID, last: snapped(point(duplicateID)))

                case .drawing(let id):
                    // Resolved before `update`: that call takes exclusive access
                    // to the annotation array, and reading it from inside the
                    // mutation is an overlapping-access trap.
                    let sampleDistance = max(0.5, 1 / scaleOf(id))
                    let here = point(id)
                    update(id) {
                        $0.appendFreehandPoint(here, minimumDistance: sampleDistance)
                    }

                case .erasing(let last):
                    document.eraseFreehand(
                        from: last, to: sp.canvas, diameter: style.eraserDiameter
                    )
                    dragMode = .erasing(last: sp.canvas)

                case .undecided(let startPixel):
                    let viewDistance = hypot(value.translation.width, value.translation.height)
                    guard viewDistance >= 3 else { break }
                    // The select tool has nothing to create on empty space, so
                    // an empty-space drag pans the (zoomed) image instead.
                    guard let kind = shapeKind(for: tool) else {
                        if tool == .select { dragMode = .panning(last: value.location) }
                        break
                    }
                    // A blur or loupe is born in image pixels; everything else
                    // on the canvas.
                    let p = sp.point(imageSpace: Annotation.kindLivesInImageSpace(kind))
                    document.beginChange()
                    var annotation = Annotation(kind: kind, start: snapped(startPixel),
                                                end: snapped(p),
                                                color: style.color, lineWidth: style.lineWidth)
                    annotation.blurStyle = style.blurStyle
                    annotation.blurLevel = style.blurLevel
                    annotation.arrowStyle = style.arrowStyle
                    annotation.arrowRoute = style.arrowRoute
                    annotation.arrowHeadPlacement = style.arrowHeadPlacement
                    annotation.arrowHeadScale = style.arrowHeadScale
                    annotation.lineStyle = style.lineStyle
                    annotation.fillOpacity = style.fillOpacity
                    annotation.polygonSides = style.polygonSides
                    annotation.starPoints = style.starPoints
                    annotation.bubbleTail = style.bubbleTail
                    annotation.loupeScale = style.loupeScale
                    annotation.loupeShape = style.loupeShape
                    annotation.loupeRevealsOriginal = style.loupeRevealsOriginal
                    annotation.end = constrainedEndpoint(snapped(p), from: annotation.start,
                                                         kind: kind)
                    annotation.updateCreationOrientation()
                    document.annotations.append(annotation)
                    document.selectedID = annotation.id
                    dragMode = .creating(annotation.id)

                case .creating(let id):
                    let target = snapped(point(id))
                    update(id) {
                        $0.end = constrainedEndpoint(target, from: $0.start, kind: $0.kind)
                        $0.updateCreationOrientation()
                    }

                case .moving(let id, let last):
                    let p = point(id)
                    // Snapping the pointer (not the raw delta) keeps a move in
                    // whole grid steps, so an object created on the lattice
                    // stays on it.
                    let target = snapped(p)
                    let delta = CGPoint(x: target.x - last.x, y: target.y - last.y)
                    guard delta != .zero else { break }
                    update(id) { $0.move(by: delta) }
                    dragMode = .moving(id, last: target)

                case .movingLoupePart(let id, let part, let last):
                    let target = snapped(point(id))
                    let delta = CGPoint(x: target.x - last.x, y: target.y - last.y)
                    guard delta != .zero else { break }
                    update(id) { $0.moveLoupePart(part, by: delta) }
                    dragMode = .movingLoupePart(id, part, last: target)

                case .resizing(let id, let handle):
                    // Bend: the pointer is where the curve itself should pass,
                    // and `bentControl` turns that into the control. A wide
                    // alignment band (≈9 pt) snaps a near-straight bend flat,
                    // and Shift forces it straight. Snap against the resolved
                    // chord the user sees, then store the control in the raw
                    // chord frame so a bound arrow's bend follows its endpoints
                    // (an identity map when unbound).
                    let p = point(id)
                    if handle == .control,
                       let arrow = document.annotations.first(where: { $0.id == id }),
                       arrow.kind == .arrow {
                        let rs = arrow.resolvedStart(in: document.annotations)
                        let re = arrow.resolvedEnd(in: document.annotations)
                        let snapDistance = 9 / scaleOf(id)
                        update(id) { annotation in
                            if let bent = Annotation.bentControl(
                                forDrag: p, start: rs, end: re,
                                snapDistance: snapDistance, forceStraight: isShiftHeld) {
                                annotation.curveControl = Annotation.mapControl(
                                    bent, fromStart: rs, fromEnd: re,
                                    toStart: annotation.start, toEnd: annotation.end)
                            } else {
                                annotation.curveControl = nil
                            }
                        }
                        break
                    }
                    // Every resize rides the shared lattice, so corners and
                    // endpoints land where other snapped objects already are.
                    let target = snapped(p)
                    // A corner pushed through the opposite edge mirrors the
                    // shape; the drag continues with the mirrored handle.
                    var continuedHandle = handle
                    update(id) { annotation in
                        // Dragging a bound endpoint detaches it: it follows the
                        // cursor from its raw point live, and re-binds on release
                        // only if dropped over a shape (in bindEndpoint).
                        if (handle == .start || handle == .end),
                           annotation.kind == .arrow || annotation.kind == .line {
                            if handle == .start { annotation.startBinding = nil }
                            else { annotation.endBinding = nil }
                        }
                        if isShiftHeld,
                           annotation.kind == .line || annotation.kind == .arrow {
                            switch handle {
                            case .start:
                                annotation.start = Annotation.snappedArrowEnd(from: annotation.end, to: target)
                            case .end:
                                annotation.end = Annotation.snappedArrowEnd(from: annotation.start, to: target)
                            default:
                                break
                            }
                        } else {
                            continuedHandle = annotation.apply(
                                handle: handle, to: target, aspectLocked: isShiftHeld)
                        }
                    }
                    if continuedHandle != handle {
                        dragMode = .resizing(id, continuedHandle)
                    }

                case .routeSegment(let id, let index, let baseline):
                    // Always slide from the gesture's fixed baseline, so the
                    // result is a pure function of the pointer; legs that
                    // collapse to zero length drop out.
                    let waypoints = Annotation.movingRouteSegment(
                        baseline, index: index, to: point(id), grid: activeGrid)
                    update(id) { $0.elbowWaypoints = waypoints }

                case .cropCreating(let start) where style.snapsToGrid:
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved >= 3 {
                        let a = snapped(start), b = snapped(sp.image)
                        let raw = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                         width: abs(b.x - a.x), height: abs(b.y - a.y))
                        cropRect = raw.intersection(CGRect(origin: .zero, size: pixel))
                    }

                case .cropMoving(let last) where style.snapsToGrid:
                    let target = snapped(sp.image)
                    if let rect = cropRect, target != last {
                        cropRect = movedCrop(rect, by: CGPoint(x: target.x - last.x,
                                                               y: target.y - last.y))
                        dragMode = .cropMoving(last: target)
                    }

                case .cropResizing(let handle) where style.snapsToGrid:
                    if let rect = cropRect {
                        cropRect = resizedCrop(rect, handle: handle, to: snapped(sp.image))
                    }

                case .cropCreating(let start):
                    // Ignore a stray click (or the first sub-pixel of a drag) so
                    // it doesn't collapse the existing frame; only a real drag
                    // starts a fresh rect.
                    let moved = hypot(value.translation.width, value.translation.height)
                    if moved >= 3 {
                        let ip = sp.image
                        let raw = CGRect(x: min(start.x, ip.x), y: min(start.y, ip.y),
                                         width: abs(ip.x - start.x), height: abs(ip.y - start.y))
                        cropRect = raw.intersection(CGRect(origin: .zero, size: pixel))
                    }

                case .cropMoving(let last):
                    if let rect = cropRect {
                        cropRect = movedCrop(rect, by: CGPoint(x: sp.image.x - last.x,
                                                               y: sp.image.y - last.y))
                    }
                    dragMode = .cropMoving(last: sp.image)

                case .cropResizing(let handle):
                    if let rect = cropRect {
                        cropRect = resizedCrop(rect, handle: handle, to: sp.image)
                    }

                case .movingImage(let last):
                    let target = sp.canvas
                    let delta = CGPoint(x: target.x - last.x, y: target.y - last.y)
                    guard delta != .zero else { break }
                    document.moveImage(by: delta, canvasSize: canvasSize)
                    dragMode = .movingImage(last: target)

                case .resizingImage(let corner):
                    // The page keeps its size through a resize, so its mapping
                    // to the view is stable and the live point is exact.
                    document.resizeImage(
                        corner: corner, to: sp.canvas,
                        canvasSize: canvasSize,
                        imagePixelSize: pixel
                    )

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
                let sp = SpacedPoint(
                    image: pixelPoint(value.location, fitScale: fitScale,
                                      offset: offset, bounds: annotationBounds),
                    canvas: pixelPoint(value.location, fitScale: canvasScale,
                                       offset: canvasOffset, bounds: canvasBounds),
                    imageScale: fitScale, canvasScale: canvasScale
                )
                let point = { (id: UUID) -> CGPoint in
                    document.annotations.first { $0.id == id }
                        .map(sp.point(for:)) ?? sp.canvas
                }
                let scaleOf = { (id: UUID) -> CGFloat in
                    document.annotations.first { $0.id == id }
                        .map(sp.scale(for:)) ?? sp.canvasScale
                }

                switch dragMode {
                case .undecided:
                    handleClick(at: sp)
                case .creating(let id):
                    if let a = document.annotations.first(where: { $0.id == id }), a.isDegenerate {
                        document.annotations.removeAll { $0.id == id }
                        document.selectedID = nil
                        document.discardChange()
                    } else {
                        // A callout loupe: the drawn rect is the source marker
                        // (what to magnify). The magnifier — source × scale —
                        // pops out beside it, on whichever side has more room,
                        // never overlapping, so both bodies and the connector
                        // read immediately.
                        update(id) {
                            guard $0.kind == .loupe, style.loupeCallout else { return }
                            let source = $0.rect
                            $0.loupeSource = CGPoint(x: source.midX, y: source.midY)
                            $0.loupeSourceSize = source.size
                            let display = Self.calloutDisplayPlacement(
                                source: source, scale: $0.loupeScale,
                                lineWidth: $0.lineWidth, imageSize: pixel)
                            $0.start = CGPoint(x: display.minX, y: display.minY)
                            $0.end = CGPoint(x: display.maxX, y: display.maxY)
                        }
                        // A freshly drawn elbow arrow squares up onto its axis
                        // when it was drawn nearly straight.
                        let elbowTolerance = 12 / scaleOf(id)
                        update(id) { $0.alignForElbow(tolerance: elbowTolerance) }
                        // A freshly drawn arrow/line binds whichever endpoints
                        // landed on (or near) a shape, so drawing one straight
                        // onto a shape connects it — same undo step.
                        if let a = document.annotations.first(where: { $0.id == id }),
                           a.kind == .arrow || a.kind == .line {
                            let tolerancePx = hitTolerancePt / scaleOf(id)
                            let magnetPx = bindMagnetPt / scaleOf(id)
                            document.bindEndpoint(.start, of: id, releasedAt: a.start,
                                                  tolerance: tolerancePx, magnet: magnetPx)
                            document.bindEndpoint(.end, of: id, releasedAt: a.end,
                                                  tolerance: tolerancePx, magnet: magnetPx)
                            document.refreshBindingFallbacks()
                        }
                        document.commitChange()
                    }
                case .drawing(let id):
                    let here = point(id)
                    update(id) { $0.appendFreehandPoint(here, minimumDistance: 0.01) }
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
                case .routeSegment:
                    document.commitChange()
                case .moving, .movingLoupePart:
                    // A moved/resized shape can carry bound arrows with it;
                    // refresh their fallbacks so a later delete freezes them
                    // at the right spot.
                    document.refreshBindingFallbacks()
                    document.commitChange()
                case .resizing(let id, let handle):
                    // Dropping an arrow/line endpoint over (or near) a shape
                    // binds it; empty space clears any prior binding. Part of
                    // the same undo step as the drag.
                    document.bindEndpoint(handle, of: id, releasedAt: point(id),
                                          tolerance: hitTolerancePt / scaleOf(id),
                                          magnet: bindMagnetPt / scaleOf(id))
                    document.refreshBindingFallbacks()
                    document.commitChange()
                case .resizingImage:
                    document.commitChange()
                case .duplicatePending, .cropCreating, .cropMoving, .cropResizing,
                     .movingImage, .panning, .ignore, nil:
                    break
                }
            }
    }

    /// Decides what a fresh mouse-down does, before we know if it's a click
    /// or a drag.
    private func beginDrag(at sp: SpacedPoint) -> DragMode {
        // Tolerances are in pixels of whichever space the object being tested
        // is measured in, so a grab feels the same distance on screen either way.
        let selectedScale = document.selectedAnnotation.map(sp.scale(for:)) ?? sp.canvasScale
        let grabPx = handleGrabPt / selectedScale
        let tolerancePx = hitTolerancePt / selectedScale
        let p = document.selectedAnnotation.map(sp.point(for:)) ?? sp.canvas

        // Resize handles of the current selection win over everything. Bound
        // arrow endpoints are grabbed at their resolved (drawn) positions.
        if let selected = document.selectedAnnotation,
           let handle = selected.handle(at: p, tolerance: grabPx, in: document.annotations) {
            document.beginChange()
            return .resizing(selected.id, handle)
        }

        // An elbow arrow's per-leg sliders sit below the endpoint handles. The
        // route is captured here and drives the whole drag.
        if let selected = document.selectedAnnotation,
           let index = routeSegmentSlider(of: selected, at: p, tolerance: grabPx) {
            document.beginChange()
            return .routeSegment(selected.id, index: index,
                                 baseline: selected.elbowRoute(in: document.annotations))
        }

        // Option-drag duplicates any annotation body under the cursor, even
        // while a regular drawing tool is active. Recognition and crop keep
        // exclusive ownership of their gestures. Creation is deferred until
        // movement crosses the standard 3 pt drag threshold, so Option-click only selects.
        if tool != .scan, tool != .crop, isOptionHeld,
           let hit = document.annotation(imagePoint: sp.image, canvasPoint: sp.canvas,
                                         imageTolerance: hitTolerancePt / sp.imageScale,
                                         canvasTolerance: hitTolerancePt / sp.canvasScale) {
            let p = sp.point(for: hit)
            document.selectedID = hit.id
            return .duplicatePending(sourceID: hit.id, start: p)
        }

        switch tool {
        case .scan:
            // The selection overlay covers the image while this tool is
            // active, so a drag never reaches the canvas.
            return .ignore
        case .crop:
            // Crop drags are routed through beginCropDrag before reaching here.
            return .ignore
        case .select:
            if let hit = document.annotation(at: p, tolerance: tolerancePx) {
                document.selectedID = hit.id
                document.beginChange()
                // A callout loupe's bodies drag independently; whole-
                // annotation moves stay on the keyboard-nudge path.
                if let part = hit.loupePart(at: p, tolerance: tolerancePx) {
                    return .movingLoupePart(hit.id, part, last: snapped(p))
                }
                return .moving(hit.id, last: snapped(p))
            }
            // The picture is the last thing under the pointer: annotations sit
            // on top of it, empty background below.
            if let mode = beginImageDrag(at: sp) { return mode }
            // Empty space: a click deselects (in handleClick), a drag pans.
            return .undecided(pixelPoint: p)
        case .text:
            // Drag the selected text's body to move it; otherwise a click
            // places or edits (handled in onEnded).
            if let selected = document.selectedAnnotation,
               selected.kind == .text, selected.hitTest(p, tolerance: tolerancePx) {
                document.beginChange()
                return .moving(selected.id, last: snapped(p))
            }
            return .undecided(pixelPoint: p)
        case .drawing:
            document.selectedID = nil
            document.beginChange()
            let width = style.width(for: style.drawingMode)
            var annotation = Annotation(kind: .freehand, start: p, end: p,
                                        color: style.color, lineWidth: width)
            annotation.freehandStyle = style.drawingMode.freehandStyle
            annotation.markerTip = style.markerTip
            annotation.appendFreehandPoint(p, minimumDistance: 0)
            document.annotations.append(annotation)
            document.selectedID = annotation.id
            return .drawing(annotation.id)
        case .eraser:
            document.selectedID = nil
            document.beginChange()
            document.eraseFreehand(from: p, to: p, diameter: style.eraserDiameter)
            return .erasing(last: p)
        case .line, .arrow, .rect, .oval, .roundedRect, .polygon,
             .star, .bubble, .blur, .step, .loupe:
            // Dragging the selected annotation's body moves it even with a
            // shape tool active; empty space starts a new shape on drag.
            if let selected = document.selectedAnnotation,
               selected.hitTest(p, tolerance: tolerancePx, in: document.annotations) {
                document.beginChange()
                if let part = selected.loupePart(at: p, tolerance: tolerancePx) {
                    return .movingLoupePart(selected.id, part, last: snapped(p))
                }
                return .moving(selected.id, last: snapped(p))
            }
            return .undecided(pixelPoint: p)
        }
    }

    /// Grabbing the picture: a corner of the selection frame resizes it, its
    /// body moves it. Only with a presentation — without one the picture *is*
    /// the canvas and there is nowhere to move it to.
    private func beginImageDrag(at sp: SpacedPoint) -> DragMode? {
        guard document.presentation != nil else { return nil }
        let layout = PresentationLayout.resolve(imagePixelSize: document.pixelSize,
                                                document.presentation)
        let rect = layout.imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let grab = handleGrabPt / sp.canvasScale

        if imageSelected {
            for corner in ImageCorner.allCases {
                let c = corner.point(in: rect)
                if hypot(sp.canvas.x - c.x, sp.canvas.y - c.y) <= grab {
                    document.beginChange()
                    return .resizingImage(corner)
                }
            }
        }
        guard rect.insetBy(dx: -grab / 2, dy: -grab / 2).contains(sp.canvas) else { return nil }
        document.selectedID = nil
        imageSelected = true
        return .movingImage(last: sp.canvas)
    }

    /// A single click that never became a drag: select what's under it, or
    /// place a new text/step marker on empty space. (Double-click editing is
    /// handled up front at mouse-down.)
    private func handleClick(at sp: SpacedPoint) {
        let hit = document.annotation(imagePoint: sp.image, canvasPoint: sp.canvas,
                                      imageTolerance: hitTolerancePt / sp.imageScale,
                                      canvasTolerance: hitTolerancePt / sp.canvasScale)
        // Text and step are canvas-space, so a new one is placed there.
        let p = sp.canvas

        if hit != nil { imageSelected = false }

        switch tool {
        case .text:
            if let hit, hit.kind == .text { document.selectedID = hit.id }
            else { placeText(at: snapped(p)) }        // new text opens straight into editing
        case .step:
            if let hit, hit.kind == .step { document.selectedID = hit.id }
            else { placeStep(at: snapped(p)) }
        default:
            document.selectedID = hit?.id
        }
    }

    /// Records the mouse-down and, if it's the second click of a double-click
    /// on a text or step annotation, opens that annotation's inline editor.
    /// Returns true when it started editing (so the caller skips the drag).
    private func beginEditingIfDoubleClick(at sp: SpacedPoint) -> Bool {
        let hit = document.annotation(imagePoint: sp.image, canvasPoint: sp.canvas,
                                      imageTolerance: hitTolerancePt / sp.imageScale,
                                      canvasTolerance: hitTolerancePt / sp.canvasScale)
        // The double-click test compares against the previous click, so it has
        // to use one consistent space; text and step are canvas-space.
        let p = sp.canvas
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

    /// Where a freshly drawn callout loupe drops its magnifier: the user draws
    /// the source marker, and the magnifier — `source × scale` — is placed
    /// diagonally beside it on the side with more room, clamped so it stays
    /// on-image. Pure and static so it's unit-testable and free of view state.
    static func calloutDisplayPlacement(source: CGRect, scale: CGFloat,
                                        lineWidth: CGFloat,
                                        imageSize: CGSize) -> CGRect {
        let k = max(1, scale)
        let dw = source.width * k, dh = source.height * k
        let gap = max(source.width, source.height) * 0.5 + lineWidth
        let cx = source.minX >= (imageSize.width - source.maxX)
            ? source.minX - gap - dw / 2
            : source.maxX + gap + dw / 2
        let cy = source.minY >= (imageSize.height - source.maxY)
            ? source.minY - gap - dh / 2
            : source.maxY + gap + dh / 2
        let clampedX = min(max(dw / 2, cx), imageSize.width - dw / 2)
        let clampedY = min(max(dh / 2, cy), imageSize.height - dh / 2)
        return CGRect(x: clampedX - dw / 2, y: clampedY - dh / 2,
                      width: dw, height: dh)
    }

    private func shapeKind(for tool: EditorTool) -> AnnotationKind? {
        switch tool {
        case .line:  return .line
        case .arrow: return .arrow
        case .rect:  return .rect
        case .oval:  return .oval
        case .roundedRect: return .roundedRect
        case .polygon:  return .polygon
        case .star:     return .star
        case .bubble:   return .bubble
        case .blur:  return .blur
        case .loupe: return .loupe
        case .select, .text, .drawing, .eraser, .step, .scan, .crop: return nil
        }
    }

    private func update(_ id: UUID, _ mutate: (inout Annotation) -> Void) {
        guard let idx = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&document.annotations[idx])
    }

    /// Where a gesture may reach, in image-pixel space.
    ///
    /// The canvas bounds alone would make an annotation that has left the frame
    /// unreachable: every point clamps to the edge, so it could not be grabbed,
    /// moved back or deleted. With a presentation the reach is widened well
    /// past the canvas for exactly that. Without one it stays the image, which
    /// is what the editor has always allowed.
    private func reachableAnnotationBounds(pixel: CGSize,
                                           layout: PresentationLayout.Resolved,
                                           hasPresentation: Bool) -> CGRect {
        let bounds = PresentationLayout.annotationBounds(imagePixelSize: pixel, layout)
        guard hasPresentation else { return bounds }
        return bounds.insetBy(dx: -bounds.width, dy: -bounds.height)
    }

    /// The same reach, expressed in canvas pixels — the space commentary is
    /// measured in.
    private func reachableCanvasBounds(layout: PresentationLayout.Resolved,
                                       hasPresentation: Bool) -> CGRect {
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        guard hasPresentation else { return canvas }
        return canvas.insetBy(dx: -canvas.width, dy: -canvas.height)
    }

    /// A view point in the image's pixel space, clamped to where annotations
    /// may go. That is the whole canvas, not the picture: with a presentation
    /// the background around the image is a legitimate place for a caption or
    /// for an arrow pointing at the mockup. Without one the bounds collapse to
    /// the image and the behaviour is unchanged.
    private func pixelPoint(_ viewPoint: CGPoint, fitScale: CGFloat,
                            offset: CGPoint, bounds: CGRect) -> CGPoint {
        CGPoint(
            x: max(bounds.minX, min(bounds.maxX, (viewPoint.x - offset.x) / fitScale)),
            y: max(bounds.minY, min(bounds.maxY, (viewPoint.y - offset.y) / fitScale))
        )
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
        case .rect, .oval, .roundedRect, .polygon, .star, .bubble,
             .loupe:
            // Shift makes a loupe's oval a circle (its rounded rect a square,
            // a polygon or star regular).
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
                let newZoom = EditorViewportGeometry.clampedZoom(startZoom * magnification)
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
                } else if self.imageSelected {
                    // The picture is a selection like any other, frame and all,
                    // so Escape has to be able to drop it too.
                    self.imageSelected = false
                }
                return nil
            }

            let nudges = Self.nudgeTarget(selectedID: self.document.selectedID,
                                          imageSelected: self.imageSelected,
                                          isDecorated: self.document.presentation != nil)
            guard event.type == .keyDown, nudges != .nothing else { return event }

            // Delete / Backspace removes the selection. SwiftUI's
            // onDeleteCommand never fires because the Canvas isn't first
            // responder, so the monitor owns this. The picture cannot be
            // deleted — it is the document.
            if event.keyCode == 51 || event.keyCode == 117,
               nudges == .annotation,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                self.document.deleteSelected()
                return nil
            }

            // Arrow-key nudge, of whatever is selected — the picture included.
            guard let delta = Self.nudgeDelta(for: event) else { return event }
            switch nudges {
            case .image:
                let canvas = PresentationLayout.resolve(
                    imagePixelSize: self.document.pixelSize,
                    self.document.presentation
                ).canvasSize
                self.document.moveImage(by: delta, canvasSize: canvas)
            case .annotation:
                self.document.nudgeSelected(by: delta)
            case .nothing:
                break
            }
            return nil
        }
    }

    /// What the arrow keys (and Delete) act on.
    enum NudgeTarget: Equatable { case annotation, image, nothing }

    /// The picture is not an annotation and therefore has no `selectedID`.
    /// Asking for one before letting an arrow key through is what left a
    /// selected picture sitting still: the keys never reached the nudge.
    static func nudgeTarget(selectedID: UUID?,
                            imageSelected: Bool,
                            isDecorated: Bool) -> NudgeTarget {
        // A selected annotation wins: selecting one drops the picture's
        // selection anyway, so the two are never both live.
        if selectedID != nil { return .annotation }
        // Nothing to move a picture within until there is a canvas around it.
        if imageSelected, isDecorated { return .image }
        return .nothing
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
        annotation.fontPreset = style.fontPreset
        annotation.bold = style.bold
        annotation.italic = style.italic
        annotation.underline = style.underline
        annotation.strikethrough = style.strikethrough
        annotation.textShadow = style.textShadow
        annotation.textBackground = style.textBackground
        annotation.textAlignment = style.textAlignment
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
        annotation.stepLabelSize = style.stepLabelSize
        annotation.fontPreset = style.fontPreset
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

        let baseFont = AnnotationRenderer.stepFont(for: annotation)
        let scaledFont = NSFont(descriptor: baseFont.fontDescriptor,
                                size: baseFont.pointSize * fitScale) ?? baseFont
        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(Font(scaledFont))
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
/// labels round-trip to the exported image. Paragraph alignment is applied
/// by the renderer on commit, not while editing — the editor's container is
/// unbounded (it must never soft-wrap), so non-left alignment would place
/// glyphs at the container's far edge instead of within the visible box.
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
