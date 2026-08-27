import CoreGraphics
import Foundation

/// A path as a list of segments, so that two of them can be made to agree.
///
/// CoreAnimation morphs one path into another by pairing their points in
/// order — the first with the first, the second with the second — so two
/// drawings of the same silhouette with different numbers of anchors cannot be
/// morphed at all. The mascot's poses come out of Figma exactly like that:
/// nine poses, three drawings, and structures of twelve, fourteen and fifteen
/// segments depending on how the ear was drawn that day.
///
/// The answer is not to make the designer count anchors. It is to bring the
/// paths into agreement here: every line becomes a curve, and the shorter paths
/// have their longest curves split in half until every path has the same number
/// of segments. Splitting a curve at its middle leaves the curve exactly where
/// it was — the shape does not move, it only gains a point to be paired with.
nonisolated struct VectorPath: Equatable {

    enum Segment: Equatable {
        case move(CGPoint)
        /// Control point one, control point two, and where the curve ends.
        case curve(CGPoint, CGPoint, CGPoint)
    }

    var segments: [Segment]

    init(segments: [Segment]) { self.segments = segments }

    // MARK: What it is made of

    var curveCount: Int {
        segments.reduce(0) { count, segment in
            if case .curve = segment { return count + 1 }
            return count
        }
    }

    /// The shape of the list rather than the shape it draws: "MCCCC…", which is
    /// what has to match before a morph is possible. Printed by the test that
    /// keeps every pose in agreement.
    var structure: String {
        segments.map { segment in
            if case .move = segment { return "M" }
            return "C"
        }.joined()
    }

    var start: CGPoint {
        if case .move(let point)? = segments.first { return point }
        return .zero
    }

    // MARK: Making one

    /// The subset of SVG the mascot's artwork uses: absolute and relative
    /// moves, lines, horizontal and vertical lines, cubic curves, and close.
    ///
    /// Written out rather than pulled in: the alternative was to ship the nine
    /// SVGs as resources and read them at launch, and then the artwork would be
    /// a file nobody diffs. As strings in the source, a pose that changes shows
    /// up in a review as the numbers that changed.
    static func parse(_ d: String) -> VectorPath? {
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t\r")
        var segments: [Segment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character = " "

        func number() -> CGFloat? {
            guard let value = scanner.scanDouble() else { return nil }
            return CGFloat(value)
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        /// A line, written as the curve it is: the control points sit on it, at
        /// a third and two thirds, so the drawn shape is identical.
        func line(to end: CGPoint) -> Segment {
            let dx = end.x - current.x, dy = end.y - current.y
            return .curve(CGPoint(x: current.x + dx / 3, y: current.y + dy / 3),
                          CGPoint(x: current.x + dx * 2 / 3, y: current.y + dy * 2 / 3),
                          end)
        }

        while !scanner.isAtEnd {
            if let letter = scanner.scanCharacters(from: CharacterSet.letters)?.first {
                command = letter
            } else if command == " " {
                return nil
            }
            let relative = command.isLowercase
            switch Character(command.uppercased()) {
            case "M":
                guard let p = point(relative: relative) else { return nil }
                segments.append(.move(p))
                current = p
                subpathStart = p
                // A second pair after a move is a line, as SVG says.
                command = relative ? "l" : "L"
            case "L":
                guard let p = point(relative: relative) else { return nil }
                segments.append(line(to: p))
                current = p
            case "H":
                guard let x = number() else { return nil }
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                segments.append(line(to: p))
                current = p
            case "V":
                guard let y = number() else { return nil }
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                segments.append(line(to: p))
                current = p
            case "C":
                guard let c1 = point(relative: relative),
                      let c2 = point(relative: relative),
                      let end = point(relative: relative) else { return nil }
                segments.append(.curve(c1, c2, end))
                current = end
            case "Z":
                if current != subpathStart {
                    segments.append(line(to: subpathStart))
                    current = subpathStart
                }
            default:
                return nil
            }
        }
        return segments.isEmpty ? nil : VectorPath(segments: segments)
    }

    // MARK: Moving it about

    func applying(_ transform: CGAffineTransform) -> VectorPath {
        VectorPath(segments: segments.map { segment in
            switch segment {
            case .move(let p):
                return .move(p.applying(transform))
            case .curve(let c1, let c2, let end):
                return .curve(c1.applying(transform), c2.applying(transform),
                              end.applying(transform))
            }
        })
    }

    /// The same drawing, flipped left to right inside a box of `width`.
    ///
    /// This alone is not enough to morph with. A mirror keeps the anchors in
    /// the order they were written, so every point's partner ends up directly
    /// across the axis — and a morph walks them all straight onto it: at
    /// halfway the hare is a vertical line. `mirroredForMorphing` is the one to
    /// pair with; this is the plain geometry it is built from.
    func mirrored(in width: CGFloat) -> VectorPath {
        applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -width, y: 0))
    }

    /// The mirror image, with its anchors put back in anatomical order.
    ///
    /// A mirror reverses which way the outline is travelled: a hare drawn from
    /// the left skirt up the left ear, across, and down to the right skirt
    /// becomes, in the mirror, one drawn from the right skirt up the right ear.
    /// Reversing that puts the left ear back at the start — so anchor for
    /// anchor the two poses now agree about *which ear is which*, and morphing
    /// between them lowers one ear while the other rises. Which is the whole
    /// point: the shape changes, the hare does not turn and does not melt.
    func mirroredForMorphing(in width: CGFloat) -> VectorPath {
        mirrored(in: width).reversed()
    }

    /// The same drawing, travelled backwards.
    ///
    /// Every curve is walked the other way — its two control points swap, and
    /// it ends where the one before it began — so the shape is identical and
    /// only the order of the anchors changes.
    func reversed() -> VectorPath {
        var anchors: [CGPoint] = []
        var controls: [(CGPoint, CGPoint)] = []
        for segment in segments {
            switch segment {
            case .move(let p):
                anchors.append(p)
            case .curve(let c1, let c2, let end):
                controls.append((c1, c2))
                anchors.append(end)
            }
        }
        guard anchors.count > 1 else { return self }
        var flipped: [Segment] = [.move(anchors[anchors.count - 1])]
        for index in stride(from: controls.count - 1, through: 0, by: -1) {
            let (c1, c2) = controls[index]
            flipped.append(.curve(c2, c1, anchors[index]))
        }
        return VectorPath(segments: flipped)
    }

    var cgPath: CGPath {
        let path = CGMutablePath()
        for segment in segments {
            switch segment {
            case .move(let p):
                path.move(to: p)
            case .curve(let c1, let c2, let end):
                path.addCurve(to: end, control1: c1, control2: c2)
            }
        }
        return path
    }

    // MARK: Agreement

    /// Every path given back with the same structure, and none of them moved.
    ///
    /// The longest curve is split first, so the points that are added land
    /// where the drawing has the most room for them rather than crowding one
    /// corner. Splitting is exact: a cubic cut at its middle is two cubics that
    /// draw the same line.
    static func agreeing(_ paths: [VectorPath]) -> [VectorPath] {
        guard let most = paths.map(\.curveCount).max() else { return paths }
        return paths.map { $0.split(toReach: most) }
    }

    func split(toReach count: Int) -> VectorPath {
        var result = segments
        var curves = curveCount
        while curves < count {
            guard let index = result.indices
                .filter({ if case .curve = result[$0] { return true } else { return false } })
                .max(by: { length(of: $0, in: result) < length(of: $1, in: result) })
            else { break }
            guard case .curve(let c1, let c2, let end) = result[index] else { break }
            let from = startPoint(of: index, in: result)
            let (first, second) = Self.halved(from: from, c1, c2, end)
            result.replaceSubrange(index...index, with: [first, second])
            curves += 1
        }
        return VectorPath(segments: result)
    }

    /// This path a fraction of the way to another, which is what CoreAnimation
    /// draws while it morphs: every control point moved in a straight line
    /// towards its opposite number.
    ///
    /// Reproduced here so the travel can be looked at — and tested — without
    /// asking the animation what it is about to do. Two paths that agree on
    /// their structure can still turn inside out on the way, if the anchors of
    /// one run round the outline in a different order from the other's, and
    /// that is invisible in the two ends.
    func interpolated(to other: VectorPath, at t: CGFloat) -> VectorPath? {
        guard segments.count == other.segments.count else { return nil }
        func between(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        var moved: [Segment] = []
        for (mine, theirs) in zip(segments, other.segments) {
            switch (mine, theirs) {
            case (.move(let a), .move(let b)):
                moved.append(.move(between(a, b)))
            case (.curve(let a1, let a2, let a3), .curve(let b1, let b2, let b3)):
                moved.append(.curve(between(a1, b1), between(a2, b2), between(a3, b3)))
            default:
                return nil   // structures disagree after all
            }
        }
        return VectorPath(segments: moved)
    }

    // MARK: Curve arithmetic

    /// De Casteljau at the middle: the two halves of a cubic, which together
    /// are the cubic.
    static func halved(from p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint)
        -> (Segment, Segment) {
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let p01 = mid(p0, p1), p12 = mid(p1, p2), p23 = mid(p2, p3)
        let p012 = mid(p01, p12), p123 = mid(p12, p23)
        let middle = mid(p012, p123)
        return (.curve(p01, p012, middle), .curve(p123, p23, p3))
    }

    private func startPoint(of index: Int, in segments: [Segment]) -> CGPoint {
        for i in stride(from: index - 1, through: 0, by: -1) {
            switch segments[i] {
            case .move(let p):            return p
            case .curve(_, _, let end):   return end
            }
        }
        return .zero
    }

    /// How long a segment is, near enough to choose the longest by: the
    /// distance from where it starts to where it ends, through its controls.
    private func length(of index: Int, in segments: [Segment]) -> CGFloat {
        guard case .curve(let c1, let c2, let end) = segments[index] else { return 0 }
        let from = startPoint(of: index, in: segments)
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }
        return distance(from, c1) + distance(c1, c2) + distance(c2, end)
    }

    /// A point on the path at `t` of the way along its curves — for the test
    /// that proves splitting does not move the drawing.
    func point(at t: CGFloat) -> CGPoint {
        let curves = segments.enumerated().compactMap { index, segment -> (CGPoint, CGPoint, CGPoint, CGPoint)? in
            guard case .curve(let c1, let c2, let end) = segment else { return nil }
            return (startPoint(of: index, in: segments), c1, c2, end)
        }
        guard !curves.isEmpty else { return start }
        let scaled = min(max(0, t), 1) * CGFloat(curves.count)
        let index = min(curves.count - 1, Int(scaled))
        let local = scaled - CGFloat(index)
        let (p0, p1, p2, p3) = curves[index]
        let u = 1 - local
        let x = u*u*u*p0.x + 3*u*u*local*p1.x + 3*u*local*local*p2.x + local*local*local*p3.x
        let y = u*u*u*p0.y + 3*u*u*local*p1.y + 3*u*local*local*p2.y + local*local*local*p3.y
        return CGPoint(x: x, y: y)
    }
}
