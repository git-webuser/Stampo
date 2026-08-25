import AppKit
import Observation

// MARK: - Annotation primitives

nonisolated enum AnnotationKind: Equatable, Sendable {
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
    /// A picture of the user's own, placed on the page beside the screenshot —
    /// a second shot for a before-and-after, a logo, anything droppable. Held
    /// by name like the background picture is: the annotation is a value that
    /// crosses into the export task, and the pixels live in the document.
    case picture

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
nonisolated enum BubbleTailDirection: String, Equatable, CaseIterable, Sendable {
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
nonisolated enum LineStyle: String, Equatable, CaseIterable, Sendable {
    case solid
    case dashed
}

/// Which endpoint of an `.arrow` receives a filled arrowhead.
nonisolated enum ArrowHeadPlacement: String, Equatable, CaseIterable, Sendable {
    case start
    case end
    case both

    var includesStart: Bool { self == .start || self == .both }
    var includesEnd: Bool { self == .end || self == .both }
}

enum BlurStyle: String, Equatable, CaseIterable, Sendable {
    case gaussian
    case pixelate
}

/// Persisted visual style of a freehand annotation. New drawing instruments
/// (pencil, brush, calligraphy pen) extend this enum without adding toolbar
/// buttons or changing the gesture model.
nonisolated enum FreehandStyle: String, Equatable, CaseIterable, Sendable {
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
nonisolated enum MarkerTip: String, Equatable, CaseIterable, Sendable {
    case round
    case square
}

/// Active instrument of the shared Drawing tool. Destructive erasing is a
/// separate top-level editor tool rather than a drawable annotation style.
nonisolated enum DrawingMode: String, Equatable, CaseIterable, Sendable {
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

/// Visual variant of an `.arrow`: the shaft is solid or dashed, both with the
/// same open (chevron) arrowhead. `filled` is the default. (Weight is the
/// thickness slider's job, so there's no separate "bold" style. The case name
/// is historical — the head is a stroked chevron, not a filled triangle.)
nonisolated enum ArrowStyle: String, Equatable, CaseIterable, Sendable {
    case filled   // solid shaft, open chevron head   (→)
    case dashed   // dashed shaft, open chevron head  (⇢)
}

/// How an `.arrow` gets from one end to the other — an axis independent of the
/// stroke's appearance (`ArrowStyle`).
nonisolated enum ArrowRoute: String, Equatable, CaseIterable, Sendable {
    /// A straight shaft, bendable into a quadratic curve via `curveControl`.
    case curved
    /// An axis-aligned ("elbowed") route with rounded corners, whose legs are
    /// slid on a grid; ignores `curveControl`.
    case elbowed
}

/// Backing plate drawn behind `.text` for legibility over busy images.
nonisolated enum TextBackground: String, Equatable, CaseIterable, Sendable {
    case none
    case dark
    case light
}

/// Paragraph alignment of a (multi-line) `.text` annotation.
nonisolated enum TextAlign: String, Equatable, CaseIterable, Sendable {
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
nonisolated enum LoupeShape: String, Equatable, CaseIterable, Sendable {
    case oval
    case roundedRect
}

/// Curated fonts available to text and numbering annotations (the same set
/// Telegram curates, plus SF Rounded and Times New Roman). Short enough for a
/// useful menu while covering neutral, rounded, typewriter, geometric, book,
/// classic, monospaced, handwritten, decorative, and script styles. Every
/// named family ships with macOS; all but Papyrus also include Cyrillic —
/// missing scripts render through the system-font fallback.
nonisolated enum AnnotationFontPreset: String, Equatable, CaseIterable, Identifiable, Sendable {
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
nonisolated enum TextStyleFlag: Equatable, CaseIterable, Sendable {
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
nonisolated struct BlurSource: Hashable, Sendable {
    var style: BlurStyle
    var level: Int
}

/// Color stored as sRGB components so Annotation stays Equatable/value-only.
nonisolated struct AnnotationColor: Equatable, Sendable {
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

/// How a bound arrow endpoint places itself on its target.
nonisolated enum AnchorSpec: Equatable, Sendable {
    /// A fixed point on the target's bounding rect, normalized 0…1 in each
    /// axis (0,0 top-left … 1,1 bottom-right). Every snapped anchor — an edge
    /// midpoint, a vertex, a point caught by the outline magnet, or the
    /// center — is stored this way, so it tracks the shape through resize.
    case fixed(unit: CGPoint)
}

/// A reference point on a shape an endpoint can snap to. Edge midpoints are
/// `visible` (drawn while dragging); vertices and the center are hidden snap
/// targets. `spec` is the binding this anchor creates (all are `.fixed(unit:)`
/// — edge, vertex, or the shape center); `point` is its current world position
/// (for snapping and drawing). `isCenter` marks the central connector, which
/// snaps within a small bullseye rather than by nearest-edge distance.
nonisolated struct ReferenceAnchor: Equatable, Sendable {
    var spec: AnchorSpec
    var point: CGPoint
    var isVisible: Bool
    var isCenter: Bool = false
}

/// Binds one endpoint of an `.arrow`/`.line` to a target annotation so the
/// endpoint follows the target as it moves or resizes. Value data on the
/// annotation itself — undo/redo/duplicate/rotate ride the existing snapshot
/// mechanism with zero synchronization. See `Docs/Stampo/ArrowBindingPlan.md`.
nonisolated struct EndpointBinding: Equatable, Sendable {
    /// Stable identity of the target shape.
    var targetID: UUID
    /// How the endpoint sits on the target's outline.
    var anchor: AnchorSpec
    /// Last successfully resolved point. Used when the target is gone
    /// (deleted) so the arrow holds its place instead of collapsing.
    var fallback: CGPoint
}

/// A single annotation. All geometry is in **image pixel coordinates**
/// with a top-left origin (y grows downward) — the view converts to and
/// from screen points through one fitScale factor, and export at native
/// pixel size needs no conversion at all.
nonisolated struct Annotation: Identifiable, Equatable, Sendable {
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
    /// Which picture a `.picture` annotation draws — the document holds the
    /// pixels under this name.
    var pictureID: UUID?
    /// How round a placed picture's corners are, as a fraction of its short
    /// side — the same rule the page uses for the screenshot's corners, so the
    /// two look like the same treatment when they sit side by side.
    var pictureCornerRadius: CGFloat = 0
    /// How strong the shadow under a placed picture is, 0…1. One number rather
    /// than four: a picture on a page wants the same shadow the screenshot has,
    /// only more or less of it, and the radius and offset follow from its size.
    var pictureShadow: CGFloat = 0
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
    /// Routing of an `.arrow`: a straight/curved shaft or an elbowed run.
    var arrowRoute: ArrowRoute = .curved
    /// Endpoint(s) that receive a filled arrowhead.
    var arrowHeadPlacement: ArrowHeadPlacement = .end
    /// Multiplier on the arrowhead's natural size (which follows the stroke).
    /// 1 is the size arrows have always drawn at, so old annotations and new
    /// ones agree until the slider is touched.
    var arrowHeadScale: CGFloat = 1
    /// Quadratic Bézier control point for a curved `.arrow`; nil is straight.
    /// Internal geometry only — the user grabs `bendHandle`, which rides the
    /// curve rather than this point.
    var curveControl: CGPoint? = nil
    /// True for an arrow that routes orthogonally (so it ignores
    /// `curveControl`, hides the bend handle, and offers per-leg sliders).
    var isElbowed: Bool { kind == .arrow && arrowRoute == .elbowed }

    /// Interior corners of an elbowed arrow's route, in image pixels. Empty
    /// means the route is auto-generated from the endpoints; dragging a leg's
    /// slider materializes the corners so the user's routing is preserved.
    var elbowWaypoints: [CGPoint] = []
    /// Binds the `start` endpoint of an `.arrow`/`.line` to a target shape;
    /// nil is a free endpoint (current behavior). Ignored on other kinds.
    var startBinding: EndpointBinding? = nil
    /// Binds the `end` endpoint of an `.arrow`/`.line` to a target shape.
    var endBinding: EndpointBinding? = nil
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
    /// Size of the callout marker.
    ///
    /// Marker, magnifier and `loupeScale` are one relationship, not three
    /// independent values: **the magnifier is the marked region drawn at
    /// `loupeScale`**, so `magnifier == marker × loupeScale` always holds. That
    /// is already what the renderer draws — it magnifies around the marker's
    /// centre by that factor — so letting the sizes drift apart made the marker
    /// outline promise one region while the glass showed another.
    /// `syncLoupeGeometry(anchoredTo:)` is what keeps the three in step.
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

    /// Which coordinate space this annotation is measured in.
    ///
    /// Blur and loupe read pixels *out of the picture* — a redaction that does
    /// not follow the image it hides stops hiding it — so they are measured in
    /// image pixels. Everything else is commentary on the page: it belongs to
    /// the canvas and must not move when the picture is scaled or nudged
    /// inside it. Without a presentation the two spaces are the same, which is
    /// why nothing about the plain editor changes.
    var livesInImageSpace: Bool { Self.kindLivesInImageSpace(kind) }

    /// The same rule before an annotation exists — the creation gesture has to
    /// know which space it is drawing in from the tool alone.
    static func kindLivesInImageSpace(_ kind: AnnotationKind) -> Bool {
        kind == .blur || kind == .loupe
    }

    /// Restores `magnifier == marker × loupeScale` after one of the three has
    /// changed, keeping the body named by `anchoredTo` exactly where it is and
    /// resizing the other about its own centre.
    ///
    /// - `.source` — the marker (or the factor) changed; the glass follows.
    /// - `.display` — the glass was resized; the marked region follows.
    ///
    /// No-op for an in-place loupe, which magnifies what is under itself and so
    /// has no second frame to agree with.
    mutating func syncLoupeGeometry(anchoredTo part: LoupePart) {
        guard kind == .loupe, loupeSource != nil, let sourceSize = loupeSourceSize
        else { return }
        let scale = max(1, loupeScale)
        switch part {
        case .source:
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let half = CGSize(width: max(Self.minimumShapeSize, sourceSize.width * scale) / 2,
                              height: max(Self.minimumShapeSize, sourceSize.height * scale) / 2)
            start = CGPoint(x: center.x - half.width, y: center.y - half.height)
            end = CGPoint(x: center.x + half.width, y: center.y + half.height)
        case .display:
            loupeSourceSize = CGSize(
                width: max(Self.minimumShapeSize, rect.width / scale),
                height: max(Self.minimumShapeSize, rect.height / scale)
            )
        }
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
        if isElbowed {
            let route = elbowRoute(start: start, end: end)
            if route.count >= 2 {
                let xs = route.map(\.x), ys = route.map(\.y)
                return CGRect(x: xs.min()!, y: ys.min()!,
                              width: xs.max()! - xs.min()!,
                              height: ys.max()! - ys.min()!)
            }
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
             .blur, .loupe, .picture:
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
            if isElbowed {
                let route = elbowRoute(start: start, end: end)
                return zip(route, route.dropFirst()).contains { a, b in
                    Self.distance(from: p, toSegment: a, b) <= distance
                }
            }
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
        case .text, .blur, .picture:
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

    /// Where the bend handle sits: on the curve itself, at its midpoint
    /// (t = 0.5), or the chord midpoint while the arrow is straight.
    ///
    /// Deliberately *not* the raw Bézier control. A quadratic's control lies
    /// twice as far off the chord as the curve it produces, so a bend drawn
    /// near an image edge would park its handle outside the image — where the
    /// clipped canvas can't draw it and the image-clamped pan can't reach it,
    /// stranding the user with an arrow they can only delete. Riding the curve
    /// keeps the handle wherever the stroke is visible, and makes the bend
    /// track the cursor exactly instead of at half its travel.
    var bendHandle: CGPoint {
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        guard kind == .arrow, !isElbowed, let control = curveControl else {
            return midpoint
        }
        // B(0.5) of a quadratic is the midpoint of chord-midpoint→control.
        return CGPoint(x: (midpoint.x + control.x) / 2,
                       y: (midpoint.y + control.y) / 2)
    }

    /// The control that puts the curve's midpoint on `p` — the inverse of
    /// `bendHandle`, so dragging the handle plants the bend under the cursor.
    static func control(forBendHandle p: CGPoint,
                        start: CGPoint, end: CGPoint) -> CGPoint {
        CGPoint(x: 2 * p.x - (start.x + end.x) / 2,
                y: 2 * p.y - (start.y + end.y) / 2)
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
            // An elbow arrow's shape comes from its route, not a bend.
            if isElbowed { return [(.start, start), (.end, end)] }
            // Control last so endpoint grabs win on tiny arrows. A straight
            // arrow offers it at the midpoint — dragging it bends the shaft.
            return [(.start, start), (.end, end), (.control, bendHandle)]
        case .line:
            return [(.start, start), (.end, end)]
        case .rect, .oval, .roundedRect, .polygon, .star, .bubble,
             .blur, .loupe, .picture:
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
        if !elbowWaypoints.isEmpty {
            elbowWaypoints = elbowWaypoints.map {
                CGPoint(x: $0.x + delta.x, y: $0.y + delta.y)
            }
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
            // `p` is a point on the curve (see `bendHandle`), not the control.
            if kind == .arrow {
                curveControl = Self.control(forBendHandle: p, start: start, end: end)
            }
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
        // The glass is the marked region at `loupeScale`, so it follows.
        syncLoupeGeometry(anchoredTo: .source)
    }

    /// Resizing the glass re-marks the region it shows: the marker becomes the
    /// new glass divided by `loupeScale`, centred where it already is. No-op for
    /// an in-place loupe.
    private mutating func scaleLoupeSource(byWidth oldW: CGFloat, height oldH: CGFloat,
                                           from new: CGRect) {
        syncLoupeGeometry(anchoredTo: .display)
    }

    // MARK: Arrow geometry (pure — unit-testable)

    /// Length of the filled arrowhead for a stroke width, times the
    /// annotation's own `arrowHeadScale`. A generous floor keeps the head
    /// clearly readable on thin arrows without scaling the whole annotation,
    /// while it still grows with thicker strokes. The scale multiplies the
    /// result rather than the floor, so a smaller head stays proportionate on
    /// a thin arrow instead of collapsing into the shaft.
    static func arrowheadLength(lineWidth: CGFloat, scale: CGFloat = 1) -> CGFloat {
        max(18, lineWidth * 3.5) * scale
    }

    /// The two barb points of the arrowhead for a shaft from `from` to `tip`.
    /// Head size scales with line width so thick arrows look proportionate.
    static func arrowheadBarbs(from: CGPoint, tip: CGPoint, lineWidth: CGFloat,
                               scale: CGFloat = 1)
        -> (CGPoint, CGPoint)
    {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let headLength = arrowheadLength(lineWidth: lineWidth, scale: scale)
        let spread: CGFloat = .pi / 7
        let b1 = CGPoint(x: tip.x - headLength * cos(angle - spread),
                         y: tip.y - headLength * sin(angle - spread))
        let b2 = CGPoint(x: tip.x - headLength * cos(angle + spread),
                         y: tip.y - headLength * sin(angle + spread))
        return (b1, b2)
    }

    // MARK: Elbow routing (pure — unit-testable)

    /// Outward direction implied by a bound endpoint's anchor: the normal of
    /// the bbox edge it sits on. nil when the anchor doesn't pick a side (a
    /// corner/vertex, or the center) or the endpoint is free — the
    /// router then derives a direction from the geometry.
    static func anchorDirection(_ binding: EndpointBinding?) -> CGPoint? {
        guard let binding, case .fixed(let u) = binding.anchor else { return nil }
        if u.x <= 0, u.y > 0, u.y < 1 { return CGPoint(x: -1, y: 0) }
        if u.x >= 1, u.y > 0, u.y < 1 { return CGPoint(x: 1, y: 0) }
        if u.y <= 0, u.x > 0, u.x < 1 { return CGPoint(x: 0, y: -1) }
        if u.y >= 1, u.x > 0, u.x < 1 { return CGPoint(x: 0, y: 1) }
        return nil
    }

    /// The dominant-axis direction from `from` toward `to` — the fallback exit
    /// direction for an endpoint whose anchor doesn't imply a side.
    private static func axisDirection(from: CGPoint, to: CGPoint) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        return abs(dx) >= abs(dy) ? CGPoint(x: dx < 0 ? -1 : 1, y: 0)
                                  : CGPoint(x: 0, y: dy < 0 ? -1 : 1)
    }

    /// The axis-aligned ("snake") route between two endpoints: each end leaves
    /// along its own direction, then the two runs meet on a shared mid-line.
    /// A bound end gets a `stub` so it clears its shape before turning; a free
    /// end turns immediately. Purely geometric — like Figma's elbow connector,
    /// it does not route around obstacles.
    static func elbowRoute(from s: CGPoint, startDirection ds: CGPoint?,
                           to e: CGPoint, endDirection de: CGPoint?,
                           stub: CGFloat = 24) -> [CGPoint] {
        let dsr = ds ?? axisDirection(from: s, to: e)
        let der = de ?? axisDirection(from: e, to: s)
        // Only a side-anchored end steps out before turning.
        let sStub = ds == nil ? 0 : stub
        let eStub = de == nil ? 0 : stub
        let p1 = CGPoint(x: s.x + dsr.x * sStub, y: s.y + dsr.y * sStub)
        let p2 = CGPoint(x: e.x + der.x * eStub, y: e.y + der.y * eStub)

        let startHorizontal = dsr.y == 0
        let endHorizontal = der.y == 0
        var middle: [CGPoint] = []
        switch (startHorizontal, endHorizontal) {
        case (true, true):
            let mid = (p1.x + p2.x) / 2
            middle = [CGPoint(x: mid, y: p1.y), CGPoint(x: mid, y: p2.y)]
        case (false, false):
            let mid = (p1.y + p2.y) / 2
            middle = [CGPoint(x: p1.x, y: mid), CGPoint(x: p2.x, y: mid)]
        case (true, false):
            middle = [CGPoint(x: p2.x, y: p1.y)]
        case (false, true):
            middle = [CGPoint(x: p1.x, y: p2.y)]
        }
        return simplifiedRoute([s, p1] + middle + [p2, e])
    }

    /// Drops repeated and collinear points so the route has one point per
    /// actual corner (corner rounding and hit-testing both rely on that).
    private static func simplifiedRoute(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last,
               abs(last.x - point.x) < 0.01, abs(last.y - point.y) < 0.01 {
                continue
            }
            if result.count >= 2 {
                let a = result[result.count - 2], b = result[result.count - 1]
                let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                if abs(cross) < 0.01 { result.removeLast() }   // b is collinear
            }
            result.append(point)
        }
        return result
    }

    /// Connects `p` to `q` with axis-aligned legs, leaving `p` along `axis`
    /// when a corner is needed. Returns the corner points between them.
    private static func orthogonalJoin(_ p: CGPoint, _ q: CGPoint,
                                       preferHorizontal: Bool) -> [CGPoint] {
        if abs(p.x - q.x) < 0.01 || abs(p.y - q.y) < 0.01 { return [] }
        return preferHorizontal ? [CGPoint(x: q.x, y: p.y)] : [CGPoint(x: p.x, y: q.y)]
    }

    /// This arrow's elbow route through the given endpoints. With no stored
    /// waypoints the route is generated from the endpoints and their anchors;
    /// otherwise it threads the user's corners, re-joining the (possibly moved)
    /// endpoints orthogonally. Empty unless the arrow is in elbow style.
    func elbowRoute(start s: CGPoint, end e: CGPoint) -> [CGPoint] {
        guard isElbowed else { return [] }
        let ds = Self.anchorDirection(startBinding)
        let de = Self.anchorDirection(endBinding)
        guard let first = elbowWaypoints.first,
              let last = elbowWaypoints.last else {
            return Self.elbowRoute(from: s, startDirection: ds,
                                   to: e, endDirection: de)
        }
        // Re-attach each end to its nearest waypoint, leaving along the
        // anchor's normal when it has one.
        let head = Self.orthogonalJoin(s, first,
                                       preferHorizontal: ds.map { $0.y == 0 }
                                           ?? (abs(first.x - s.x) >= abs(first.y - s.y)))
        let tail = Self.orthogonalJoin(e, last,
                                       preferHorizontal: de.map { $0.y == 0 }
                                           ?? (abs(last.x - e.x) >= abs(last.y - e.y)))
        return Self.simplifiedRoute([s] + head + elbowWaypoints + tail.reversed() + [e])
    }

    /// Quantizes `p` onto the lattice anchored at `origin`. Elbow endpoints use
    /// the *other* endpoint as the origin, so both ends and every leg share one
    /// lattice: a zero offset on an axis means exactly aligned, and adjusting an
    /// end can't leave sub-step jitter in the route.
    static func snappedToGrid(_ p: CGPoint, origin: CGPoint,
                              grid: CGFloat) -> CGPoint {
        guard grid > 1 else { return p }
        return CGPoint(x: origin.x + ((p.x - origin.x) / grid).rounded() * grid,
                       y: origin.y + ((p.y - origin.y) / grid).rounded() * grid)
    }

    /// Squares a nearly axis-aligned elbow arrow onto its axis by nudging a
    /// *free* endpoint, and drops stale waypoints. Without this an arrow whose
    /// ends differ by a few pixels can never render straight — the route has to
    /// jog between them — which reads as a permanent zigzag. Bound endpoints
    /// are left alone (their position belongs to the shape).
    mutating func alignForElbow(tolerance: CGFloat = 12) {
        guard isElbowed else { return }
        elbowWaypoints = []
        let dx = end.x - start.x, dy = end.y - start.y
        // Square up along whichever axis is already the near-aligned one.
        if abs(dx) <= tolerance, abs(dx) > 0, abs(dy) > abs(dx) {
            if endBinding == nil { end.x = start.x }
            else if startBinding == nil { start.x = end.x }
        } else if abs(dy) <= tolerance, abs(dy) > 0, abs(dx) > abs(dy) {
            if endBinding == nil { end.y = start.y }
            else if startBinding == nil { start.y = end.y }
        }
    }

    /// Midpoint of each leg of `route` — where the parallel-move sliders sit.
    static func routeSegmentMidpoints(_ route: [CGPoint]) -> [CGPoint] {
        zip(route, route.dropFirst()).map { a, b in
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }

    /// Slides leg `index` of `route` parallel to itself so it passes through
    /// `p`, and returns the route's new interior corners (to store as
    /// waypoints). The endpoints stay put — a leg touching an end grows a new
    /// corner there — and legs that collapse to zero length disappear via
    /// `simplifiedRoute`.
    ///
    /// `grid` is measured **from the arrow's own start**, not from absolute
    /// image coordinates, and any position within half a step of an endpoint's
    /// coordinate snaps exactly onto it. Otherwise the arrow could never be
    /// straightened: its endpoints sit wherever they were drawn, so an absolute
    /// grid would leave a permanent jog next to them.
    static func movingRouteSegment(_ route: [CGPoint], index: Int, to p: CGPoint,
                                   grid: CGFloat = 1) -> [CGPoint] {
        guard route.count >= 2, index >= 0, index < route.count - 1 else { return [] }
        guard let first = route.first, let last = route.last else { return [] }
        var points = route
        var i = index
        // Keep the anchored endpoints fixed by budding a new corner off them.
        if i == 0 {
            points.insert(points[0], at: 1)
            i += 1
        }
        if i + 1 == points.count - 1 {
            points.insert(points[points.count - 1], at: points.count - 1)
        }
        let a = points[i], b = points[i + 1]
        let isVertical = abs(a.x - b.x) < 0.01
        let value = isVertical ? p.x : p.y
        let origin = isVertical ? first.x : first.y
        let opposite = isVertical ? last.x : last.y
        // Align exactly with either endpoint when within half a step, so the
        // leg can collapse; otherwise step on the grid measured from the start.
        var snapped = origin + ((value - origin) / grid).rounded() * grid
        for alignment in [origin, opposite]
        where abs(value - alignment) <= grid / 2 {
            snapped = alignment
            break
        }
        if isVertical {
            points[i].x = snapped; points[i + 1].x = snapped
        } else {
            points[i].y = snapped; points[i + 1].y = snapped
        }
        let simplified = simplifiedRoute(points)
        guard simplified.count > 2 else { return [] }
        return Array(simplified.dropFirst().dropLast())
    }

    /// This arrow's elbow route in world space, with bound ends resolved.
    func elbowRoute(in annotations: [Annotation]) -> [CGPoint] {
        elbowRoute(start: resolvedStart(in: annotations),
                   end: resolvedEnd(in: annotations))
    }

    /// Maps `c` through the similarity (translation + rotation + uniform scale)
    /// that carries segment `fromStart`→`fromEnd` onto `toStart`→`toEnd`. Used
    /// to move a curved arrow's control with its resolved endpoints so the bend
    /// keeps its shape relative to the chord instead of drifting. A degenerate
    /// source chord falls back to translating by the start delta.
    static func mapControl(_ c: CGPoint, fromStart: CGPoint, fromEnd: CGPoint,
                           toStart: CGPoint, toEnd: CGPoint) -> CGPoint {
        let w = CGPoint(x: fromEnd.x - fromStart.x, y: fromEnd.y - fromStart.y)
        let denom = w.x * w.x + w.y * w.y
        guard denom > 1e-9 else {
            return CGPoint(x: c.x + (toStart.x - fromStart.x),
                           y: c.y + (toStart.y - fromStart.y))
        }
        let w2 = CGPoint(x: toEnd.x - toStart.x, y: toEnd.y - toStart.y)
        // Complex division w2 / w gives the scale-and-rotation factor.
        let ax = (w2.x * w.x + w2.y * w.y) / denom
        let ay = (w2.y * w.x - w2.x * w.y) / denom
        let rel = CGPoint(x: c.x - fromStart.x, y: c.y - fromStart.y)
        return CGPoint(x: toStart.x + ax * rel.x - ay * rel.y,
                       y: toStart.y + ax * rel.y + ay * rel.x)
    }

    /// The curve control for a bend drag to `p`, where `p` is where the user
    /// wants the curve itself to pass (the bend handle rides the curve — see
    /// `bendHandle`). nil (straight) when the drag lands within `snapDistance`
    /// of the straight start–end chord — a wide alignment band so a nearly
    /// straight bend snaps flat — or when `forceStraight` (Shift) is held.
    /// Measuring the band against the drag point rather than the control makes
    /// the band the width it looks like on screen. Pure for testing.
    static func bentControl(forDrag p: CGPoint, start: CGPoint, end: CGPoint,
                            snapDistance: CGFloat, forceStraight: Bool) -> CGPoint? {
        if forceStraight { return nil }
        guard distance(from: p, toSegment: start, end) > snapDistance else { return nil }
        return control(forBendHandle: p, start: start, end: end)
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

    // MARK: Arrow binding (pure resolver — unit-testable)

    /// Shapes an arrow endpoint can bind to. Closed regions with a meaningful
    /// interior and outline; open/degenerate kinds (line, arrow, freehand,
    /// text, step, blur, loupe) aren't binding targets.
    var isBindableTarget: Bool {
        switch kind {
        case .rect, .oval, .roundedRect, .polygon, .star, .bubble: return true
        default: return false
        }
    }

    /// The resolved position of the `start` endpoint: the bound point on the
    /// target, the binding's fallback if the target is gone, or the raw
    /// `start` when unbound. Pure — computed fresh each render/gesture, so
    /// moving a target makes the arrow follow with no stored derived state.
    func resolvedStart(in annotations: [Annotation]) -> CGPoint {
        resolved(binding: startBinding, rawSelf: start, in: annotations)
    }

    /// The resolved position of the `end` endpoint (the arrow's tip). See
    /// `resolvedStart(in:)`.
    func resolvedEnd(in annotations: [Annotation]) -> CGPoint {
        resolved(binding: endBinding, rawSelf: end, in: annotations)
    }

    /// Resolves one endpoint: the anchor's bbox-relative point on the target,
    /// so it follows the shape as it moves and resizes.
    private func resolved(binding: EndpointBinding?, rawSelf: CGPoint,
                          in annotations: [Annotation]) -> CGPoint {
        guard let binding else { return rawSelf }
        guard let target = annotations.first(where: { $0.id == binding.targetID }),
              target.isBindableTarget else { return binding.fallback }
        guard case .fixed(let unit) = binding.anchor else { return binding.fallback }
        let r = target.rect
        return CGPoint(x: r.minX + unit.x * r.width,
                       y: r.minY + unit.y * r.height)
    }

    /// The reference points an endpoint can snap to. Edge midpoints are the
    /// visible anchors; vertices are hidden snap targets. Derived from the real
    /// shape geometry, so a polygon/star recomputes with its side/point count.
    /// Empty for non-bindable kinds.
    func referenceAnchors() -> [ReferenceAnchor] {
        guard isBindableTarget else { return [] }
        let r = rect
        guard r.width > 0, r.height > 0 else { return [] }
        func anchor(_ unit: CGPoint, visible: Bool) -> ReferenceAnchor {
            ReferenceAnchor(spec: .fixed(unit: unit),
                            point: CGPoint(x: r.minX + unit.x * r.width,
                                           y: r.minY + unit.y * r.height),
                            isVisible: visible)
        }
        var result: [ReferenceAnchor]
        switch kind {
        case .oval:
            // No edges or vertices: the four extreme points, all shown.
            result = [anchor(CGPoint(x: 0.5, y: 0), visible: true),
                      anchor(CGPoint(x: 0.5, y: 1), visible: true),
                      anchor(CGPoint(x: 0, y: 0.5), visible: true),
                      anchor(CGPoint(x: 1, y: 0.5), visible: true)]
        case .rect, .roundedRect, .bubble:
            // Edge midpoints visible; the four corners are hidden vertices.
            let midpoints = [CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1),
                             CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)]
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                           CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            result = midpoints.map { anchor($0, visible: true) }
                + corners.map { anchor($0, visible: false) }
        case .polygon, .star:
            let vertices = kind == .polygon
                ? Self.polygonVertices(sides: polygonSides, in: r,
                                       flippedVertically: flippedVertically)
                : Self.starVertices(points: starPoints, in: r,
                                    flippedVertically: flippedVertically)
            guard vertices.count >= 2 else { return [] }
            func unit(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
            }
            result = []
            for (index, vertex) in vertices.enumerated() {
                let next = vertices[(index + 1) % vertices.count]
                let midpoint = CGPoint(x: (vertex.x + next.x) / 2,
                                       y: (vertex.y + next.y) / 2)
                result.append(anchor(unit(vertex), visible: false))  // vertex
                result.append(anchor(unit(midpoint), visible: true)) // edge mid
            }
        default:
            return []
        }
        // A hidden center connector: the endpoint lands on the shape's center
        // (bound, so it follows the shape) — an arrow pointing inside it.
        result.append(ReferenceAnchor(spec: .fixed(unit: CGPoint(x: 0.5, y: 0.5)),
                                      point: CGPoint(x: r.midX, y: r.midY),
                                      isVisible: false, isCenter: true))
        return result
    }

    /// A flattened, closed polyline of this shape's outline — for
    /// nearest-point snapping. Empty for non-bindable kinds.
    func outlinePolyline() -> [CGPoint] {
        guard isBindableTarget else { return [] }
        let r = rect
        guard r.width > 0, r.height > 0 else { return [] }
        switch kind {
        case .rect:
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.minY)]
        case .oval:
            let steps = 48
            var points = (0..<steps).map { index -> CGPoint in
                let t = 2 * .pi * CGFloat(index) / CGFloat(steps)
                return CGPoint(x: r.midX + r.width / 2 * cos(t),
                               y: r.midY + r.height / 2 * sin(t))
            }
            if let first = points.first { points.append(first) }
            return points
        default:
            return pathShapeOutline.map { Self.flatten($0) } ?? []
        }
    }

    /// The point on this shape's outline nearest to `p`. nil for non-bindable
    /// kinds.
    func nearestOutlinePoint(to p: CGPoint) -> CGPoint? {
        let polyline = outlinePolyline()
        guard polyline.count >= 2 else { return nil }
        var best: (point: CGPoint, distance: CGFloat)?
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let q = Self.closestPoint(on: a, b, to: p)
            let distance = hypot(p.x - q.x, p.y - q.y)
            if best == nil || distance < best!.distance { best = (q, distance) }
        }
        return best?.point
    }

    /// The closest point to `p` on segment a→b (clamped to the segment).
    static func closestPoint(on a: CGPoint, _ b: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq))
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }

    /// The anchor `p` snaps to, given a `magnet` catch distance:
    /// 1. a small central bullseye → the hidden center connector;
    /// 2. else the nearest edge/vertex reference within `magnet` — references
    ///    are the strongest snap;
    /// 3. else, within `magnet` of the outline, the nearest contour point (a
    ///    weaker whole-outline magnet that also reaches just outside the shape);
    /// 4. else nil — the interior between center and contour stays free.
    func nearestBindingAnchor(to p: CGPoint, magnet: CGFloat) -> ReferenceAnchor? {
        let anchors = referenceAnchors()
        guard !anchors.isEmpty else { return nil }
        let r = rect
        let centerDistance = hypot(p.x - r.midX, p.y - r.midY)
        if centerDistance <= min(r.width, r.height) * 0.16 {
            return anchors.first { $0.isCenter }
        }
        var bestReference: (anchor: ReferenceAnchor, distance: CGFloat)?
        for candidate in anchors where !candidate.isCenter {
            let distance = hypot(p.x - candidate.point.x, p.y - candidate.point.y)
            guard distance <= magnet else { continue }
            if bestReference == nil || distance < bestReference!.distance {
                bestReference = (candidate, distance)
            }
        }
        if let bestReference { return bestReference.anchor }
        if let near = nearestOutlinePoint(to: p),
           hypot(p.x - near.x, p.y - near.y) <= magnet {
            let unit = CGPoint(x: (near.x - r.minX) / r.width,
                               y: (near.y - r.minY) / r.height)
            return ReferenceAnchor(spec: .fixed(unit: unit), point: near,
                                   isVisible: false)
        }
        return nil
    }

    /// The curve control adjusted to the arrow's resolved endpoints. For an
    /// unbound arrow this is the stored control unchanged; for a bound one it
    /// rides the resolved chord (via `mapControl`) so the bend keeps its shape
    /// instead of drifting as the target moves. nil for a straight arrow.
    func resolvedControl(in annotations: [Annotation]) -> CGPoint? {
        guard let control = curveControl else { return nil }
        guard startBinding != nil || endBinding != nil else { return control }
        return Self.mapControl(control, fromStart: start, fromEnd: end,
                               toStart: resolvedStart(in: annotations),
                               toEnd: resolvedEnd(in: annotations))
    }

    /// A copy of a bound arrow/line with its endpoints (and curve control)
    /// baked to their resolved positions and the bindings cleared — so
    /// hit-testing and handle geometry operate on where the arrow is actually
    /// drawn. nil for kinds/instances without bindings (the caller uses the raw
    /// value directly).
    private func resolvedForInteraction(in annotations: [Annotation]) -> Annotation? {
        guard kind == .arrow || kind == .line,
              startBinding != nil || endBinding != nil else { return nil }
        var copy = self
        copy.curveControl = resolvedControl(in: annotations)
        copy.start = resolvedStart(in: annotations)
        copy.end = resolvedEnd(in: annotations)
        copy.startBinding = nil
        copy.endBinding = nil
        return copy
    }

    /// Hit-test that honors binding: a bound arrow/line is tested where it's
    /// drawn (endpoints on their targets), not at its stale raw endpoints.
    /// Unbound annotations fall through to the plain `hitTest`.
    func hitTest(_ p: CGPoint, tolerance: CGFloat, in annotations: [Annotation]) -> Bool {
        (resolvedForInteraction(in: annotations) ?? self).hitTest(p, tolerance: tolerance)
    }

    /// Draggable handles with bound endpoints at their resolved positions.
    func handles(in annotations: [Annotation]) -> [(Handle, CGPoint)] {
        (resolvedForInteraction(in: annotations) ?? self).handles
    }

    /// The handle near `p`, resolving bound endpoints first.
    func handle(at p: CGPoint, tolerance: CGFloat,
                in annotations: [Annotation]) -> Handle? {
        (resolvedForInteraction(in: annotations) ?? self).handle(at: p, tolerance: tolerance)
    }

    /// Flattens a CGPath into a polyline (curves subdivided, subpaths closed)
    /// so ray intersection sees exactly the rendered silhouette. Arcs already
    /// arrive as cubic curve elements from CoreGraphics.
    static func flatten(_ path: CGPath, segments: Int = 12) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                subpathStart = current
                points.append(current)
            case .addLineToPoint:
                current = element.points[0]
                points.append(current)
            case .addQuadCurveToPoint:
                let control = element.points[0], end = element.points[1]
                points.append(contentsOf:
                    quadraticPoints(from: current, control: control, to: end,
                                    segments: segments).dropFirst())
                current = end
            case .addCurveToPoint:
                let c1 = element.points[0], c2 = element.points[1]
                let end = element.points[2]
                points.append(contentsOf:
                    cubicPoints(from: current, control1: c1, control2: c2, to: end,
                                segments: segments).dropFirst())
                current = end
            case .closeSubpath:
                points.append(subpathStart)
                current = subpathStart
            @unknown default:
                break
            }
        }
        return points
    }

    /// Flattened polyline of a cubic Bézier — the cubic sibling of
    /// `quadraticPoints`, used to flatten rounded-rect and bubble arcs.
    static func cubicPoints(from: CGPoint, control1: CGPoint, control2: CGPoint,
                            to: CGPoint, segments: Int = 16) -> [CGPoint] {
        (0...segments).map { step in
            let t = CGFloat(step) / CGFloat(segments)
            let m = 1 - t
            let a = m * m * m, b = 3 * m * m * t, c = 3 * m * t * t, d = t * t * t
            return CGPoint(x: a * from.x + b * control1.x + c * control2.x + d * to.x,
                           y: a * from.y + b * control1.y + c * control2.y + d * to.y)
        }
    }
}

/// The four grab points of the picture's frame.
///
/// `nonisolated`, because it is pure geometry and `PresentationLayout` — which
/// is nonisolated by design, so preview and export can share it — asks a corner
/// where it is. The default isolation in this project is the main actor, so
/// without this the layout maths would be calling into it from outside.
nonisolated enum ImageCorner: CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeading: Bool { self == .topLeft || self == .bottomLeft }

    var opposite: ImageCorner {
        switch self {
        case .topLeft:     return .bottomRight
        case .topRight:    return .bottomLeft
        case .bottomLeft:  return .topRight
        case .bottomRight: return .topLeft
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: isLeading ? rect.minX : rect.maxX,
                y: isTop ? rect.minY : rect.maxY)
    }
}

// MARK: - Document history

/// One point-in-time snapshot of everything the undo stack must restore: the
/// annotations, the base image, and the rotation count. Carrying the image (by
/// reference — cheap for annotation-only edits that don't change it) is what
/// lets whole-image operations like crop and rotate be undone.
struct DocumentSnapshot: Equatable, Sendable {
    var annotations: [Annotation]
    var image: CGImage
    var rotationQuarters: Int
    var presentation: Presentation?

    static func == (lhs: DocumentSnapshot, rhs: DocumentSnapshot) -> Bool {
        lhs.rotationQuarters == rhs.rotationQuarters
            && lhs.image === rhs.image                 // identity: same image object
            && lhs.annotations == rhs.annotations
            && lhs.presentation == rhs.presentation
    }
}

/// Immutable value captured on the MainActor before a render/encode worker is
/// launched. It deliberately contains no editor/controller references.
nonisolated struct EditorRenderSnapshot: Sendable {
    let baseImage: CGImage
    let blurSources: [BlurSource: CGImage]
    /// The user's own pictures — the page's background and anything placed on
    /// it. Carried by the snapshot for the same reason the blurred copies are:
    /// the values name them, the document holds them, and the export task gets
    /// neither unless they are handed over.
    let pictures: [UUID: CGImage]
    let annotations: [Annotation]
    let revision: UInt64
    let format: String
    let presentation: Presentation?
}

/// Encoded output of a render. The bytes are safe to pass back to the
/// MainActor for pasteboard/share UI or to a background file writer.
nonisolated struct RenderedArtifact: Sendable {
    let data: Data
    let format: String
    let revision: UInt64
}

// MARK: - EditorDocument

/// The open image plus its annotations, selection, and undo history.
/// Same @Observable pattern as NotchArchiveModel.
@Observable final class EditorDocument {
    private(set) var baseImage: CGImage {
        didSet { revision &+= 1 }
    }
    let sourceURL: URL

    /// Revision of all user-visible render inputs. Selection changes are not
    /// included; annotation/base-image edits are. Save completion compares it
    /// with the captured artifact before marking the document clean.
    private(set) var revision: UInt64 = 0

    /// Net 90° turns applied to the image since open (mod 4). Part of the
    /// snapshot so a rotation alone still counts as a change.
    private var rotationQuarters = 0

    /// Pre-filtered full-size copies for the blur tool, keyed by style and
    /// intensity level and computed lazily off the main thread on first
    /// request. Until a source is ready, its blur annotations render as
    /// no-ops (a fraction of a second in practice).
    private(set) var blurSources: [BlurSource: CGImage] = [:]
    private var blurSourcesInFlight: Set<BlurSource> = []
    private var blurTasks: [BlurSource: Task<CGImage?, Never>] = [:]
    private(set) var imageRevision: UInt64 = 0

    /// The picture's own palette, sampled once per image.
    ///
    /// The decor panel reads it from `body`, which re-runs on every slider
    /// tick; sampling there meant a downsample plus a thousand `colorAt`
    /// conversions per frame on the main actor. The answer only changes when
    /// the image does, so it is kept against that image's identity — and kept
    /// out of observation, since filling a cache while a view is being built
    /// is not a change anything should redraw for.
    @ObservationIgnored private var sampledPaletteSource: CGImage?
    @ObservationIgnored private var sampledPaletteCache: [Presentation.Color] = []

    var sampledPalette: [Presentation.Color] {
        if let source = sampledPaletteSource, source === baseImage {
            return sampledPaletteCache
        }
        let colors = PresentationColorSampler.colors(from: baseImage)
        sampledPaletteCache = colors
        sampledPaletteSource = baseImage
        return colors
    }

    var annotations: [Annotation] = [] {
        didSet { revision &+= 1 }
    }
    /// Optional so an untouched document remains exactly the old image editor;
    /// setting nil to nil must not create a dirty state or a new revision.
    var presentation: Presentation? {
        didSet {
            if presentation != oldValue { revision &+= 1 }
        }
    }
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
                                              rotationQuarters: 0,
                                              presentation: nil)
    }

    func makeRenderSnapshot(format: String) -> EditorRenderSnapshot {
        EditorRenderSnapshot(
            baseImage: baseImage,
            blurSources: blurSources,
            pictures: pictures,
            annotations: annotations,
            revision: revision,
            format: format,
            presentation: presentation
        )
    }

    /// Everything the history restores, captured from live state.
    private var currentSnapshot: DocumentSnapshot {
        DocumentSnapshot(annotations: annotations, image: baseImage,
                         rotationQuarters: rotationQuarters,
                         presentation: presentation)
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
    /// cached nor already being computed. Every job carries the image revision
    /// it was created for; a completion from an older image is ignored and is
    /// not allowed to clear the in-flight state of a newer job.
    func prepareBlurSource(style: BlurStyle, level: Int) {
        let key = BlurSource(style: style, level: BlurIntensity.clamped(level))
        guard blurSources[key] == nil,
              !blurSourcesInFlight.contains(key),
              blurTasks[key] == nil
        else { return }

        blurSourcesInFlight.insert(key)
        let revision = imageRevision
        let base = baseImage

        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            return key.style == .pixelate
                ? AnnotationRenderer.makePixelated(base: base, level: key.level)
                : AnnotationRenderer.makeBlurred(base: base, level: key.level)
        }
        blurTasks[key] = task

        Task { @MainActor [weak self] in
            let image = await task.value
            guard let self else { return }

            // Only the generation that created this task may touch its cache or
            // release its in-flight marker. A stale completion must not affect a
            // newer job for the same style/level.
            guard self.imageRevision == revision else { return }
            self.blurTasks[key] = nil
            self.blurSourcesInFlight.remove(key)
            if let image { self.blurSources[key] = image }
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
        imageRevision &+= 1
        blurTasks.values.forEach { $0.cancel() }
        blurTasks.removeAll()
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
            if !a.elbowWaypoints.isEmpty {
                a.elbowWaypoints = a.elbowWaypoints.map {
                    rotatePoint($0, in: size, clockwise: clockwise)
                }
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

    /// Topmost annotation under the pointer (annotations later in the array
    /// draw on top, so search in reverse). Blur is a bottom redaction layer,
    /// so a non-blur annotation over it wins the hit even when the blur was
    /// added later.
    ///
    /// The pointer comes in **both** spaces, and each annotation is tested
    /// against the point (and tolerance) of the space it is measured in. Blur
    /// and loupe live in image pixels, everything else in canvas pixels;
    /// without a presentation the two are the same point and the same scale.
    func annotation(imagePoint: CGPoint, canvasPoint: CGPoint,
                    imageTolerance: CGFloat, canvasTolerance: CGFloat) -> Annotation? {
        func hits(_ a: Annotation) -> Bool {
            a.hitTest(a.livesInImageSpace ? imagePoint : canvasPoint,
                      tolerance: a.livesInImageSpace ? imageTolerance : canvasTolerance,
                      in: annotations)
        }
        return annotations.reversed().first { $0.kind != .blur && hits($0) }
            ?? annotations.reversed().first { $0.kind == .blur && hits($0) }
    }

    // MARK: Arrow binding

    /// Binds (or unbinds) one endpoint of an arrow/line at the release point
    /// `p`. A shape under `p` (topmost, excluding the arrow itself) snaps the
    /// endpoint to its nearest cardinal reference point — but only when `p` is
    /// toward that edge; a drop in the shape's interior (or on empty space)
    /// leaves the endpoint free, so an arrow can still point *inside* a shape.
    /// The fallback is the endpoint's current raw point (where the drag left
    /// it). Called inside the resize gesture's open change, so the bind is part
    /// of the same undo step as the endpoint drag.
    func bindEndpoint(_ handle: Annotation.Handle, of id: UUID,
                      releasedAt p: CGPoint, tolerance: CGFloat, magnet: CGFloat) {
        guard handle == .start || handle == .end,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].kind == .arrow || annotations[idx].kind == .line
        else { return }
        // Capture a shape when the drop is inside it or within the magnet band
        // of its outline. A deep-interior drop still captures (so it doesn't
        // fall through to a shape behind) but yields no anchor → free tip.
        let target = annotations.last { shape in
            shape.id != id && shape.isBindableTarget
                && (shape.hitTest(p, tolerance: tolerance, in: annotations)
                    || shape.nearestBindingAnchor(to: p, magnet: magnet) != nil)
        }
        let raw = handle == .start ? annotations[idx].start : annotations[idx].end
        let binding = target.flatMap { shape -> EndpointBinding? in
            guard let anchor = shape.nearestBindingAnchor(to: p, magnet: magnet)
            else { return nil }
            return EndpointBinding(targetID: shape.id,
                                   anchor: anchor.spec, fallback: raw)
        }
        if handle == .start { annotations[idx].startBinding = binding }
        else { annotations[idx].endBinding = binding }
    }

    /// Freezes every live binding's fallback at its current resolved point, so
    /// a target's removal leaves the arrow where it currently points instead of
    /// snapping back to a stale drop location. A no-op for a binding whose
    /// target is already gone (its resolve returns the existing fallback).
    func refreshBindingFallbacks() {
        for i in annotations.indices {
            guard annotations[i].kind == .arrow || annotations[i].kind == .line
            else { continue }
            // Resolve into locals first: reading `annotations` on the RHS while
            // mutating `annotations[i]` on the LHS of one statement is an
            // exclusive-access violation.
            if annotations[i].startBinding != nil {
                let resolved = annotations[i].resolvedStart(in: annotations)
                annotations[i].startBinding?.fallback = resolved
            }
            if annotations[i].endBinding != nil {
                let resolved = annotations[i].resolvedEnd(in: annotations)
                annotations[i].endBinding?.fallback = resolved
            }
        }
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
        presentation = snapshot.presentation
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
        // Freeze bound arrows at their current point before the target (which
        // might be this selection) disappears, so they hold place rather than
        // snapping to a stale fallback. Undo restores the target and the
        // pre-freeze fallbacks together via the snapshot.
        refreshBindingFallbacks()
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
    /// Starts a decoration on an undecorated document: a white page and the
    /// picture framed by `margin` canvas pixels, as one undo step. No-op once
    /// a decoration exists, so it can be called on every open of the panel.
    ///
    /// Deliberately *not* driven by the inspector appearing: SwiftUI builds
    /// `.inspector` content together with the editor, so an `onAppear` there
    /// fired at editor launch and decorated documents nobody had asked to
    /// decorate (measured: presentation set, document dirty, one undo entry,
    /// without a single click). The button that opens the panel is the event.
    func startDecorationIfNeeded(margin: CGFloat? = nil) {
        let margin = margin ?? Presentation.defaultMargin(for: pixelSize)
        guard presentation == nil, margin > 0 else { return }
        beginChange()
        // An auto page: the picture keeps every one of its own pixels and the
        // page grows around it by the margin, on all four sides equally.
        presentation = Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                                    background: .solid(.white))
        commitChange()
    }

    // MARK: Background pictures

    /// The user's own pictures, by the name that refers to them — a page's
    /// background and a picture placed on the page alike.
    ///
    /// Beside the picture rather than inside it, exactly as the blurred copies
    /// of the screenshot are: `Presentation` is a value that crosses into the
    /// export task and is compared on every undo step, and an image in it would
    /// be neither cheap to compare nor pleasant to carry. Undo therefore takes
    /// the *name* back and the pixels stay — which is what makes undoing a
    /// change of background instant rather than a second trip to the disk.
    private(set) var pictures: [UUID: CGImage] = [:]

    func picture(for id: UUID?) -> CGImage? {
        guard let id else { return nil }
        return pictures[id]
    }

    /// Kept, not owned: an undo that takes a picture off the page leaves the
    /// pixels here, so putting it back is instant rather than another trip to
    /// the disk. They go when the document does.
    func keepPicture(_ picture: CGImage, id: UUID) {
        pictures[id] = picture
    }

    /// Takes the file as the page's background, in one undo step.
    ///
    /// The one road in, used by the panel's file dialog and by a file dropped
    /// on the canvas alike: loading, keeping the pixels and naming them in the
    /// presentation are three things that must happen together or not at all.
    /// Returns false when the file is not an image anyone can read, which is
    /// the caller's cue to say so.
    @discardableResult
    func useBackgroundPicture(at url: URL) -> Bool {
        guard let picture = Self.picture(at: url) else { return false }
        beginChange()
        // Dropping a picture on an undecorated shot is a decision to decorate,
        // exactly as touching any other decor control is.
        startDecorationForEditing()
        let id = UUID()
        keepPicture(picture, id: id)
        // However the last picture met the page, this one meets it the same:
        // somebody who tiles textures is usually about to tile another.
        presentation?.background = .picture(id: id,
                                            backing: presentation?.background.colors.first ?? .white,
                                            fit: presentation?.background.pictureFit ?? .fill)
        commitChange()
        return true
    }

    /// Places a picture on the page, centred where it was dropped.
    ///
    /// It becomes an ordinary annotation, and that is the whole design: the
    /// canvas is where objects live and the panel is where the page is
    /// designed, so a picture brought to the canvas is a thing on the page —
    /// movable, resizable, deletable and annotatable like everything else —
    /// while the page's *background* is chosen in the panel. Two screenshots
    /// side by side with an arrow across them needs nothing else.
    ///
    /// Returns false when the file is not an image anyone can read.
    @discardableResult
    func placePicture(at url: URL, centredOn point: CGPoint, canvasSize: CGSize) -> Bool {
        guard let picture = Self.picture(at: url) else { return false }
        return placePicture(picture, centredOn: point, canvasSize: canvasSize)
    }

    /// The same, for pixels that never came from a file — the clipboard.
    @discardableResult
    func placePicture(_ picture: CGImage, centredOn point: CGPoint,
                      canvasSize: CGSize) -> Bool {
        let id = UUID()
        let size = Self.placedPictureSize(of: picture, on: canvasSize)
        beginChange()
        keepPicture(picture, id: id)
        var placed = Annotation(
            kind: .picture,
            start: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
            end: CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2),
            color: .red, lineWidth: 0
        )
        placed.pictureID = id
        annotations.append(placed)
        selectedID = placed.id
        commitChange()
        return true
    }

    /// The picture on the clipboard, if there is one.
    ///
    /// A copied *file* counts: Finder puts a URL on the pasteboard rather than
    /// the pixels, and to a person who copied a screenshot in Finder the two
    /// are the same act.
    nonisolated static func pictureOnPasteboard(
        _ pasteboard: NSPasteboard = .general
    ) -> CGImage? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let picture = urls.lazy.compactMap({ Self.picture(at: $0) }).first {
            return picture
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// How big a dropped picture arrives.
    ///
    /// Its own pixels, unless that would cover more than half the page: a
    /// screenshot dropped beside another is usually the same size as the one
    /// already there, and something enormous would land as a wall with no
    /// visible handles to shrink it by.
    nonisolated static func placedPictureSize(of picture: CGImage,
                                              on canvasSize: CGSize) -> CGSize {
        let size = CGSize(width: CGFloat(picture.width), height: CGFloat(picture.height))
        guard size.width > 0, size.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return size }
        let room = min(canvasSize.width * 0.5 / size.width,
                       canvasSize.height * 0.5 / size.height)
        let scale = min(1, room)
        return CGSize(width: (size.width * scale).rounded(),
                      height: (size.height * scale).rounded())
    }

    /// A picture read from a file, in the form the renderer draws.
    nonisolated static func picture(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    /// A decor control was used, so there is a decoration.
    ///
    /// «Remove Decor» leaves the document undecorated with the panel still
    /// open, and every setter below used to answer that state by doing nothing:
    /// margins took a number and dropped it, the canvas size could not be set
    /// at all, and the only way out was to close the panel and open it again.
    /// Touching one of these controls *is* the decision to decorate, exactly as
    /// pressing the decor button is.
    ///
    /// No undo step of its own: each caller either wraps one or is part of a
    /// gesture that does, and a second step here would make one action take two
    /// presses of ⌘Z.
    func startDecorationForEditing() {
        guard presentation == nil else { return }
        let margin = Presentation.defaultMargin(for: pixelSize)
        guard margin > 0 else { return }
        presentation = Presentation(canvas: .auto(margins: .init(all: margin), scale: 1),
                                    background: .solid(.white))
    }

    /// Puts the page into a ratio, as one undo step.
    ///
    /// The page is worked out from what is on screen — see `CanvasRatio.page` —
    /// so the picture keeps the size it is drawn at and only gains air. A
    /// format used to be a pixel size, which meant "Instagram 4:5" resampled a
    /// retina screenshot down to 1080 wide before anyone reached the export.
    func setCanvasRatio(_ ratio: CanvasRatio) {
        startDecorationForEditing()
        guard let presentation else { return }
        let layout = PresentationLayout.resolve(imagePixelSize: pixelSize, presentation)
        let page = CanvasRatio.page(for: ratio, in: layout)
        guard page.width > 0, page.height > 0 else { return }

        var updated = presentation
        updated.canvas = .preset(pixelSize: page)
        updated.image = CanvasRatio.placement(keepingDrawnSizeOf: layout,
                                              from: presentation.image,
                                              imagePixelSize: pixelSize,
                                              on: page)
        // A transparent canvas is a deliberate choice, not a starting point:
        // the first format a picture is given should show it on a real
        // background. `.fitted` is the placement nobody has touched yet.
        if presentation.image == .fitted, case .none = presentation.background {
            updated.background = .solid(.white)
        }
        guard updated != presentation else { return }
        beginChange()
        self.presentation = updated
        commitChange()
    }

    /// Sets one of the page's two numbers, as one undo step.
    ///
    /// Moved here from the inspector when the canvas controls went into the
    /// toolbar's second row; the rule is unchanged. On an auto page the size is
    /// still yours to set — the margins take up the difference and the picture
    /// is left alone. On a fixed page it simply sets that page's size.
    ///
    /// The equality guard is not an optimisation. A field writes its parsed
    /// value back as it appears, and without this the canvas changed the moment
    /// the row was merely drawn — measured, not supposed.
    func setCanvasDimension(_ dimension: CanvasDimension, to value: Int) {
        startDecorationForEditing()
        guard let presentation else { return }
        let safeValue = CGFloat(min(16384, max(1, value)))
        let live = PresentationLayout.resolve(imagePixelSize: pixelSize, presentation).canvasSize
        let current = dimension == .width ? live.width : live.height
        guard safeValue != current.rounded() else { return }

        var updated = presentation
        if case .auto(var margins, let scale) = presentation.canvas {
            let delta = safeValue - current
            if dimension == .width {
                let split = PresentationLayout.absorb(delta, into: margins.leading,
                                                      and: margins.trailing)
                margins.leading = split.near
                margins.trailing = split.far
            } else {
                let split = PresentationLayout.absorb(delta, into: margins.top,
                                                      and: margins.bottom)
                margins.top = split.near
                margins.bottom = split.far
            }
            updated.canvas = .auto(margins: margins, scale: scale)
        } else {
            var size = live
            if dimension == .width { size.width = safeValue } else { size.height = safeValue }
            updated.canvas = .preset(pixelSize: size)
        }
        guard updated != presentation else { return }
        beginChange()
        self.presentation = updated
        commitChange()
    }

    /// Hands the page back to its margins, as one undo step.
    ///
    /// Auto takes over exactly what is on screen — the margins *and* the size
    /// the picture was left at — so nothing moves when the format is dropped;
    /// ⌘Z is what goes back to the page before it. Rewinding to whatever Auto
    /// held earlier would move the picture under the cursor for no reason the
    /// user could see.
    func setAutoPage() {
        guard let presentation, case .preset = presentation.canvas else { return }
        let layout = PresentationLayout.resolve(imagePixelSize: pixelSize, presentation)
        let gaps = PresentationLayout.gaps(layout)
        let image = pixelSize
        guard image.width > 0, layout.imageRect.width > 0 else { return }

        var updated = presentation
        updated.canvas = .auto(
            margins: Presentation.Margins(top: gaps.top.rounded(),
                                          leading: gaps.leading.rounded(),
                                          bottom: gaps.bottom.rounded(),
                                          trailing: gaps.trailing.rounded()),
            scale: layout.imageRect.width / image.width
        )
        updated.image = .fitted
        guard updated != presentation else { return }
        beginChange()
        self.presentation = updated
        commitChange()
    }

    /// Sets one gap, from wherever the number came from — a field in the panel
    /// or the side of the picture being dragged on the canvas.
    ///
    /// On an auto page the margins *are* the page, so the gap is simply itself.
    /// On a fixed page there is a size to respect, so the picture resizes
    /// against the opposite edge — which is what dragging a side looks like
    /// anyway.
    ///
    /// Live, like `moveImage` and `resizeImage`: the undo step belongs to the
    /// gesture, and opening one here would push an entry per pointer sample.
    func setGap(_ edge: PresentationLayout.Edge, to value: CGFloat) {
        startDecorationForEditing()
        guard let presentation else { return }
        let canvasSize = PresentationLayout.resolve(imagePixelSize: pixelSize,
                                                    presentation).canvasSize
        if case .auto(var margins, let scale) = presentation.canvas {
            guard margins[edge] != value else { return }
            margins[edge] = value
            self.presentation?.canvas = .auto(margins: margins, scale: scale)
            return
        }
        let placement = PresentationLayout.placement(
            presentation.image, settingGap: edge, to: value,
            imagePixelSize: pixelSize, canvasSize: canvasSize, in: presentation
        )
        guard placement != presentation.image else { return }
        self.presentation?.image = placement
    }

    /// Live, for the same reason as `setGap`.
    func setCornerRadius(_ radius: CGFloat) {
        startDecorationForEditing()
        guard presentation != nil else { return }
        let clamped = min(0.5, max(0, radius.isFinite ? radius : 0))
        guard presentation?.cornerRadius != clamped else { return }
        presentation?.cornerRadius = clamped
    }

    /// Moves the picture on its canvas by a delta in canvas pixels — the same
    /// gesture as dragging an annotation, applied to the one object that is not
    /// one.
    ///
    /// The undo step belongs to the caller, exactly as it does for
    /// `resizeImage`: a drag calls this once per pointer sample, so opening and
    /// closing a change here would push one undo entry per mouse event and
    /// leave ⌘Z rewinding a single sample instead of the drag.
    func moveImage(by delta: CGPoint, canvasSize: CGSize) {
        guard var presentation, canvasSize.width > 0, canvasSize.height > 0,
              delta != .zero else { return }
        switch presentation.canvas {
        case .auto(var margins, let scale):
            // The page hugs the picture, so moving it trades one margin for the
            // opposite one: the page keeps its size and the picture slides
            // inside it, exactly as it does on a fixed page. A margin going
            // negative is the picture leaving the page, which is allowed.
            margins.leading += delta.x
            margins.trailing -= delta.x
            margins.top += delta.y
            margins.bottom -= delta.y
            presentation.canvas = .auto(margins: margins, scale: scale)
        case .preset:
            presentation.image.center.x += delta.x / canvasSize.width
            presentation.image.center.y += delta.y / canvasSize.height
        }
        self.presentation = presentation
    }

    /// Resizes the picture so `corner` lands on `point` (canvas pixels) while
    /// the opposite corner stays put. The aspect ratio is locked, so the drag
    /// is read along whichever axis moved further.
    func resizeImage(corner: ImageCorner, to point: CGPoint,
                     canvasSize: CGSize, imagePixelSize: CGSize) {
        guard var presentation, canvasSize.width > 0, canvasSize.height > 0,
              imagePixelSize.width > 0, imagePixelSize.height > 0 else { return }
        let resolved = PresentationLayout.resolve(imagePixelSize: imagePixelSize,
                                                  presentation)
        let rect = resolved.imageRect
        guard rect.width > 0, rect.height > 0 else { return }
        let anchor = corner.opposite.point(in: rect)
        let width = abs(point.x - anchor.x)
        let height = abs(point.y - anchor.y)
        // Locked aspect: the axis that travelled further wins, so the picture
        // never distorts and never snaps to the pointer's other coordinate.
        let factor = max(width / rect.width, height / rect.height)
        let newSize = CGSize(width: rect.width * factor, height: rect.height * factor)
        guard newSize.width >= 1, newSize.height >= 1 else { return }

        switch presentation.canvas {
        case .auto:
            // Resizing the picture leaves the page alone; the margins take up
            // the difference. That is the same thing that happens on a fixed
            // page, and it is what keeps the page from re-fitting itself under
            // the cursor while the corner is being dragged.
            let origin = CGPoint(x: corner.isLeading ? anchor.x - newSize.width : anchor.x,
                                 y: corner.isTop ? anchor.y - newSize.height : anchor.y)
            let margins = Presentation.Margins(
                top: origin.y,
                leading: origin.x,
                bottom: canvasSize.height - (origin.y + newSize.height),
                trailing: canvasSize.width - (origin.x + newSize.width)
            )
            presentation.canvas = .auto(margins: margins,
                                        scale: newSize.width / imagePixelSize.width)
        case .preset:
            let fit = min(canvasSize.width / imagePixelSize.width,
                          canvasSize.height / imagePixelSize.height)
            guard fit > 0 else { return }
            presentation.image.scale = newSize.width / (imagePixelSize.width * fit)
            let center = CGPoint(
                x: anchor.x + (corner.isLeading ? -newSize.width : newSize.width) / 2,
                y: anchor.y + (corner.isTop ? -newSize.height : newSize.height) / 2
            )
            presentation.image.center = CGPoint(x: center.x / canvasSize.width,
                                                y: center.y / canvasSize.height)
        }
        self.presentation = presentation
    }

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
