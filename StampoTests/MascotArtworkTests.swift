import CoreGraphics
import Testing
@testable import Stampo

/// The mascot's own poses, brought into agreement.
///
/// This is the test that decides whether the animation is possible at all: a
/// morph pairs points by their place in the list, and the poses arrive from
/// Figma with twelve, fourteen and fifteen segments.
@Suite struct MascotArtworkTests {

    @Test func everyPoseIsADrawingThatCanBeRead() {
        for pose in MascotArtwork.poses {
            let d = pose.drawing.replacingOccurrences(of: "\n", with: "")
            #expect(VectorPath.parse(d) != nil, "\(pose.name) could not be read")
        }
    }

    /// The three drawings really do disagree — the reason the normaliser is
    /// here at all. If Figma ever ships them in agreement this fails, and the
    /// normaliser becomes a no-op rather than a mystery.
    @Test func theDrawingsArriveDisagreeing() throws {
        func structure(_ d: String) throws -> String {
            try #require(VectorPath.parse(d.replacingOccurrences(of: "\n", with: ""))).structure
        }
        let up = try structure(MascotArtwork.earsUp)
        let folded = try structure(MascotArtwork.earFolded)
        let wide = try structure(MascotArtwork.earsWide)
        #expect(up.count == 12)
        #expect(folded.count == 14)
        #expect(wide.count == 15)
        #expect(Set([up, folded, wide]).count == 3)
    }

    @Test func inAgreementEveryPoseCanMorphIntoEveryOther() {
        let paths = MascotArtwork.agreeingPaths()
        #expect(paths.count == MascotArtwork.poses.count)
        let structures = Set(paths.map(\.path.structure))
        #expect(structures.count == 1,
                "poses still disagree: \(paths.map { "\($0.name)=\($0.path.structure.count)" })")
        // At least as many curves as the busiest drawing arrived with — and
        // more is expected, not a fault: the count is the sum of what each
        // stretch between two corners needs, and no two poses spend their
        // anchors on the same stretches.
        #expect((paths.first?.path.curveCount ?? 0) >= 14)
    }

    /// Agreement may not redraw the mascot. Each pose is compared with the
    /// drawing it came from, measured as a drawing: every point of one lies on
    /// the other.
    @Test func agreementLeavesEveryPoseWhereItWas() throws {
        for (index, pose) in MascotArtwork.poses.enumerated() {
            var before = try #require(
                VectorPath.parse(pose.drawing.replacingOccurrences(of: "\n", with: "")))
            if pose.mirrored { before = before.mirrored(in: MascotArtwork.side) }
            if pose.drop != 0 {
                before = before.applying(CGAffineTransform(translationX: 0, y: pose.drop))
            }
            let after = MascotArtwork.agreeingPaths()[index].path
            #expect(apart(before, after) < 0.01, "\(pose.name) moved")
        }
    }

    /// Every pose stays inside the box it is drawn in — a pose that grew a
    /// point outside 12 × 12 would be clipped in the menu bar.
    @Test func everyPoseFitsItsBox() {
        for (name, path) in MascotArtwork.agreeingPaths() {
            let box = path.cgPath.boundingBoxOfPath
            #expect(box.minX >= -0.01 && box.minY >= -0.01, "\(name) starts outside the box")
            #expect(box.maxX <= MascotArtwork.side + 0.01, "\(name) is too wide")
            #expect(box.maxY <= MascotArtwork.side + 0.01, "\(name) is too tall")
        }
    }

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
                    nearest = min(nearest, distance(from: point, toEdgeBetween: others[index],
                                                    others[index + 1]))
                }
                return max(worst, nearest)
            }
        }
        return max(distance(from: firstSparse, to: secondDense),
                   distance(from: secondSparse, to: firstDense))
    }

    /// An ear travels to an ear.
    ///
    /// The point of aligning at the corners: after it, the anchor numbers mean
    /// the same thing in every pose. Splitting each drawing's longest curve
    /// instead gave them equal counts and paired an ear of one with the skirt
    /// of another — on the way across the ear was pulled sideways and grew a
    /// kink, which is what the sheet showed and what a count alone cannot see.
    @Test func theCornersOfEveryPoseLandOnTheSameAnchors() {
        let poses = MascotArtwork.agreeingPaths()
        let corners = poses.map { $0.path.corners(sharperThan: 60) }
        #expect(Set(corners.map { $0.description }).count == 1,
                "the poses' corners sit at different anchors: \(corners)")
        // Five of them: the two ends of the outline, the shoulder, and the ears.
        #expect(corners.first?.count == 5)
    }

    /// The anchors of every pose sit at the same places along the outline.
    ///
    /// This is the invariant that stops the wobble, and the one a count cannot
    /// express. Two poses whose shoulder is the same shape used to spend their
    /// anchors on it differently — one a third of the way along, the other
    /// almost at the corner — so the morph slid an anchor along an outline that
    /// was not changing, and dragged the curve out of shape as it went. Sharing
    /// the positions means an unchanging stretch has unchanging anchors.
    @Test func everyPoseKeepsItsAnchorsInTheSamePlacesAlongTheOutline() {
        let poses = MascotArtwork.agreeingPaths()
        guard let corners = poses.first?.path.corners(sharperThan: 60) else {
            Issue.record("no poses"); return
        }
        for stretch in 0..<(corners.count - 1) {
            let from = corners[stretch], to = corners[stretch + 1]
            let fractions = poses.map { pose -> [CGFloat] in
                let curves = Array(pose.path.segments[(from + 1)...to])
                return VectorPath.anchorFractions(of: curves, from: pose.path.anchors[from])
            }
            guard let first = fractions.first else { continue }
            for (index, other) in fractions.enumerated().dropFirst() {
                #expect(other.count == first.count,
                        "\(poses[index].name) has a different number of anchors on stretch \(stretch)")
                for (mine, theirs) in zip(first, other) {
                    #expect(abs(mine - theirs) < 0.05,
                            "\(poses[index].name) puts an anchor at \(theirs) where the first pose puts one at \(mine)")
                }
            }
        }
    }
}
