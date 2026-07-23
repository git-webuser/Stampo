import AppKit
import Observation

// MARK: - Annotation primitives

enum AnnotationKind: Equatable {
    case line
    case arrow
    case rect
    case oval
    case roundedRect
    case polygon
    case star
    case bubble
    case text
    case freehand
    case blur
    case step
    case loupe

    /// Closed-region shapes whose outline is a computed `CGPath` over the
    /// bounding rect (unlike rect/oval, which stroke CG primitives directly).
    /// They share the family's corner handles, resize, and fill semantics.
    /// A triangle is the 3-sided polygon, not a separate kind.
    var isPathShape: Bool {
        switch self {
        case .roundedRect, .polygon, .star, .bubble: return true
        default: return false
        }
    }
}

/// Which side of a `.bubble` speech balloon carries the tail.
enum BubbleTailDirection: String, Equatable, CaseIterable {
    case left
    case right
}

/// Detented counts shared by the toolbar steppers and the path builders.
nonisolated enum ShapeCounts {
    static let polygonSides = 3...12
    static let defaultPolygonSides = 6
    static let starPoints = 4...10
    static let defaultStarPoints = 5
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

/// Tip of the marker nib: round lays soft stroke caps, square flat ones —
/// the classic chisel-highlighter look. The pen always draws round.
enum MarkerTip: String, Equatable, CaseIterable {
    case round
    case square
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
    /// Number of sides of a `.polygon` (ShapeCounts.polygonSides).
    var polygonSides: Int = ShapeCounts.defaultPolygonSides
    /// Number of points of a `.star` (ShapeCounts.starPoints).
    var starPoints: Int = ShapeCounts.defaultStarPoints
    /// Vertically asymmetric shapes (polygon, star) drawn apex-down (funnel).
    /// Set from the drag direction while drawing; a resize toggles it only on
    /// a decisive push through the opposite edge (see `apply(handle:)`).
    var flippedVertically: Bool = false
    /// Which side of a `.bubble` carries the tail.
    var bubbleTail: BubbleTailDirection = .right
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
    /// Nib shape of a `.freehand` marker stroke; pens ignore it.
    var markerTip: MarkerTip = .round
    /// Magnification factor of a `.loupe`.
    var loupeScale: CGFloat = 2
    /// Outline of a `.loupe`.
    var loupeShape: LoupeShape = .oval
    /// Center of the **callout** loupe's source marker. nil is the plain
    /// in-place loupe (it magnifies the pixels beneath itself). The marker and
    /// the magnifier are two independent frames sharing the loupe's shape,
    /// joined by a straight connector; each is dragged independently, while
    /// whole-annotation moves (`move(by:)`) carry both.
    var loupeSource: CGPoint? = nil
    /// Size of the callout marker, stored independently of the magnifier — the
    /// magnification (`loupeScale`) zooms the content, not the marker frame, so
    /// the region the user chose keeps its size when magnification changes.
    var loupeSourceSize: CGSize? = nil
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

    /// The callout marker's frame in image space (its stored center and
    /// size). nil for an in-place loupe.
    var loupeSourceRect: CGRect? {
        guard kind == .loupe, let center = loupeSource,
              let size = loupeSourceSize else { return nil }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The two independently draggable bodies of a callout loupe.
    enum LoupePart: Equatable {
        case display
        case source
    }

    /// Which body of a callout loupe the point lands on; the magnifier wins
    /// when the two overlap. nil for misses and for in-place loupes (whose
    /// single body routes through the ordinary move path).
    func loupePart(at p: CGPoint, tolerance: CGFloat) -> LoupePart? {
        guard kind == .loupe, loupeSource != nil else { return nil }
        if Self.shapeContains(p, in: rect, shape: loupeShape, tolerance: tolerance) {
            return .display
        }
        if let sourceRect = loupeSourceRect,
           Self.shapeContains(p, in: sourceRect, shape: loupeShape,
                              tolerance: tolerance) {
            return .source
        }
        return nil
    }

    /// Drags one body of a callout loupe without disturbing the other.
    mutating func moveLoupePart(_ part: LoupePart, by delta: CGPoint) {
        switch part {
        case .display:
            start.x += delta.x; start.y += delta.y
            end.x += delta.x; end.y += delta.y
        case .source:
            guard let source = loupeSource else { return }
            loupeSource = CGPoint(x: source.x + delta.x, y: source.y + delta.y)
        }
    }

    /// Full-interior containment for a loupe body (ellipse or rounded rect —
    /// corner rounding is within tolerance of the plain rect).
    private static func shapeContains(_ p: CGPoint, in r: CGRect,
                                      shape: LoupeShape,
                                      tolerance: CGFloat) -> Bool {
        switch shape {
        case .roundedRect:
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .oval:
            guard r.width > 0, r.height > 0 else { return false }
            let nx = (p.x - r.midX) / (r.width / 2)
            let ny = (p.y - r.midY) / (r.height / 2)
            let tol = tolerance / min(r.width, r.height) * 2
            return sqrt(nx * nx + ny * ny) <= 1 + tol
        }
    }

    /// Endpoints of a callout's connector: where the straight line between
    /// the source and magnifier centers crosses each outline. nil while the
    /// bodies overlap (the line would be hidden anyway) — pure, so the
    /// renderer and tests agree on when the connector appears.
    func loupeConnectorPoints() -> (CGPoint, CGPoint)? {
        guard let sourceRect = loupeSourceRect else { return nil }
        let displayRect = rect
        let c1 = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let c2 = CGPoint(x: displayRect.midX, y: displayRect.midY)
        let distance = hypot(c2.x - c1.x, c2.y - c1.y)
        guard distance > 0.01 else { return nil }
        let dxn = (c2.x - c1.x) / distance, dyn = (c2.y - c1.y) / distance
        let t1 = Self.edgeDistance(halfWidth: sourceRect.width / 2,
                                   halfHeight: sourceRect.height / 2,
                                   shape: loupeShape, dxn: dxn, dyn: dyn)
        let t2 = Self.edgeDistance(halfWidth: displayRect.width / 2,
                                   halfHeight: displayRect.height / 2,
                                   shape: loupeShape, dxn: dxn, dyn: dyn)
        guard t1 + t2 < distance else { return nil }
        return (CGPoint(x: c1.x + dxn * t1, y: c1.y + dyn * t1),
                CGPoint(x: c2.x - dxn * t2, y: c2.y - dyn * t2))
    }

    /// Distance from a shape's center to its outline along a unit direction
    /// (ray–ellipse, or ray–box with corner rounding ignored).
    private static func edgeDistance(halfWidth: CGFloat, halfHeight: CGFloat,
                                     shape: LoupeShape,
                                     dxn: CGFloat, dyn: CGFloat) -> CGFloat {
        guard halfWidth > 0, halfHeight > 0 else { return 0 }
        switch shape {
        case .oval:
            return 1 / sqrt(pow(dxn / halfWidth, 2) + pow(dyn / halfHeight, 2))
        case .roundedRect:
            return 1 / max(abs(dxn) / halfWidth, abs(dyn) / halfHeight)
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

    // MARK: Path-shape outlines (pure — unit-testable)

    /// Outline path of a path-shape kind over its bounding rect; nil for
    /// other kinds. Shared by rendering and hit-testing so they always agree.
    var pathShapeOutline: CGPath? {
        let r = rect
        switch kind {
        case .roundedRect:
            let radius = Self.shapeCornerRadius(for: r)
            return CGPath(roundedRect: r, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        case .polygon:
            return Self.closedPath(Self.polygonVertices(
                sides: polygonSides, in: r, flippedVertically: flippedVertically))
        case .star:
            return Self.closedPath(Self.starVertices(
                points: starPoints, in: r, flippedVertically: flippedVertically))
        case .bubble:
            return Self.bubblePath(tail: bubbleTail, in: r)
        default:
            return nil
        }
    }

    /// While drawing, vertically asymmetric shapes follow the drag: pulling
    /// upward points the apex down (funnel). Called by the canvas on every
    /// creation update; once the shape exists the orientation is fixed.
    mutating func updateCreationOrientation() {
        guard kind == .polygon || kind == .star else { return }
        flippedVertically = end.y < start.y
    }

    /// Corner rounding of a rounded rect or bubble body: the loupe's 20%
    /// proportion, capped so large regions keep a crisp, UI-like radius.
    static func shapeCornerRadius(for r: CGRect) -> CGFloat {
        min(min(r.width, r.height) * 0.2, 40)
    }

    /// Vertices of a regular n-gon, first vertex centered on the top edge
    /// (image space, y grows downward). A triangle is the 3-sided case.
    static func polygonVertices(sides: Int, in r: CGRect,
                                flippedVertically: Bool = false) -> [CGPoint] {
        let n = max(3, sides)
        let unit = (0..<n).map { index -> CGPoint in
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(n)
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        return Self.fitUnitPoints(unit, in: r, flippedVertically: flippedVertically)
    }

    /// Vertices of an n-pointed star: outer points alternating with inner
    /// points at a fixed radius ratio, first point at the top. 0.4
    /// approximates the classic pentagram's inner radius.
    static func starVertices(points: Int, in r: CGRect,
                             flippedVertically: Bool = false) -> [CGPoint] {
        let n = max(2, points)
        let unit = (0..<(2 * n)).map { index -> CGPoint in
            let angle = -CGFloat.pi / 2 + .pi * CGFloat(index) / CGFloat(n)
            let k: CGFloat = index.isMultiple(of: 2) ? 1 : 0.4
            return CGPoint(x: k * cos(angle), y: k * sin(angle))
        }
        return Self.fitUnitPoints(unit, in: r, flippedVertically: flippedVertically)
    }

    /// Maps unit-circle samples into the rect so their bounding box exactly
    /// fills it. Inscribing the vertices directly would leave gaps on flat
    /// sides (a triangle inscribed in the rect's ellipse floats a quarter of
    /// the height above the bottom edge) and make the occupied area vary
    /// with the side/point count.
    private static func fitUnitPoints(_ unit: [CGPoint], in r: CGRect,
                                      flippedVertically: Bool) -> [CGPoint] {
        guard let first = unit.first else { return [] }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in unit.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let spanX = max(maxX - minX, 0.0001)
        let spanY = max(maxY - minY, 0.0001)
        return unit.map { point in
            let nx = (point.x - minX) / spanX
            let ny = (point.y - minY) / spanY
            return CGPoint(x: r.minX + nx * r.width,
                           y: r.minY + (flippedVertically ? 1 - ny : ny) * r.height)
        }
    }

    private static func closedPath(_ vertices: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = vertices.first else { return path }
        path.move(to: first)
        for vertex in vertices.dropFirst() { path.addLine(to: vertex) }
        path.closeSubpath()
        return path
    }

    /// Speech balloon: a rounded-rect body over the top of the rect with a
    /// flag-like tail whose outer edge continues the chosen side straight
    /// down to the rect's bottom corner — the same silhouette as SF Symbols'
    /// bubble.left/right, so the popover icon predicts the drawn shape.
    static func bubblePath(tail: BubbleTailDirection, in r: CGRect) -> CGPath {
        let tailSize = min(r.height * 0.25, r.width * 0.3, 56)
        let body = CGRect(x: r.minX, y: r.minY,
                          width: r.width, height: max(1, r.height - tailSize))
        let radius = min(Self.shapeCornerRadius(for: body),
                         body.width / 2, body.height / 2)
        let path = CGMutablePath()
        switch tail {
        case .right:
            path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
            path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                        tangent2End: CGPoint(x: body.maxX, y: body.minY + radius),
                        radius: radius)
            path.addLine(to: CGPoint(x: body.maxX, y: r.maxY))          // tail tip
            path.addLine(to: CGPoint(x: body.maxX - tailSize, y: body.maxY))
            path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                        tangent2End: CGPoint(x: body.minX, y: body.maxY - radius),
                        radius: radius)
            path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                        tangent2End: CGPoint(x: body.minX + radius, y: body.minY),
                        radius: radius)
        case .left:
            path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
            path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                        tangent2End: CGPoint(x: body.maxX, y: body.minY + radius),
                        radius: radius)
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                        tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY),
                        radius: radius)
            path.addLine(to: CGPoint(x: body.minX + tailSize, y: body.maxY))
            path.addLine(to: CGPoint(x: body.minX, y: r.maxY))          // tail tip
            path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                        tangent2End: CGPoint(x: body.minX + radius, y: body.minY),
                        radius: radius)
        }
        path.closeSubpath()
        return path
    }

    /// True when the annotation is too small to be meaningful (accidental click).
    var isDegenerate: Bool {
        switch kind {
        case .line, .arrow:
            return hypot(end.x - start.x, end.y - start.y) < 4
        case .rect, .oval, .roundedRect, .polygon, .star, .bubble,
             .blur, .loupe:
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
            // Whole interior, filled or not: 0% fill still reads as the
            // shape's body, so selecting doesn't require sniping the outline
            // (Fitts). The cost — a frame drawn atop other annotations
            // swallows clicks inside it — follows z-order, topmost first.
            return rect.insetBy(dx: -tolerance - lineWidth / 2,
                                dy: -tolerance - lineWidth / 2).contains(p)
        case .oval:
            // Inside the ellipse (plus tolerance): interior counts as body
            // even without a fill — same Fitts rationale as .rect.
            let r = rect
            guard r.width > 0, r.height > 0 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            // Convert tolerance to normalized units using the smaller radius.
            let tol = (tolerance + lineWidth / 2) / min(rx, ry)
            return sqrt(nx * nx + ny * ny) <= 1 + tol
        case .roundedRect, .polygon, .star, .bubble:
            // The full path interior, or near the stroked outline — the same
            // path the renderer draws, inflated by the tolerance.
            guard let outline = pathShapeOutline else { return false }
            if outline.contains(p) { return true }
            return outline.copy(strokingWithWidth: lineWidth + tolerance * 2,
                                lineCap: .round, lineJoin: .round,
                                miterLimit: 10).contains(p)
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
            // Full interior: the loupe occludes what's beneath it anyway. A
            // callout's source marker is a second hittable body.
            if Self.shapeContains(p, in: rect, shape: loupeShape,
                                  tolerance: tolerance) {
                return true
            }
            if let sourceRect = loupeSourceRect {
                return Self.shapeContains(p, in: sourceRect, shape: loupeShape,
                                          tolerance: tolerance)
            }
            return false
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
        // A callout loupe's source marker carries its own corner handles.
        case sourceTopLeft, sourceTopRight, sourceBottomLeft, sourceBottomRight

        /// The display-body corner mirroring a source corner (both resize the
        /// pair together, so they share resize logic).
        var displayCounterpart: Handle? {
            switch self {
            case .sourceTopLeft:     return .topLeft
            case .sourceTopRight:    return .topRight
            case .sourceBottomLeft:  return .bottomLeft
            case .sourceBottomRight: return .bottomRight
            default:                 return nil
            }
        }
    }

    private static func corners(of r: CGRect,
                                _ handles: (Handle, Handle, Handle, Handle))
        -> [(Handle, CGPoint)] {
        [(handles.0, CGPoint(x: r.minX, y: r.minY)),
         (handles.1, CGPoint(x: r.maxX, y: r.minY)),
         (handles.2, CGPoint(x: r.minX, y: r.maxY)),
         (handles.3, CGPoint(x: r.maxX, y: r.maxY))]
    }

    /// Draggable handles for the current kind, with their positions. A callout
    /// loupe adds a second set of corners on its source marker (source handles
    /// last so a display grab wins where the two bodies overlap).
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
        case .rect, .oval, .roundedRect, .polygon, .star, .bubble,
             .blur, .loupe:
            var result = Self.corners(of: rect,
                                      (.topLeft, .topRight, .bottomLeft, .bottomRight))
            if let sourceRect = loupeSourceRect {
                result += Self.corners(of: sourceRect,
                                       (.sourceTopLeft, .sourceTopRight,
                                        .sourceBottomLeft, .sourceBottomRight))
            }
            return result
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
        if let source = loupeSource {
            loupeSource = CGPoint(x: source.x + delta.x, y: source.y + delta.y)
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

    /// Smallest edge an area shape can be resized down to (image pixels) —
    /// keeps a compressed shape a shape instead of a degenerate line.
    static let minimumShapeSize: CGFloat = 8

    /// Drags one handle to a new position, returning the handle the drag
    /// should continue with. Corner handles re-anchor start/end so the
    /// opposite corner stays fixed; within ±minimumShapeSize of the anchor
    /// they sit in a dead zone at the minimum size (jitter can't flip the
    /// shape), while a decisive push through the opposite edge mirrors the
    /// geometry — the grabbed corner takes the mirrored handle's role and a
    /// polygon/star flips its apex.
    @discardableResult
    mutating func apply(handle: Handle, to p: CGPoint,
                        aspectLocked: Bool = false) -> Handle {
        switch handle {
        case .start: start = p
        case .end:   end = p
        case .control:
            if kind == .arrow { curveControl = p }
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // A callout scales its marker in step (see applyDisplayResize);
            // plain shapes just re-anchor on the opposite corner.
            if kind == .loupe, loupeSourceRect != nil {
                applyDisplayResize(handle: handle, to: p, aspectLocked: aspectLocked)
                return handle
            }
            let r = rect
            let anchor: CGPoint
            let direction: CGPoint   // the grabbed corner's side of the anchor
            switch handle {
            case .topLeft:
                anchor = CGPoint(x: r.maxX, y: r.maxY)
                direction = CGPoint(x: -1, y: -1)
            case .topRight:
                anchor = CGPoint(x: r.minX, y: r.maxY)
                direction = CGPoint(x: 1, y: -1)
            case .bottomLeft:
                anchor = CGPoint(x: r.maxX, y: r.minY)
                direction = CGPoint(x: -1, y: 1)
            case .bottomRight:
                anchor = CGPoint(x: r.minX, y: r.minY)
                direction = CGPoint(x: 1, y: 1)
            default: return handle
            }
            start = anchor
            // Shift locks the aspect for area shapes (a loupe's oval becomes
            // a circle, its rounded rect a square, a polygon/star regular).
            let lockAspect = aspectLocked
                && (kind == .rect || kind == .oval || kind == .loupe
                    || kind.isPathShape)
            let target = lockAspect ? Self.aspectLockedEnd(from: anchor, to: p) : p
            let (dx, crossedX) = Self.resolvedDelta(raw: target.x - anchor.x,
                                                    side: direction.x)
            let (dy, crossedY) = Self.resolvedDelta(raw: target.y - anchor.y,
                                                    side: direction.y)
            end = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
            if crossedY { flippedVertically.toggle() }
            return Self.mirroredCorner(handle, acrossX: crossedX, acrossY: crossedY)
        case .sourceTopLeft, .sourceTopRight, .sourceBottomLeft, .sourceBottomRight:
            applySourceResize(handle: handle, to: p, aspectLocked: aspectLocked)
        }
        return handle
    }

    /// One axis of a corner resize. `side` is the grabbed corner's side of
    /// the anchor (±1). Within ±minimumShapeSize of the anchor the corner
    /// clamps to the minimum size on its original side — a dead zone that
    /// keeps a shape from degenerating into a line and jitter from flipping
    /// it; beyond that the delta passes through and reports the crossing.
    private static func resolvedDelta(raw: CGFloat, side: CGFloat)
        -> (delta: CGFloat, crossed: Bool) {
        let along = raw * side
        if along >= minimumShapeSize { return (raw, false) }
        if along > -minimumShapeSize { return (side * minimumShapeSize, false) }
        return (raw, true)
    }

    /// The handle whose geometric role the grabbed corner assumes after the
    /// resize mirrored the shape across the anchor.
    private static func mirroredCorner(_ handle: Handle,
                                       acrossX: Bool, acrossY: Bool) -> Handle {
        var result = handle
        if acrossX {
            switch result {
            case .topLeft:     result = .topRight
            case .topRight:    result = .topLeft
            case .bottomLeft:  result = .bottomRight
            case .bottomRight: result = .bottomLeft
            default: break
            }
        }
        if acrossY {
            switch result {
            case .topLeft:     result = .bottomLeft
            case .bottomLeft:  result = .topLeft
            case .topRight:    result = .bottomRight
            case .bottomRight: result = .topRight
            default: break
            }
        }
        return result
    }

    /// Clamps a dragged corner to the grabbed side of its anchor, at least
    /// minimumShapeSize away — a loupe body never collapses or mirrors (a
    /// mirrored magnifier is meaningless, unlike a flipped polygon).
    private static func clampedCorner(_ p: CGPoint, anchor: CGPoint,
                                      direction: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x + direction.x * max(minimumShapeSize,
                                                direction.x * (p.x - anchor.x)),
                y: anchor.y + direction.y * max(minimumShapeSize,
                                                direction.y * (p.y - anchor.y)))
    }

    /// Resizes the magnifier from one of its corners, scaling the source
    /// marker by the same factors so the two frames keep their size ratio
    /// ("both drag together"). The magnifier re-anchors on its opposite
    /// corner; the marker scales about its own center, staying put.
    private mutating func applyDisplayResize(handle: Handle, to p: CGPoint,
                                             aspectLocked: Bool) {
        let old = rect
        let anchor: CGPoint
        let direction: CGPoint
        switch handle {
        case .topLeft:
            anchor = CGPoint(x: old.maxX, y: old.maxY)
            direction = CGPoint(x: -1, y: -1)
        case .topRight:
            anchor = CGPoint(x: old.minX, y: old.maxY)
            direction = CGPoint(x: 1, y: -1)
        case .bottomLeft:
            anchor = CGPoint(x: old.maxX, y: old.minY)
            direction = CGPoint(x: -1, y: 1)
        case .bottomRight:
            anchor = CGPoint(x: old.minX, y: old.minY)
            direction = CGPoint(x: 1, y: 1)
        default: return
        }
        start = anchor
        let lockAspect = aspectLocked
            && (kind == .rect || kind == .oval || kind == .loupe)
        let target = lockAspect ? Self.aspectLockedEnd(from: anchor, to: p) : p
        end = Self.clampedCorner(target, anchor: anchor, direction: direction)
        scaleLoupeSource(byWidth: old.width, height: old.height, from: rect)
    }

    /// Resizes the source marker from one of its corners, scaling the
    /// magnifier by the same factors so both frames keep their size ratio.
    /// The marker re-anchors on its opposite corner; the magnifier scales
    /// about its own center, staying put.
    private mutating func applySourceResize(handle: Handle, to p: CGPoint,
                                            aspectLocked: Bool) {
        guard kind == .loupe, let sourceRect = loupeSourceRect else { return }
        let anchor: CGPoint
        let direction: CGPoint
        switch handle {
        case .sourceTopLeft:
            anchor = CGPoint(x: sourceRect.maxX, y: sourceRect.maxY)
            direction = CGPoint(x: -1, y: -1)
        case .sourceTopRight:
            anchor = CGPoint(x: sourceRect.minX, y: sourceRect.maxY)
            direction = CGPoint(x: 1, y: -1)
        case .sourceBottomLeft:
            anchor = CGPoint(x: sourceRect.maxX, y: sourceRect.minY)
            direction = CGPoint(x: -1, y: 1)
        case .sourceBottomRight:
            anchor = CGPoint(x: sourceRect.minX, y: sourceRect.minY)
            direction = CGPoint(x: 1, y: 1)
        default: return
        }
        let locked = aspectLocked ? Self.aspectLockedEnd(from: anchor, to: p) : p
        let corner = Self.clampedCorner(locked, anchor: anchor, direction: direction)
        let newSource = CGRect(x: min(anchor.x, corner.x), y: min(anchor.y, corner.y),
                               width: abs(corner.x - anchor.x),
                               height: abs(corner.y - anchor.y))
        loupeSource = CGPoint(x: newSource.midX, y: newSource.midY)
        loupeSourceSize = newSource.size
        // Grow the magnifier by the same factors, about its own center,
        // never below the minimum size.
        let displayCenter = CGPoint(x: rect.midX, y: rect.midY)
        let kw = sourceRect.width > 0 ? newSource.width / sourceRect.width : 1
        let kh = sourceRect.height > 0 ? newSource.height / sourceRect.height : 1
        let half = CGSize(width: max(Self.minimumShapeSize, rect.width * kw) / 2,
                          height: max(Self.minimumShapeSize, rect.height * kh) / 2)
        start = CGPoint(x: displayCenter.x - half.width, y: displayCenter.y - half.height)
        end = CGPoint(x: displayCenter.x + half.width, y: displayCenter.y + half.height)
    }

    /// Scales the source marker by the width/height factors implied by the
    /// magnifier changing from `oldW`×`oldH` to `new`, keeping the marker
    /// centered where it is and never below the minimum size. No-op for an
    /// in-place loupe.
    private mutating func scaleLoupeSource(byWidth oldW: CGFloat, height oldH: CGFloat,
                                           from new: CGRect) {
        guard let size = loupeSourceSize else { return }
        let kw = oldW > 0 ? new.width / oldW : 1
        let kh = oldH > 0 ? new.height / oldH : 1
        loupeSourceSize = CGSize(width: max(Self.minimumShapeSize, size.width * kw),
                                 height: max(Self.minimumShapeSize, size.height * kh))
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
            if let source = a.loupeSource {
                a.loupeSource = rotatePoint(source, in: size, clockwise: clockwise)
            }
            if let markerSize = a.loupeSourceSize {
                a.loupeSourceSize = CGSize(width: markerSize.height,
                                           height: markerSize.width)
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

    /// Removes every freehand stroke in one undoable step — the eraser's
    /// "erase all". Other annotation kinds are untouched.
    func eraseAllFreehand() {
        guard annotations.contains(where: { $0.kind == .freehand }) else { return }
        beginChange()
        annotations.removeAll { $0.kind == .freehand }
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        commitChange()
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
