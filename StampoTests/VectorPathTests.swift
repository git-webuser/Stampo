import CoreGraphics
import Testing
@testable import Stampo

/// Bringing two drawings of the same silhouette into agreement, so that
/// CoreAnimation can morph one into the other.
///
/// The mascot's nine poses come out of Figma as three drawings with twelve,
/// fourteen and fifteen segments — the ear is drawn with a different number of
/// anchors in each. A morph pairs points by position in the list, so those
/// three cannot be morphed as they are, and asking the designer to count
/// anchors is a poor way to run a mascot.
@Suite struct VectorPathTests {

    private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.001) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    /// How far the two drawings are from each other, measured as a drawing
    /// rather than as a list.
    ///
    /// Not point-by-point at the same `t`: splitting a curve changes what `t`
    /// means — six curves divide the path into six, two divide it into two —
    /// so the same number lands somewhere else along the outline. What must
    /// hold is that every point of one path lies *on* the other.
    private func apart(_ a: VectorPath, _ b: VectorPath) -> CGFloat {
        // Sparse questions against a dense answer: the measure is bounded below
        // by how far a polyline's chords cut the corners it is standing in for,
        // so the path being measured *against* has to be drawn finely. At 300
        // points each, two of the mascot's poses read 0.04 apart when they are
        // the same drawing — the ear tips are where the chords cut.
        func polyline(_ path: VectorPath, _ count: Int) -> [CGPoint] {
            (0...count).map { path.point(at: CGFloat($0) / CGFloat(count)) }
        }
        let (firstSparse, firstDense) = (polyline(a, 200), polyline(a, 2000))
        let (secondSparse, secondDense) = (polyline(b, 200), polyline(b, 2000))
        // To the nearest *edge* rather than the nearest sample: point to point
        // can never read below half the sampling step, however dense the
        // sampling is, and would put a floor under the whole measurement.
        func distance(from point: CGPoint, toEdgeBetween a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
            let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
            return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
        }
        func distance(from points: [CGPoint], to others: [CGPoint]) -> CGFloat {
            points.reduce(0) { worst, point in
                var nearest = CGFloat.greatestFiniteMagnitude
                for index in others.indices.dropLast() {
                    nearest = min(nearest, distance(from: point,
                                                    toEdgeBetween: others[index],
                                                    others[index + 1]))
                }
                return max(worst, nearest)
            }
        }
        return max(distance(from: firstSparse, to: secondDense),
                   distance(from: secondSparse, to: firstDense))
    }

    @Test func itReadsTheSubsetOfSVGTheArtworkUses() throws {
        let path = try #require(VectorPath.parse(
            "M1 2C3 4 5 6 7 8L9 10V12H14Z"))
        #expect(path.start == CGPoint(x: 1, y: 2))
        // Every line arrives as a curve: one kind of segment is what makes two
        // paths comparable at all.
        // C, L, V, H and the line Z draws back to the start: five curves.
        #expect(path.structure == "MCCCCC")
        #expect(path.curveCount == 5)

        // The line's control points sit on it, so the drawing is unchanged: a
        // third and two thirds of the way from (7,8) to (9,10).
        guard case .curve(let c1, let c2, let end) = path.segments[2] else {
            Issue.record("the line did not become a curve"); return
        }
        #expect(near(c1, CGPoint(x: 7.667, y: 8.667)))
        #expect(near(c2, CGPoint(x: 8.333, y: 9.333)))
        #expect(end == CGPoint(x: 9, y: 10))
    }

    @Test func itReadsScientificNotationAndRelativeCommands() throws {
        // Figma writes 7.33137e-05 where a coordinate is nearly zero.
        let exponent = try #require(VectorPath.parse("M0 0C7.33137e-05 2.4108 1 2 3 4"))
        guard case .curve(let c1, _, _) = exponent.segments[1] else {
            Issue.record("no curve"); return
        }
        #expect(abs(c1.x - 0.0000733137) < 1e-9)

        let relative = try #require(VectorPath.parse("m10 10 l5 0"))
        #expect(relative.start == CGPoint(x: 10, y: 10))
        guard case .curve(_, _, let end) = relative.segments[1] else {
            Issue.record("no curve"); return
        }
        #expect(end == CGPoint(x: 15, y: 10))
    }

    @Test func nonsenseIsRefusedRatherThanGuessed() {
        #expect(VectorPath.parse("") == nil)
        #expect(VectorPath.parse("3 4 5") == nil)          // no command at all
        #expect(VectorPath.parse("M1 2C3 4 5") == nil)     // a curve short of numbers
    }

    /// The heart of it: a path split to reach more segments draws exactly the
    /// same shape. Splitting a cubic at its middle is two cubics that together
    /// are the cubic — the drawing does not move, it only gains a point for the
    /// morph to pair.
    @Test func splittingAddsPointsWithoutMovingTheDrawing() throws {
        let original = try #require(VectorPath.parse(
            "M0 0C0 5 5 10 10 10C15 10 20 5 20 0"))
        let split = original.split(toReach: 6)

        #expect(split.curveCount == 6)
        #expect(original.curveCount == 2)
        #expect(apart(original, split) < 0.01, "the shape moved")
    }

    @Test func pathsInAgreementShareOneStructure() throws {
        let twelve = try #require(VectorPath.parse(
            "M0 0C1 1 2 2 3 3C4 4 5 5 6 6"))
        let fourteen = try #require(VectorPath.parse(
            "M0 0C1 1 2 2 3 3L4 4C5 5 6 6 7 7"))
        let agreed = VectorPath.agreeing([twelve, fourteen])

        #expect(Set(agreed.map(\.structure)).count == 1, "they still disagree")
        #expect(agreed[0].curveCount == 3)
        // And each of them still draws what it drew.
        for (before, after) in zip([twelve, fourteen], agreed) {
            #expect(apart(before, after) < 0.01, "agreeing moved a drawing")
        }
    }

    /// Three of the nine poses are another pose seen in a mirror. Mirroring in
    /// code keeps one drawing and keeps its anchors running the same way round
    /// the outline — the order a morph pairs.
    @Test func aMirroredPathIsTheSamePathBackwards() throws {
        let path = try #require(VectorPath.parse("M0 0C1 1 2 2 3 3"))
        let mirrored = path.mirrored(in: 12)
        #expect(mirrored.start == CGPoint(x: 12, y: 0))
        #expect(mirrored.structure == path.structure)
        #expect(mirrored.mirrored(in: 12) == path, "mirroring twice is not the original")
    }
}
