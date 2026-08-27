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

    // MARK: Landmarks

    /// Every anchor, in order — where the curves meet.
    var anchors: [CGPoint] {
        segments.compactMap { segment in
            switch segment {
            case .move(let p):          return p
            case .curve(_, _, let end): return end
            }
        }
    }

    /// The anchors where the outline turns a corner rather than flowing on.
    ///
    /// These are the mascot's landmarks: the tips of the ears, the notch
    /// between them, the shoulders. They are what a morph has to pair with each
    /// other — an ear tip must travel to an ear tip, not to whatever anchor
    /// happens to share its number.
    ///
    /// The first and last anchors are always landmarks: the outline is open,
    /// and its two ends are the one correspondence nothing can argue with.
    func corners(sharperThan degrees: CGFloat = 40) -> [Int] {
        let points = anchors
        guard points.count > 2 else { return Array(points.indices) }
        var found = [0]
        let limit = degrees * .pi / 180
        for index in 1..<(points.count - 1) {
            let incoming = direction(into: index)
            let outgoing = direction(outOf: index)
            guard let incoming, let outgoing else { continue }
            let turn = abs(atan2(incoming.x * outgoing.y - incoming.y * outgoing.x,
                                 incoming.x * outgoing.x + incoming.y * outgoing.y))
            if turn > limit { found.append(index) }
        }
        found.append(points.count - 1)
        return found
    }

    /// The direction a curve arrives at an anchor from, and leaves it in —
    /// taken from the control point beside it, falling back to the anchor
    /// before when a control sits exactly on top of its anchor.
    private func direction(into index: Int) -> CGPoint? {
        guard index > 0, index < segments.count,
              case .curve(let c1, let c2, let end) = segments[index] else { return nil }
        let from = c2 == end ? c1 : c2
        return normalised(CGPoint(x: end.x - from.x, y: end.y - from.y))
    }

    private func direction(outOf index: Int) -> CGPoint? {
        guard index + 1 < segments.count,
              case .curve(let c1, let c2, _) = segments[index + 1] else { return nil }
        let start = anchors[index]
        let to = c1 == start ? c2 : c1
        return normalised(CGPoint(x: to.x - start.x, y: to.y - start.y))
    }

    private func normalised(_ vector: CGPoint) -> CGPoint? {
        let length = hypot(vector.x, vector.y)
        guard length > 0.0001 else { return nil }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    // MARK: Agreement

    /// Every path given back with the same structure, and none of them moved —
    /// with the new points landing in the same *place on the outline* in each.
    ///
    /// This is the difference between a morph and a mess. Splitting each path's
    /// longest curve independently gives them all the same number of anchors,
    /// and pairs an ear of one with a skirt of another: on the way across, the
    /// ear is pulled sideways and grows a kink. So the outline is cut at its
    /// corners first — the tips of the ears, the notch, the shoulders, which
    /// every pose has in the same order — and the stretch between one corner
    /// and the next is subdivided to the same count in every pose. An ear then
    /// travels to an ear.
    ///
    /// A pose whose corners do not match the others' falls back to the plain
    /// agreement, which is at least a morph that runs.
    static func aligned(_ paths: [VectorPath]) -> [VectorPath] {
        guard paths.count > 1 else { return paths }
        let landmarks = paths.map { $0.corners(sharperThan: 60) }
        guard let count = landmarks.first?.count,
              landmarks.allSatisfy({ $0.count == count }), count > 1
        else { return agreeing(paths) }

        // How many curves each stretch needs: the most any pose spends on it,
        // so nothing is ever coarsened.
        var target: [Int] = []
        for stretch in 0..<(count - 1) {
            target.append(landmarks.map { $0[stretch + 1] - $0[stretch] }.max() ?? 1)
        }
        return paths.enumerated().map { index, path in
            path.subdividingStretches(at: landmarks[index], to: target)
        }
    }

    /// Cut at the landmarks, each stretch brought up to its target count.
    func subdividingStretches(at landmarks: [Int], to target: [Int]) -> VectorPath {
        let points = anchors
        guard let first = points.first, landmarks.count == target.count + 1 else { return self }
        var result: [Segment] = [.move(first)]
        for stretch in 0..<target.count {
            let from = landmarks[stretch], to = landmarks[stretch + 1]
            guard from < to, to < segments.count || to <= segments.count - 1 else { continue }
            let curves = Array(segments[(from + 1)...to])
            result += Self.subdivided(curves, from: points[from], to: target[stretch])
        }
        return VectorPath(segments: result)
    }

    /// One stretch of curves, split until there are `count` of them. The
    /// longest goes first, so the points that are added land where the drawing
    /// has the most room for them rather than crowding one corner.
    private static func subdivided(_ curves: [Segment], from start: CGPoint,
                                   to count: Int) -> [Segment] {
        var result = curves
        while result.count < count {
            var longest = 0
            var best: CGFloat = -1
            var cursor = start
            for (index, segment) in result.enumerated() {
                guard case .curve(let c1, let c2, let end) = segment else { continue }
                let length = hypot(c1.x - cursor.x, c1.y - cursor.y)
                    + hypot(c2.x - c1.x, c2.y - c1.y)
                    + hypot(end.x - c2.x, end.y - c2.y)
                if length > best { best = length; longest = index }
                cursor = end
            }
            guard case .curve(let c1, let c2, let end) = result[longest] else { break }
            var from = start
            for index in 0..<longest {
                if case .curve(_, _, let previous) = result[index] { from = previous }
            }
            let (a, b) = halved(from: from, c1, c2, end)
            result.replaceSubrange(longest...longest, with: [a, b])
        }
        return result
    }

    /// Every path given back with the same structure, and none of them moved.
    ///
    /// The plain version, kept as the fallback for drawings whose corners do
    /// not correspond: same count, no promise about where the new points land.
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
