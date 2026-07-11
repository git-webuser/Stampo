import AppKit
import Observation

// MARK: - Annotation primitives

enum AnnotationKind: Equatable {
    case arrow
    case rect
    case oval
    case text
    case blur
    case step
}

enum BlurStyle: String, Equatable, CaseIterable {
    case gaussian
    case pixelate
}

/// Color stored as sRGB components so Annotation stays Equatable/value-only.
struct AnnotationColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1.0

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    func multipliedAlpha(_ multiplier: CGFloat) -> AnnotationColor {
        AnnotationColor(red: red, green: green, blue: blue,
                        alpha: alpha * Double(multiplier))
    }

    // Toolbar presets (red is the default tool color).
    static let red    = AnnotationColor(red: 0.93, green: 0.22, blue: 0.21)
    static let orange = AnnotationColor(red: 1.00, green: 0.58, blue: 0.09)
    static let yellow = AnnotationColor(red: 1.00, green: 0.84, blue: 0.16)
    static let green  = AnnotationColor(red: 0.22, green: 0.78, blue: 0.35)
    static let blue   = AnnotationColor(red: 0.17, green: 0.48, blue: 1.00)
    static let black  = AnnotationColor(red: 0.05, green: 0.05, blue: 0.05)
    static let white  = AnnotationColor(red: 1.00, green: 1.00, blue: 1.00)

    static let presets: [AnnotationColor] = [.red, .orange, .yellow, .green, .blue, .black, .white]
}

/// A single annotation. All geometry is in **image pixel coordinates**
/// with a top-left origin (y grows downward) — the view converts to and
/// from screen points through one fitScale factor, and export at native
/// pixel size needs no conversion at all.
struct Annotation: Identifiable, Equatable {
    let id: UUID
    var kind: AnnotationKind
    /// Anchor point. For .arrow this is the tail; for shapes a drag corner;
    /// for .text the top-left of the text box; for .step its center.
    var start: CGPoint
    /// Second point. For .arrow the tip; for shapes the opposite corner;
    /// for .text the bottom-right of the measured text bounds. Step keeps it
    /// equal to `start`, since its bounds come from `stepDiameter`.
    var end: CGPoint
    var color: AnnotationColor
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 28
    var blurStyle: BlurStyle = .pixelate
    /// 0 is outline-only; rect and oval use a translucent fill above 0.
    var fillOpacity: CGFloat = 0
    /// Number rendered by a `.step` marker.
    var stepNumber: Int = 1
    /// Diameter of a `.step` marker in image pixels.
    var stepDiameter: CGFloat = 40

    init(id: UUID = UUID(), kind: AnnotationKind, start: CGPoint, end: CGPoint,
         color: AnnotationColor, lineWidth: CGFloat) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    /// Normalized bounding rect (positive width/height) regardless of the
    /// direction the user dragged.
    var rect: CGRect {
        if kind == .step {
            return CGRect(x: start.x - stepDiameter / 2,
                          y: start.y - stepDiameter / 2,
                          width: stepDiameter, height: stepDiameter)
        }
        return CGRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(end.x - start.x),
                      height: abs(end.y - start.y))
    }

    /// True when the annotation is too small to be meaningful (accidental click).
    var isDegenerate: Bool {
        switch kind {
        case .arrow:
            return hypot(end.x - start.x, end.y - start.y) < 4
        case .rect, .oval, .blur:
            return rect.width < 4 || rect.height < 4
        case .text:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .step:
            return stepDiameter <= 0
        }
    }

    // MARK: Hit testing (pure — unit-testable)

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow:
            return Self.distance(from: p, toSegment: start, end) <= tolerance + lineWidth / 2
        case .rect:
            // On the stroked border (inflate/deflate by tolerance).
            let outer = rect.insetBy(dx: -tolerance - lineWidth / 2, dy: -tolerance - lineWidth / 2)
            if fillOpacity > 0 { return outer.contains(p) }
            let inner = rect.insetBy(dx: tolerance + lineWidth / 2, dy: tolerance + lineWidth / 2)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        case .oval:
            // Near the ellipse outline: compare normalized radial distance to 1.
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let cx = r.midX, cy = r.midY
            let rx = r.width / 2, ry = r.height / 2
            let nx = (p.x - cx) / rx, ny = (p.y - cy) / ry
            let d = sqrt(nx * nx + ny * ny)
            // Convert tolerance to normalized units using the smaller radius.
            let tol = (tolerance + lineWidth / 2) / min(rx, ry)
            if fillOpacity > 0 { return d <= 1 + tol }
            return abs(d - 1.0) <= tol
        case .text, .blur:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .step:
            return hypot(p.x - start.x, p.y - start.y) <= stepDiameter / 2 + tolerance
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq))
        let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    // MARK: Handles

    enum Handle: CaseIterable, Equatable {
        case start, end                                  // arrow endpoints
        case topLeft, topRight, bottomLeft, bottomRight  // shape corners
    }

    /// Draggable handles for the current kind, with their positions.
    var handles: [(Handle, CGPoint)] {
        switch kind {
        case .arrow:
            return [(.start, start), (.end, end)]
        case .rect, .oval, .blur:
            let r = rect
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)),
                    (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                    (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
        case .text, .step:
            return [] // move-only; double-click edits
        }
    }

    func handle(at p: CGPoint, tolerance: CGFloat) -> Handle? {
        handles.first { hypot($0.1.x - p.x, $0.1.y - p.y) <= tolerance }?.0
    }

    mutating func move(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
    }

    /// Drags one handle to a new position. Corner handles re-anchor
    /// start/end so the opposite corner stays fixed.
    mutating func apply(handle: Handle, to p: CGPoint, aspectLocked: Bool = false) {
        switch handle {
        case .start: start = p
        case .end:   end = p
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let r = rect
            let anchor: CGPoint
            switch handle {
            case .topLeft:     anchor = CGPoint(x: r.maxX, y: r.maxY)
            case .topRight:    anchor = CGPoint(x: r.minX, y: r.maxY)
            case .bottomLeft:  anchor = CGPoint(x: r.maxX, y: r.minY)
            case .bottomRight: anchor = CGPoint(x: r.minX, y: r.minY)
            default: return
            }
            start = anchor
            end = aspectLocked && (kind == .rect || kind == .oval)
                ? Self.aspectLockedEnd(from: anchor, to: p)
                : p
        }
    }

    // MARK: Arrow geometry (pure — unit-testable)

    /// The two barb points of the arrowhead for a shaft from `from` to `tip`.
    /// Head size scales with line width so thick arrows look proportionate.
    static func arrowheadBarbs(from: CGPoint, tip: CGPoint, lineWidth: CGFloat)
        -> (CGPoint, CGPoint)
    {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let headLength = max(10, lineWidth * 3.5)
        let spread: CGFloat = .pi / 7
        let b1 = CGPoint(x: tip.x - headLength * cos(angle - spread),
                         y: tip.y - headLength * sin(angle - spread))
        let b2 = CGPoint(x: tip.x - headLength * cos(angle + spread),
                         y: tip.y - headLength * sin(angle + spread))
        return (b1, b2)
    }

    /// Snaps an arrow endpoint to its nearest 45-degree ray from `from`.
    static func snappedArrowEnd(from: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - from.x, dy = point.y - from.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let increment = CGFloat.pi / 4
        let angle = atan2(dy, dx)
        let snapped = (angle / increment).rounded() * increment
        return CGPoint(x: from.x + length * cos(snapped),
                       y: from.y + length * sin(snapped))
    }

    /// Returns the square/circle endpoint that preserves the drag quadrant.
    static func aspectLockedEnd(from: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - from.x, dy = point.y - from.y
        let side = max(abs(dx), abs(dy))
        guard side > 0 else { return point }
        return CGPoint(x: from.x + (dx < 0 ? -side : side),
                       y: from.y + (dy < 0 ? -side : side))
    }
}

// MARK: - EditorDocument

/// The open image plus its annotations, selection, and undo history.
/// Same @Observable pattern as NotchTrayModel.
@Observable final class EditorDocument {
    let baseImage: CGImage
    let sourceURL: URL

    /// Pre-filtered full-size copies for the blur tool, computed once per
    /// document off the main thread after opening. Until ready, blur
    /// annotations render as no-ops (a fraction of a second in practice).
    var blurredBase: CGImage?
    var pixelatedBase: CGImage?

    var annotations: [Annotation] = []
    var selectedID: UUID?

    /// Annotation state at last save (or open) — dirty means "differs from it".
    private var savedAnnotations: [Annotation] = []
    private(set) var undoStack: [[Annotation]] = []
    private(set) var redoStack: [[Annotation]] = []
    /// Snapshot captured at gesture/edit begin, pushed on commit if changed.
    private var pendingSnapshot: [Annotation]?

    init(baseImage: CGImage, sourceURL: URL) {
        self.baseImage = baseImage
        self.sourceURL = sourceURL
    }

    var pixelSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    var isDirty: Bool { annotations != savedAnnotations }

    func markSaved() { savedAnnotations = annotations }

    var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    var nextStepNumber: Int {
        (annotations.compactMap { $0.kind == .step ? $0.stepNumber : nil }.max() ?? 0) + 1
    }

    /// Topmost annotation under the point (annotations later in the array
    /// draw on top, so search in reverse).
    func annotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first { $0.hitTest(p, tolerance: tolerance) }
    }

    func updateSelected(_ mutate: (inout Annotation) -> Void) {
        guard let selectedID,
              let idx = annotations.firstIndex(where: { $0.id == selectedID })
        else { return }
        mutate(&annotations[idx])
    }

    // MARK: Undo / redo (snapshot stack of value types)

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Capture the pre-change state at the start of a gesture or text edit.
    func beginChange() {
        pendingSnapshot = annotations
    }

    /// Push the captured snapshot if the gesture actually changed something.
    func commitChange() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard snapshot != annotations else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    /// Abandon a change without pushing (e.g. cancelled gesture).
    func discardChange() {
        if let snapshot = pendingSnapshot { annotations = snapshot }
        pendingSnapshot = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        // Selection may point at an annotation that no longer exists.
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    func deleteSelected() {
        guard let selectedID else { return }
        beginChange()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
        commitChange()
    }

    /// Moves the selected annotation by an exact image-pixel amount and
    /// records that keyboard nudge as one undoable edit.
    func nudgeSelected(by delta: CGPoint) {
        guard selectedID != nil else { return }
        beginChange()
        updateSelected { $0.move(by: delta) }
        commitChange()
    }

    /// Completes an inline text edit. An empty new label disappears without
    /// affecting history; non-empty text gets its export bounds and commits
    /// the snapshot captured when editing began.
    func finishTextEditing(_ id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotation = annotations[idx]
        if annotation.isDegenerate {
            annotations.remove(at: idx)
            if selectedID == id { selectedID = nil }
        } else {
            let size = AnnotationRenderer.measureText(annotation)
            annotation.end = CGPoint(x: annotation.start.x + size.width,
                                     y: annotation.start.y + size.height)
            annotations[idx] = annotation
        }
        commitChange()
    }
}
