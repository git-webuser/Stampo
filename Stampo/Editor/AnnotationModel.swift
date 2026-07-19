import AppKit
import Observation

// MARK: - Annotation primitives

enum AnnotationKind: Equatable {
    case line
    case arrow
    case rect
    case oval
    case text
    case freehand
    case blur
    case step
    case loupe
}

/// Visual variant of a straight `.line` annotation.
enum LineStyle: String, Equatable, CaseIterable {
    case solid
    case dashed
}

/// Which endpoint of an `.arrow` receives a filled arrowhead.
enum ArrowHeadPlacement: String, Equatable, CaseIterable {
    case start
    case end
    case both

    var includesStart: Bool { self == .start || self == .both }
    var includesEnd: Bool { self == .end || self == .both }
}

enum BlurStyle: String, Equatable, CaseIterable {
    case gaussian
    case pixelate
}

/// Persisted visual style of a freehand annotation. New drawing instruments
/// (pencil, brush, calligraphy pen) extend this enum without adding toolbar
/// buttons or changing the gesture model.
enum FreehandStyle: String, Equatable, CaseIterable {
    case pen
    case marker

    var opacity: CGFloat {
        switch self {
        case .pen:    return 1
        case .marker: return 0.35
        }
    }
}

/// Active instrument of the shared Drawing tool. Destructive erasing is a
/// separate top-level editor tool rather than a drawable annotation style.
enum DrawingMode: String, Equatable, CaseIterable {
    case pen
    case marker

    var freehandStyle: FreehandStyle {
        switch self {
        case .pen:    return .pen
        case .marker: return .marker
        }
    }

    init(_ style: FreehandStyle) {
        self = style == .pen ? .pen : .marker
    }
}

/// Visual variant of an `.arrow`. `filled` is the default.
enum ArrowStyle: String, Equatable, CaseIterable {
    case filled   // solid shaft, filled triangle head   (→)
    case dashed   // dashed shaft, filled head           (⇢)
    case bold     // heavy shaft, oversized filled head  (⇨)
}

/// Backing plate drawn behind `.text` for legibility over busy images.
enum TextBackground: String, Equatable, CaseIterable {
    case none
    case dark
    case light
}

/// Paragraph alignment of a (multi-line) `.text` annotation.
enum TextAlign: String, Equatable, CaseIterable {
    case left
    case center
    case right

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left:   return .left
        case .center: return .center
        case .right:  return .right
        }
    }
}

/// Outline of a `.loupe`: an ellipse or a rounded rectangle. A circle is
/// just the aspect-locked ellipse — hold shift while drawing or resizing.
enum LoupeShape: String, Equatable, CaseIterable {
    case oval
    case roundedRect
}

/// Curated fonts available to text and numbering annotations (the same set
/// Telegram curates, plus SF Rounded and Times New Roman). Short enough for a
/// useful menu while covering neutral, rounded, typewriter, geometric, book,
/// classic, monospaced, handwritten, decorative, and script styles. Every
/// named family ships with macOS; all but Papyrus also include Cyrillic —
/// missing scripts render through the system-font fallback.
enum AnnotationFontPreset: String, Equatable, CaseIterable, Identifiable {
    case system
    case rounded
    case typewriter
    case avenirNext
    case georgia
    case timesNewRoman
    case courierNew
    case noteworthy
    case papyrus
    case snellRoundhand

    var id: Self { self }

    var displayName: String {
        switch self {
        case .system:         return "SF Pro"
        case .rounded:        return "SF Rounded"
        case .typewriter:     return "American Typewriter"
        case .avenirNext:     return "Avenir Next"
        case .georgia:        return "Georgia"
        case .timesNewRoman:  return "Times New Roman"
        case .courierNew:     return "Courier New"
        case .noteworthy:     return "Noteworthy"
        case .papyrus:        return "Papyrus"
        case .snellRoundhand: return "Snell Roundhand"
        }
    }

    private var postScriptName: String? {
        switch self {
        case .system, .rounded: return nil
        case .typewriter:       return "AmericanTypewriter"
        case .avenirNext:       return "AvenirNext-Regular"
        case .georgia:          return "Georgia"
        case .timesNewRoman:    return "TimesNewRomanPSMT"
        case .courierNew:       return "CourierNewPSMT"
        case .noteworthy:       return "Noteworthy-Light"
        case .papyrus:          return "Papyrus"
        case .snellRoundhand:   return "SnellRoundhand"
        }
    }

    /// AppKit font used by the shared preview/export renderer. Trait
    /// conversion keeps the existing bold and italic controls working for
    /// every preset; the system font is the safe fallback on an unusual host.
    func nsFont(ofSize size: CGFloat, bold: Bool = false,
                italic: Bool = false) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        var font: NSFont

        switch self {
        case .system:
            font = NSFont.systemFont(ofSize: size, weight: weight)
        case .rounded:
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = system.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: descriptor, size: size) {
                font = rounded
            } else {
                font = system
            }
        default:
            font = postScriptName.flatMap { NSFont(name: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size)
            if bold {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        }

        if italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

/// Whole-annotation text traits supported by both the context bar and local
/// editor keyboard shortcuts. Text annotations intentionally don't contain
/// attributed ranges, so each trait applies to the complete label.
enum TextStyleFlag: Equatable, CaseIterable {
    case bold
    case italic
    case underline
    case strikethrough
    case shadow

    var annotationPath: WritableKeyPath<Annotation, Bool> {
        switch self {
        case .bold:          return \.bold
        case .italic:        return \.italic
        case .underline:     return \.underline
        case .strikethrough: return \.strikethrough
        case .shadow:        return \.textShadow
        }
    }

    var shortcut: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags, label: String) {
        switch self {
        case .bold:          return (11, .command, "⌘B")
        case .italic:        return (34, .command, "⌘I")
        case .underline:     return (32, .command, "⌘U")
        case .strikethrough: return (7, [.command, .shift], "⇧⌘X")
        case .shadow:        return (4, [.command, .shift], "⇧⌘H")
        }
    }

    static func shortcut(keyCode: UInt16,
                         modifiers: NSEvent.ModifierFlags) -> TextStyleFlag? {
        let exactModifiers = modifiers
            .intersection([.command, .control, .option, .shift])
        return allCases.first {
            $0.shortcut.keyCode == keyCode && $0.shortcut.modifiers == exactModifiers
        }
    }
}

/// Detented intensity scale shared by the toolbar slider and the renderer.
nonisolated enum BlurIntensity {
    static let range = 1...5
    static let defaultLevel = 3

    static func clamped(_ level: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, level))
    }
}

/// Cache key for one prefiltered full-size copy of the base image.
/// nonisolated: hashed inside the renderer's background filtering closures.
nonisolated struct BlurSource: Hashable {
    var style: BlurStyle
    var level: Int
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

    /// Perceived brightness (0…1). Used to pick legible label text over a fill.
    var luminance: Double {
        0.299 * red + 0.587 * green + 0.114 * blue
    }

    /// Black on light fills (white, yellow, orange), white on dark ones — so a
    /// step marker's number stays readable on every preset.
    var contrastingTextColor: NSColor {
        luminance > 0.6 ? .black : .white
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
    private(set) var id: UUID
    var kind: AnnotationKind
    /// Anchor point. For .line/.arrow this is the first endpoint; for shapes a drag corner;
    /// for .text the top-left of the text box; for .step its center.
    var start: CGPoint
    /// Second point. For .line it is the second endpoint, for .arrow the tip;
    /// for shapes the opposite corner;
    /// for .text the bottom-right of the measured text bounds. Step keeps it
    /// equal to `start`, since its bounds come from `stepDiameter`.
    var end: CGPoint
    var color: AnnotationColor
    var lineWidth: CGFloat
    var text: String = ""
    var fontSize: CGFloat = 28
    /// Font shared by text labels and numbering marker labels.
    var fontPreset: AnnotationFontPreset = .system
    // Text formatting.
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var strikethrough: Bool = false
    var textShadow: Bool = false
    var textBackground: TextBackground = .none
    /// Paragraph alignment of a multi-line `.text` label.
    var textAlignment: TextAlign = .left
    var blurStyle: BlurStyle = .pixelate
    /// Intensity detent for `.blur` (BlurIntensity.range).
    var blurLevel: Int = BlurIntensity.defaultLevel
    /// 0 is outline-only; rect and oval use a translucent fill above 0.
    var fillOpacity: CGFloat = 0
    /// Visual variant for `.arrow`.
    var arrowStyle: ArrowStyle = .filled
    /// Endpoint(s) that receive a filled arrowhead.
    var arrowHeadPlacement: ArrowHeadPlacement = .end
    /// Quadratic Bézier control point for a curved `.arrow`; nil is straight.
    var curveControl: CGPoint? = nil
    /// Visual variant for `.line`.
    var lineStyle: LineStyle = .solid
    /// Label rendered inside a `.step` marker. Auto-assigned as "1", "2", …
    /// on placement, but editable to arbitrary text (e.g. "1.1", "4.12").
    var stepLabel: String = "1"
    /// Diameter of a `.step` marker in image pixels.
    var stepDiameter: CGFloat = 40
    /// Explicit label size for a `.step` marker; nil auto-fits to the
    /// diameter. The renderer caps it at the fitted size either way, so the
    /// label never spills out of the circle.
    var stepLabelSize: CGFloat? = nil
    /// Native image-pixel samples of a `.freehand` annotation.
    var freehandPoints: [CGPoint] = []
    /// Rendering strategy for a `.freehand` annotation.
    var freehandStyle: FreehandStyle = .pen
    /// Magnification factor of a `.loupe`.
    var loupeScale: CGFloat = 2
    /// Outline of a `.loupe`.
    var loupeShape: LoupeShape = .oval
    /// A `.loupe` magnifies the redacted image by default so blur keeps
    /// hiding what it hides; opting in reveals the raw original pixels.
    var loupeRevealsOriginal: Bool = false

    init(id: UUID = UUID(), kind: AnnotationKind, start: CGPoint, end: CGPoint,
         color: AnnotationColor, lineWidth: CGFloat) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }

    /// Flattened polyline of a quadratic Bézier — the shared approximation
    /// used by hit-testing and bounds so both agree with what's rendered.
    static func quadraticPoints(from: CGPoint, control: CGPoint, to: CGPoint,
                                segments: Int = 16) -> [CGPoint] {
        (0...segments).map { step in
            let t = CGFloat(step) / CGFloat(segments)
            let m = 1 - t
            let a = m * m, b = 2 * m * t, c = t * t
            let x = a * from.x + b * control.x + c * to.x
            let y = a * from.y + b * control.y + c * to.y
            return CGPoint(x: x, y: y)
        }
    }

    /// Anchor the arrowhead's tangent points along. A quadratic Bézier's
    /// tangent at an endpoint runs along control→endpoint, so a curved head
    /// anchors on the control; degenerate controls (on top of the tip) fall
    /// back to the opposite endpoint so the head keeps a direction.
    func arrowheadAnchor(towardTip tip: CGPoint, opposite: CGPoint) -> CGPoint {
        guard let control = curveControl,
              hypot(control.x - tip.x, control.y - tip.y) >= 1 else { return opposite }
        return control
    }

    /// Normalized bounding rect (positive width/height) regardless of the
    /// direction the user dragged.
    var rect: CGRect {
        if kind == .step {
            return CGRect(x: start.x - stepDiameter / 2,
                          y: start.y - stepDiameter / 2,
                          width: stepDiameter, height: stepDiameter)
        }
        if kind == .arrow, let control = curveControl {
            let points = Self.quadraticPoints(from: start, control: control, to: end)
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? start.x, y: ys.min() ?? start.y,
                          width: (xs.max() ?? end.x) - (xs.min() ?? start.x),
                          height: (ys.max() ?? end.y) - (ys.min() ?? start.y))
        }
        if kind == .freehand, let first = freehandPoints.first {
            var minX = first.x, maxX = first.x
            var minY = first.y, maxY = first.y
            for point in freehandPoints.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            let radius = lineWidth / 2
            return CGRect(x: minX - radius, y: minY - radius,
                          width: maxX - minX + lineWidth,
                          height: maxY - minY + lineWidth)
        }
        return CGRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(end.x - start.x),
                      height: abs(end.y - start.y))
    }

    /// True when the annotation is too small to be meaningful (accidental click).
    var isDegenerate: Bool {
        switch kind {
        case .line, .arrow:
            return hypot(end.x - start.x, end.y - start.y) < 4
        case .rect, .oval, .blur, .loupe:
            return rect.width < 4 || rect.height < 4
        case .text:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .freehand:
            return freehandPoints.isEmpty
        case .step:
            return stepDiameter <= 0
        }
    }

    // MARK: Hit testing (pure — unit-testable)

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .line, .arrow:
            let distance = tolerance + lineWidth / 2
            if kind == .arrow, let control = curveControl {
                let points = Self.quadraticPoints(from: start, control: control, to: end)
                return zip(points, points.dropFirst()).contains { a, b in
                    Self.distance(from: p, toSegment: a, b) <= distance
                }
            }
            return Self.distance(from: p, toSegment: start, end) <= distance
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
        case .freehand:
            guard let first = freehandPoints.first else { return false }
            let distance = tolerance + lineWidth / 2
            if freehandPoints.count == 1 {
                return hypot(p.x - first.x, p.y - first.y) <= distance
            }
            return zip(freehandPoints, freehandPoints.dropFirst()).contains { a, b in
                Self.distance(from: p, toSegment: a, b) <= distance
            }
        case .step:
            return hypot(p.x - start.x, p.y - start.y) <= stepDiameter / 2 + tolerance
        case .loupe:
            // Full interior: the loupe occludes what's beneath it anyway.
            if loupeShape == .roundedRect {
                return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
            }
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2)
            let ny = (p.y - r.midY) / (r.height / 2)
            let tol = tolerance / min(r.width, r.height) * 2
            return sqrt(nx * nx + ny * ny) <= 1 + tol
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
        case start, end                                  // line/arrow endpoints
        case control                                     // arrow curve control
        case topLeft, topRight, bottomLeft, bottomRight  // shape corners
    }

    /// Draggable handles for the current kind, with their positions.
    var handles: [(Handle, CGPoint)] {
        switch kind {
        case .arrow:
            // Control last so endpoint grabs win on tiny arrows. A straight
            // arrow offers it at the midpoint — dragging it bends the shaft.
            let control = curveControl
                ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            return [(.start, start), (.end, end), (.control, control)]
        case .line:
            return [(.start, start), (.end, end)]
        case .rect, .oval, .blur, .loupe:
            let r = rect
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)),
                    (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                    (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY))]
        case .text, .freehand, .step:
            return [] // move-only; double-click edits
        }
    }

    func handle(at p: CGPoint, tolerance: CGFloat) -> Handle? {
        handles.first { hypot($0.1.x - p.x, $0.1.y - p.y) <= tolerance }?.0
    }

    mutating func move(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
        if let control = curveControl {
            curveControl = CGPoint(x: control.x + delta.x, y: control.y + delta.y)
        }
        if kind == .freehand {
            freehandPoints = freehandPoints.map {
                CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
        }
    }

    /// Adds a native-pixel point when it is far enough from the previous
    /// sample. The threshold is supplied by the view in screen-point terms,
    /// converted through the current zoom, to keep paths smooth but compact.
    @discardableResult
    mutating func appendFreehandPoint(_ point: CGPoint,
                                      minimumDistance: CGFloat) -> Bool {
        guard kind == .freehand else { return false }
        if let last = freehandPoints.last,
           hypot(point.x - last.x, point.y - last.y) < minimumDistance {
            return false
        }
        freehandPoints.append(point)
        start = freehandPoints.first ?? point
        end = point
        return true
    }

    /// Returns this stroke after removing the visible portion touched by one
    /// segment of an eraser gesture. A cut can yield multiple independently
    /// movable fragments; the first retains identity, later fragments get new
    /// UUIDs. Non-freehand annotations pass through unchanged.
    func erasingFreehand(from eraserStart: CGPoint, to eraserEnd: CGPoint,
                         radius: CGFloat) -> (fragments: [Annotation], changed: Bool) {
        guard kind == .freehand, !freehandPoints.isEmpty else { return ([self], false) }

        // Densify before classifying so a fast stroke with two distant samples
        // cannot tunnel across a narrow eraser path without being cut.
        let interval = max(0.75, min(max(radius, 1), max(lineWidth, 1)) / 2)
        var samples: [CGPoint] = [freehandPoints[0]]
        for (a, b) in zip(freehandPoints, freehandPoints.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(1, Int(ceil(length / interval)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                samples.append(CGPoint(x: a.x + (b.x - a.x) * t,
                                       y: a.y + (b.y - a.y) * t))
            }
        }

        let visibleRadius = max(0, radius) + lineWidth / 2
        let erased = samples.map {
            Self.distance(from: $0, toSegment: eraserStart, eraserEnd) <= visibleRadius
        }
        guard erased.contains(true) else { return ([self], false) }

        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (point, isErased) in zip(samples, erased) {
            if isErased {
                if !current.isEmpty { runs.append(current); current = [] }
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { runs.append(current) }

        let fragments = runs.enumerated().map { index, points in
            var fragment = self
            if index > 0 { fragment.id = UUID() }
            fragment.freehandPoints = points
            fragment.start = points.first ?? start
            fragment.end = points.last ?? end
            return fragment
        }
        return (fragments, true)
    }

    /// Value-copy for duplication: every visual/geometry property is retained,
    /// while identity is replaced so SwiftUI and the undo model see a new item.
    func duplicated(offset: CGPoint = .zero) -> Annotation {
        var copy = self
        copy.id = UUID()
        copy.move(by: offset)
        return copy
    }

    /// Drags one handle to a new position. Corner handles re-anchor
    /// start/end so the opposite corner stays fixed.
    mutating func apply(handle: Handle, to p: CGPoint, aspectLocked: Bool = false) {
        switch handle {
        case .start: start = p
        case .end:   end = p
        case .control:
            if kind == .arrow { curveControl = p }
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
            // Shift locks the aspect for area shapes (a loupe's oval becomes
            // a circle, its rounded rect a square).
            let lockAspect = aspectLocked
                && (kind == .rect || kind == .oval || kind == .loupe)
            end = lockAspect ? Self.aspectLockedEnd(from: anchor, to: p) : p
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

// MARK: - Document history

/// One point-in-time snapshot of everything the undo stack must restore: the
/// annotations, the base image, and the rotation count. Carrying the image (by
/// reference — cheap for annotation-only edits that don't change it) is what
/// lets whole-image operations like crop and rotate be undone.
struct DocumentSnapshot: Equatable {
    var annotations: [Annotation]
    var image: CGImage
    var rotationQuarters: Int

    static func == (lhs: DocumentSnapshot, rhs: DocumentSnapshot) -> Bool {
        lhs.rotationQuarters == rhs.rotationQuarters
            && lhs.image === rhs.image                 // identity: same image object
            && lhs.annotations == rhs.annotations
    }
}

// MARK: - EditorDocument

/// The open image plus its annotations, selection, and undo history.
/// Same @Observable pattern as NotchTrayModel.
@Observable final class EditorDocument {
    private(set) var baseImage: CGImage
    let sourceURL: URL

    /// Net 90° turns applied to the image since open (mod 4). Part of the
    /// snapshot so a rotation alone still counts as a change.
    private var rotationQuarters = 0

    /// Pre-filtered full-size copies for the blur tool, keyed by style and
    /// intensity level and computed lazily off the main thread on first
    /// request. Until a source is ready, its blur annotations render as
    /// no-ops (a fraction of a second in practice).
    private(set) var blurSources: [BlurSource: CGImage] = [:]
    private var blurSourcesInFlight: Set<BlurSource> = []

    var annotations: [Annotation] = []
    var selectedID: UUID?

    /// Document state at last save (or open) — dirty means "differs from it".
    private var savedSnapshot: DocumentSnapshot
    private(set) var undoStack: [DocumentSnapshot] = []
    private(set) var redoStack: [DocumentSnapshot] = []
    /// Snapshot captured at gesture/edit begin, pushed on commit if changed.
    private var pendingSnapshot: DocumentSnapshot?

    init(baseImage: CGImage, sourceURL: URL) {
        self.baseImage = baseImage
        self.sourceURL = sourceURL
        self.savedSnapshot = DocumentSnapshot(annotations: [], image: baseImage,
                                              rotationQuarters: 0)
    }

    /// Everything the history restores, captured from live state.
    private var currentSnapshot: DocumentSnapshot {
        DocumentSnapshot(annotations: annotations, image: baseImage,
                         rotationQuarters: rotationQuarters)
    }

    var pixelSize: CGSize {
        CGSize(width: baseImage.width, height: baseImage.height)
    }

    /// Image-relative default for newly placed text (also the slider's value
    /// while nothing is selected and the user hasn't picked a size yet).
    var autoFontSize: CGFloat {
        max(24, pixelSize.width / 60)
    }

    // MARK: Blur sources

    /// Kicks off background filtering for one style+level if it's neither
    /// cached nor already being computed. Same GCD pattern as the window
    /// controller's original one-shot preparation.
    func prepareBlurSource(style: BlurStyle, level: Int) {
        let key = BlurSource(style: style, level: BlurIntensity.clamped(level))
        guard blurSources[key] == nil, !blurSourcesInFlight.contains(key) else { return }
        blurSourcesInFlight.insert(key)
        let base = baseImage
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = key.style == .pixelate
                ? AnnotationRenderer.makePixelated(base: base, level: key.level)
                : AnnotationRenderer.makeBlurred(base: base, level: key.level)
            DispatchQueue.main.async {
                guard let self else { return }
                self.blurSourcesInFlight.remove(key)
                if let image { self.blurSources[key] = image }
            }
        }
    }

    /// Undo/redo can resurrect blur annotations whose source was never
    /// computed in this session; request any that are missing.
    private func prepareBlurSourcesForAnnotations() {
        for annotation in annotations where annotation.kind == .blur {
            prepareBlurSource(style: annotation.blurStyle, level: annotation.blurLevel)
        }
    }

    var isDirty: Bool {
        currentSnapshot != savedSnapshot
    }

    func markSaved() {
        savedSnapshot = currentSnapshot
    }

    /// The blur caches belong to one specific base image, so any operation that
    /// replaces `baseImage` (rotate, crop, an undo/redo across one) must drop
    /// and re-warm them.
    private func rebuildBlurSources() {
        blurSources.removeAll()
        blurSourcesInFlight.removeAll()
        prepareBlurSource(style: .gaussian, level: BlurIntensity.defaultLevel)
        prepareBlurSource(style: .pixelate, level: BlurIntensity.defaultLevel)
        prepareBlurSourcesForAnnotations()
    }

    // MARK: Whole-image rotation (90° steps)

    /// Maps an image-pixel point through one 90° turn, given the pre-rotation
    /// size. Pure so the same transform can be replayed over every stored
    /// coordinate (live, saved, and each undo/redo snapshot).
    static func rotatePoint(_ p: CGPoint, in size: CGSize, clockwise: Bool) -> CGPoint {
        clockwise
            ? CGPoint(x: size.height - p.y, y: p.x)          // (x,y) → (H−y, x)
            : CGPoint(x: p.y, y: size.width - p.x)           // (x,y) → (y, W−x)
    }

    private static func rotateAnnotations(_ list: [Annotation], in size: CGSize,
                                          clockwise: Bool) -> [Annotation] {
        list.map { a in
            var a = a
            a.start = rotatePoint(a.start, in: size, clockwise: clockwise)
            a.end = rotatePoint(a.end, in: size, clockwise: clockwise)
            if let control = a.curveControl {
                a.curveControl = rotatePoint(control, in: size, clockwise: clockwise)
            }
            if a.kind == .freehand {
                a.freehandPoints = a.freehandPoints.map {
                    rotatePoint($0, in: size, clockwise: clockwise)
                }
            }
            return a
        }
    }

    /// Rotates the base image and every stored coordinate a quarter turn so
    /// the whole pipeline keeps operating in one consistent (rotated) frame —
    /// no special-casing in the renderer, hit-testing, or handles. Undoable as
    /// one step; the snapshot carries the pre-rotation image so undo restores it.
    func rotate(clockwise: Bool) {
        guard let rotated = AnnotationRenderer.rotated90(baseImage, clockwise: clockwise) else { return }
        beginChange()
        let oldSize = pixelSize
        annotations = Self.rotateAnnotations(annotations, in: oldSize, clockwise: clockwise)
        baseImage = rotated
        rotationQuarters = ((rotationQuarters + (clockwise ? 1 : -1)) % 4 + 4) % 4
        rebuildBlurSources()
        commitChange()
    }

    /// Crops the base image and remaps annotations to `rect` (in current
    /// image-pixel space). Undoable as one step: annotations shift by the crop
    /// origin and any that no longer overlap the cropped canvas are dropped.
    func crop(to rect: CGRect) {
        let bounds = CGRect(origin: .zero, size: pixelSize)
        let region = rect.integral.intersection(bounds)
        guard region.width >= 1, region.height >= 1, region != bounds,
              let cropped = baseImage.cropping(to: region) else { return }
        beginChange()
        let newBounds = CGRect(x: 0, y: 0, width: region.width, height: region.height)
        let offset = CGPoint(x: -region.origin.x, y: -region.origin.y)
        annotations = annotations.compactMap { a in
            var moved = a
            moved.move(by: offset)
            return moved.rect.intersects(newBounds) ? moved : nil
        }
        baseImage = cropped
        rebuildBlurSources()
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        commitChange()
    }

    var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    /// Next auto-label for a placed step: one past the highest purely-numeric
    /// existing label. Custom labels like "1.1" don't participate, so manual
    /// edits never derail the running count.
    var nextStepLabel: String {
        let highest = annotations.compactMap { $0.kind == .step ? Int($0.stepLabel) : nil }.max() ?? 0
        return String(highest + 1)
    }

    /// Topmost annotation under the point (annotations later in the array
    /// draw on top, so search in reverse). Blur is a bottom redaction layer,
    /// so a non-blur annotation over it wins the hit even when the blur was
    /// added later.
    func annotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first { $0.kind != .blur && $0.hitTest(p, tolerance: tolerance) }
            ?? annotations.reversed().first { $0.kind == .blur && $0.hitTest(p, tolerance: tolerance) }
    }

    func updateSelected(_ mutate: (inout Annotation) -> Void) {
        guard let selectedID,
              let idx = annotations.firstIndex(where: { $0.id == selectedID })
        else { return }
        mutate(&annotations[idx])
    }

    /// Applies one eraser movement to every freehand style while preserving
    /// all other annotation kinds and their stacking order. The caller owns
    /// begin/commit so a complete drag becomes one undo step.
    @discardableResult
    func eraseFreehand(from start: CGPoint, to end: CGPoint,
                       diameter: CGFloat) -> Bool {
        var didChange = false
        annotations = annotations.flatMap { annotation in
            let result = annotation.erasingFreehand(
                from: start, to: end, radius: max(0, diameter) / 2
            )
            didChange = didChange || result.changed
            return result.fragments
        }
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        return didChange
    }

    // MARK: Undo / redo (snapshot stack of value types)

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Capture the pre-change state at the start of a gesture or edit.
    func beginChange() {
        pendingSnapshot = currentSnapshot
    }

    /// Push the captured snapshot if the gesture actually changed something.
    func commitChange() {
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard snapshot != currentSnapshot else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
    }

    /// Abandon a change without pushing (e.g. cancelled gesture).
    func discardChange() {
        if let snapshot = pendingSnapshot { restore(snapshot) }
        pendingSnapshot = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(next)
    }

    /// Restores a snapshot's annotations, image, and rotation. Rebuilds blur
    /// caches only when the image actually changed (crop/rotate steps), and
    /// drops a selection that no longer exists.
    private func restore(_ snapshot: DocumentSnapshot) {
        let imageChanged = snapshot.image !== baseImage
        annotations = snapshot.annotations
        baseImage = snapshot.image
        rotationQuarters = snapshot.rotationQuarters
        if imageChanged {
            rebuildBlurSources()
        } else {
            prepareBlurSourcesForAnnotations()
        }
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

    /// Appends an exact duplicate above all existing annotations as part of an
    /// already-open change (used by Option-drag so creation + movement share
    /// one undo step). Returns the new annotation's identity.
    @discardableResult
    func appendDuplicate(of id: UUID, offset: CGPoint = .zero) -> UUID? {
        guard let source = annotations.first(where: { $0.id == id }) else { return nil }
        let copy = source.duplicated(offset: offset)
        annotations.append(copy)
        selectedID = copy.id
        return copy.id
    }

    /// Duplicates the current selection as one complete undoable command.
    @discardableResult
    func duplicateSelected(offset: CGPoint = CGPoint(x: 40, y: 40)) -> UUID? {
        guard let selectedID else { return nil }
        beginChange()
        guard let duplicateID = appendDuplicate(of: selectedID, offset: offset) else {
            discardChange()
            return nil
        }
        commitChange()
        return duplicateID
    }

    // MARK: Z-order (array order is draw order; blur is a separate bottom layer)

    /// Index of the nearest annotation in the same render group as `idx`
    /// (blur always renders beneath non-blur, so the groups never interleave
    /// visually) in the given direction, or nil at that group's edge. Skipping
    /// the other group keeps every successful reorder visible on canvas.
    private func adjacentSameGroupIndex(from idx: Int, forward: Bool) -> Int? {
        let isBlur = annotations[idx].kind == .blur
        let neighbors = forward
            ? Array(annotations.indices.suffix(from: idx + 1))
            : annotations.indices.prefix(upTo: idx).reversed().map { $0 }
        return neighbors.first { (annotations[$0].kind == .blur) == isBlur }
    }

    /// Swaps the selection with its next same-group neighbor above.
    /// One undoable step; a no-op at the top never touches history.
    func bringSelectedForward() {
        reorderSelected { idx in
            guard let target = adjacentSameGroupIndex(from: idx, forward: true) else { return }
            annotations.swapAt(idx, target)
        }
    }

    /// Swaps the selection with its next same-group neighbor below.
    func sendSelectedBackward() {
        reorderSelected { idx in
            guard let target = adjacentSameGroupIndex(from: idx, forward: false) else { return }
            annotations.swapAt(idx, target)
        }
    }

    /// Moves the selection above every other annotation (of any group — the
    /// renderer's blur partition keeps blur beneath regardless).
    func bringSelectedToFront() {
        reorderSelected { idx in
            guard idx != annotations.indices.last else { return }
            annotations.append(annotations.remove(at: idx))
        }
    }

    /// Moves the selection beneath every other annotation.
    func sendSelectedToBack() {
        reorderSelected { idx in
            guard idx != 0 else { return }
            annotations.insert(annotations.remove(at: idx), at: 0)
        }
    }

    /// Runs one reorder mutation as a single undo step. `commitChange`'s
    /// snapshot-equality guard drops boundary no-ops from history.
    private func reorderSelected(_ mutate: (Int) -> Void) {
        guard let selectedID,
              let idx = annotations.firstIndex(where: { $0.id == selectedID })
        else { return }
        beginChange()
        mutate(idx)
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

    /// Toggles one whole-label text trait and keeps its export bounds fitted.
    /// Inline editing already owns a pending snapshot, so callers can opt out
    /// of opening a nested undo command and let the edit commit everything.
    @discardableResult
    func toggleTextStyle(_ flag: TextStyleFlag, annotationID: UUID? = nil,
                         undoable: Bool = true) -> Bool? {
        guard let id = annotationID ?? selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].kind == .text
        else { return nil }

        if undoable { beginChange() }
        annotations[idx][keyPath: flag.annotationPath].toggle()
        let size = AnnotationRenderer.measureText(annotations[idx])
        annotations[idx].end = CGPoint(x: annotations[idx].start.x + size.width,
                                       y: annotations[idx].start.y + size.height)
        let newValue = annotations[idx][keyPath: flag.annotationPath]
        if undoable { commitChange() }
        return newValue
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

    /// Completes an inline step-label edit. A step is a placed marker, so an
    /// empty label is not deletion — it falls back to "?" so the circle keeps
    /// meaning. Bounds come from `stepDiameter`, so there's nothing to remeasure.
    func finishStepEditing(_ id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        if annotations[idx].stepLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            annotations[idx].stepLabel = "?"
        }
        commitChange()
    }
}
