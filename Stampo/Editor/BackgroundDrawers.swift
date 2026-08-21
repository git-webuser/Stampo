import CoreGraphics

/// What each kind of background held when it was last left.
///
/// The panel offers four drawers — solid, linear, radial, mesh — and switching
/// between them used to *convert*: a four-stop gradient became four corners,
/// and coming back gave two stops derived from those corners. The work was
/// gone, and gone in a way that looked like a reset.
///
/// Conversion is still what happens the first time a drawer is opened —
/// arriving in a mesh with nothing in it should not mean arriving at black —
/// but it never happens twice for the same drawer.
///
/// Deliberately a value the panel holds in its own state: this is the inspector
/// remembering what you were doing a minute ago, not the document carrying four
/// backgrounds around. Closing the editor forgets it, and nothing is written
/// anywhere.
nonisolated struct BackgroundDrawers: Sendable {
    enum Drawer: Hashable, Sendable {
        case solid, linear, radial, mesh

        var isGradient: Bool { self != .solid }
    }

    private var remembered: [Drawer: Presentation.Background] = [:]
    /// Which gradient the "Gradient" tile returns to — the one you were last
    /// in, not a linear one you may never have chosen.
    private(set) var lastGradient: Drawer = .linear

    init() {}

    /// The drawer a background belongs to. Transparent belongs to none: there
    /// is nothing in it to keep.
    static func drawer(of background: Presentation.Background) -> Drawer? {
        switch background {
        case .none:            return nil
        case .solid:           return .solid
        case .linearGradient:  return .linear
        case .radialGradient:  return .radial
        case .mesh:            return .mesh
        }
    }

    /// Puts `background` away under its own drawer.
    mutating func keep(_ background: Presentation.Background) {
        guard let drawer = Self.drawer(of: background) else { return }
        remembered[drawer] = background
        if drawer.isGradient { lastGradient = drawer }
    }

    /// The background to show when the user opens `drawer`, having been in
    /// `background`: what was left there, or — the first time — the colours on
    /// screen rearranged for the new shape.
    mutating func switching(from background: Presentation.Background,
                            to drawer: Drawer,
                            angle: CGFloat) -> Presentation.Background {
        keep(background)
        if drawer.isGradient { lastGradient = drawer }
        return remembered[drawer] ?? Self.converted(background, to: drawer, angle: angle)
    }

    func kept(_ drawer: Drawer) -> Presentation.Background? { remembered[drawer] }

    /// What a drawer starts out as when it has never been opened.
    static func converted(_ background: Presentation.Background,
                          to drawer: Drawer,
                          angle: CGFloat) -> Presentation.Background {
        let colors = background.colors
        let stops = background.stops.count >= 2
            ? background.stops
            : Presentation.Stop.spread(colors.count >= 2 ? colors : defaultStops)
        switch drawer {
        case .solid:
            return .solid(colors.first ?? .white)
        case .linear:
            return .linearGradient(stops: stops, angle: angle)
        case .radial:
            return .radialGradient(stops: stops)
        case .mesh:
            // The colours carry across: two stops become the two ends of a
            // four-corner spread rather than being thrown away. Their positions
            // do not — a mesh's corners sit in a square, and there is no line
            // for them to sit along.
            return .mesh(colors: meshCorners(from: stops.map(\.color)))
        }
    }

    /// The blue pair a gradient starts from when there is nothing to carry.
    static let defaultStops: [Presentation.Color] = [
        Presentation.Color(red: 0.36, green: 0.55, blue: 0.98, alpha: 1),
        Presentation.Color(red: 0.09, green: 0.13, blue: 0.36, alpha: 1)
    ]

    /// Two colours spread over four corners: the ends keep theirs and the other
    /// two are the blend, so a line turned into a mesh keeps what the user had
    /// rather than starting over.
    static func meshCorners(from colors: [Presentation.Color]) -> [Presentation.Color] {
        guard let first = colors.first else {
            return Array(repeating: Presentation.Color.white, count: 4)
        }
        if colors.count >= 4 { return Array(colors.prefix(4)) }
        let last = colors.last ?? first
        let middle = GradientStops.blend(first, last, amount: 0.5)
        return [first, middle, middle, last]
    }
}
