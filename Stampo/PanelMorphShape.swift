import SwiftUI
import CoreGraphics
import QuartzCore

// MARK: - PanelMorphShape
//
// 7 keyframes (Main + 5 transitions + Archive), built from corner radii by
// `PanelCorners.keyframe(height:flare:bottom:)`. progress 0.0→1.0
// interpolates between them pairwise. Each keyframe is a flat array of 84
// CGFloat values (42 points × 2 coordinates), of which the path reads 41.
// Point order is identical across all frames — only the coordinates change.

struct PanelMorphShape: Shape {
    var progress: CGFloat
    let pixel: CGFloat

    /// Points added below the archive's 89pt, for routes that need a taller
    /// body. Zero is the archive itself; the Translator's exported artwork is
    /// 79. Anything in between is a body sized to its own content.
    ///
    /// A number rather than a second set of keyframes, for two reasons. It
    /// animates — the archive and the Translator are both at `progress == 1`,
    /// so switching between them could not morph at all if the height lived in
    /// the frames. And a panel that fits its text needs every height in the
    /// range, not two of them.
    var extraHeight: CGFloat = 0

    /// Draw with `PanelCorners.wideShoulder` instead of the original 15pt, and
    /// keep the corners their size at any panel width rather than stretching
    /// them with it. Off is the shape exactly as it was before.
    var wideFlares: Bool = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, extraHeight) }
        set { progress = newValue.first; extraHeight = newValue.second }
    }

    /// How much of `extraHeight` has arrived at a given progress.
    ///
    /// The keyframes grow 34 → 45 → 56 → 67 → 78 → 89 → 89, so by frame *i*
    /// the panel has covered `i/5` of its climb while progress has covered
    /// `i/6`. Scaling by 6/5 and clamping makes the extra height land exactly
    /// in step with the drawn frames at every one of them, rather than lagging
    /// behind and snapping at the end.
    static func extraFactor(at progress: CGFloat) -> CGFloat {
        min(1, max(0, progress) * 6 / 5)
    }

    // 7 keyframes. Each is a flat array of path-point coordinates:
    // [x0,y0, cx1,cy1, cx2,cy2, x1,y1, ...] following SVG command order.
    // Path: M p0 → C p1,p2→p3 → C p4,p5→p6 → C p7,p8→p9 →
    //        L p10 → C p11,p12→p13 → C p14,p15→p16 → C p17,p18→p19 →
    //        L p20 →
    //        C p21,p22→p23 → C p24,p25→p26 → C p27,p28→p29 →
    //        L p30 → C p31,p32→p33 → C p34,p35→p36 → C p37,p38→p39 →
    //        L p40 → close
    // Total: 41 points = 82 values per keyframe, plus a trailing pair.

    /// Internal, not private, so the frames can be pinned by a test.
    static let archiveFrames: [[CGFloat]] = frames(shoulder: PanelCorners.shoulder)
    static let wideArchiveFrames: [[CGFloat]] = frames(shoulder: PanelCorners.wideShoulder)

    nonisolated private static func frames(shoulder: CGFloat) -> [[CGFloat]] {
        (0...6).map { i in
            // 34 → 89 in five equal steps; the last frame repeats the fifth.
            let height = 34 + 11 * CGFloat(min(i, 5))
            let reference = min(height, PanelCorners.ceiling)
            return PanelCorners.keyframe(
                height: height,
                flare: SmoothCorner(radius: PanelCorners.flareShare * reference,
                                    smoothing: PanelCorners.smoothing)
                    .fitting(shoulder),
                bottom: SmoothCorner(radius: PanelCorners.bottomShare * reference,
                                     smoothing: PanelCorners.smoothing),
                shoulder: shoulder
            )
        }
    }

    func path(in rect: CGRect) -> Path {
        let p = max(0, min(1, progress))
        let frames = wideFlares ? Self.wideArchiveFrames : Self.archiveFrames
        // Points 10…29 are the lower half of every frame: the two straight
        // sides and the bottom edge between them. Moving only those lengthens
        // the panel without touching a single corner radius.
        let drop = extraHeight * Self.extraFactor(at: p)

        let n = CGFloat(frames.count - 1)
        let scaled = p * n
        let i = min(Int(scaled), frames.count - 2)
        let t = scaled - CGFloat(i)

        let a = frames[i]
        let b = frames[i + 1]

        func lerp(_ ai: CGFloat, _ bi: CGFloat) -> CGFloat { ai + (bi - ai) * t }

        // Y is 1:1 — the frames are already in logical points. X is scaled to
        // the panel width (viewBox = 536), corners and all; with wide flares
        // the right half is shifted instead, so the corners keep their size and
        // only the straight top and bottom edges take up the difference.
        let sx = rect.width / 536
        func x(_ design: CGFloat) -> CGFloat {
            guard wideFlares else { return design * sx }
            return design <= 268 ? design : design + rect.width - 536
        }

        func pt(_ idx: Int) -> CGPoint {
            CGPoint(
                x: rect.minX + x(lerp(a[idx * 2], b[idx * 2])),
                y: rect.minY - pixel + lerp(a[idx * 2 + 1], b[idx * 2 + 1])
                    + ((10...29).contains(idx) ? drop : 0)
            )
        }

        var path = Path()
        path.move(to: pt(0))
        path.addCurve(to: pt(3),  control1: pt(1),  control2: pt(2))
        path.addCurve(to: pt(6),  control1: pt(4),  control2: pt(5))
        path.addCurve(to: pt(9),  control1: pt(7),  control2: pt(8))
        path.addLine(to: pt(10))
        path.addCurve(to: pt(13), control1: pt(11), control2: pt(12))
        path.addCurve(to: pt(16), control1: pt(14), control2: pt(15))
        path.addCurve(to: pt(19), control1: pt(17), control2: pt(18))
        path.addLine(to: pt(20))
        path.addCurve(to: pt(23), control1: pt(21), control2: pt(22))
        path.addCurve(to: pt(26), control1: pt(24), control2: pt(25))
        path.addCurve(to: pt(29), control1: pt(27), control2: pt(28))
        path.addLine(to: pt(30))
        path.addCurve(to: pt(33), control1: pt(31), control2: pt(32))
        path.addCurve(to: pt(36), control1: pt(34), control2: pt(35))
        path.addCurve(to: pt(39), control1: pt(37), control2: pt(38))
        path.addLine(to: pt(40))
        path.closeSubpath()
        return path
    }
}

// MARK: - PanelCorners

/// What the panel's corners are made of, in the 536-wide design space the
/// keyframes are drawn in.
nonisolated enum PanelCorners {
    /// Figma's corner smoothing at 60% — its "iOS" preset — on every corner of
    /// every frame. Only the radii change from frame to frame.
    static let smoothing: CGFloat = 0.6

    /// Corner radii as a share of the panel's height, from the macOS 27
    /// reference traced in the Stampo Figma file (node 1822:1072): 46 at the bottom and 32 at
    /// the flare, on a body 148 tall.
    static let bottomShare: CGFloat = 46.0 / 148
    static let flareShare: CGFloat = 32.0 / 148

    /// The height past which the corners stop growing: the shortest panel the
    /// shape is ever opened to, a one-line translation (34 + 40). There the
    /// shares give 23 and 16, the bottom corner still fits inside the
    /// translation's body, and anything taller — the archive, a longer
    /// translation — only lengthens the straight sides.
    static let ceiling: CGFloat = 74

    /// The band between the frame's edge and the straight side, which is all
    /// the room the flare has sideways. A flare that wants more keeps its
    /// smoothing and gives up radius: 15 / 1.6 ≈ 9.4, short of the reference's
    /// 16 at the ceiling. Past Main, every frame's flare is this one.
    static let shoulder: CGFloat = 15

    /// The shoulder of the widened panel (`NotchMetrics.wideFlares`): room for
    /// the reference's flare, 16 at 60% smoothing, which spans 25.6.
    static let wideShoulder: CGFloat = 26

    /// One keyframe: the four corners in path order — left flare, bottom left,
    /// bottom right, right flare — then the far end of the top edge and the
    /// trailing pair the path never reads.
    static func keyframe(height: CGFloat, flare: SmoothCorner, bottom: SmoothCorner,
                         shoulder: CGFloat = PanelCorners.shoulder) -> [CGFloat] {
        let width: CGFloat = 536
        let left = shoulder
        let right = width - shoulder

        var points: [CGPoint] = []
        points += flare.points(at: CGPoint(x: left, y: 0),
                               along: CGVector(dx: 1, dy: 0), toward: CGVector(dx: 0, dy: 1))
        points += bottom.points(at: CGPoint(x: left, y: height),
                                along: CGVector(dx: 0, dy: 1), toward: CGVector(dx: 1, dy: 0))
        points += bottom.points(at: CGPoint(x: right, y: height),
                                along: CGVector(dx: 1, dy: 0), toward: CGVector(dx: 0, dy: -1))
        points += flare.points(at: CGPoint(x: right, y: 0),
                               along: CGVector(dx: 0, dy: -1), toward: CGVector(dx: 1, dy: 0))
        points += [CGPoint(x: width, y: 0), CGPoint(x: 0, y: 0)]
        return points.flatMap { [$0.x, $0.y] }
    }
}

// MARK: - SmoothCorner

/// One corner the way Figma draws it with corner smoothing: the arc of a
/// circle of `radius` in the middle, eased into both straight edges by a cubic
/// on either side, so the curvature never jumps the way it does where a plain
/// rounded corner meets its edge. Smoothing 0 is that plain corner; the more
/// smoothing, the further along each edge the corner starts — `span` instead of
/// `radius` — and the shorter its circular middle.
///
/// The construction is Figma's (the figma-squircle derivation of it), and
/// `PanelMorphFrameTests` holds it against frames Figma itself exported.
nonisolated struct SmoothCorner: Sendable {
    var radius: CGFloat
    var smoothing: CGFloat

    /// How far along each edge the corner starts before the vertex.
    var span: CGFloat { (1 + smoothing) * radius }

    /// The same smoothing on a smaller radius, if this corner would need more
    /// than `room` along an edge.
    func fitting(_ room: CGFloat) -> SmoothCorner {
        span <= room ? self : SmoothCorner(radius: room / (1 + smoothing), smoothing: smoothing)
    }

    /// Ten points — a start, then three cubics as control, control, end — for
    /// the corner at `vertex`, reached travelling `along` and left travelling
    /// `toward`. Both are unit vectors.
    func points(at vertex: CGPoint, along e1: CGVector, toward e2: CGVector) -> [CGPoint] {
        let p = span
        // The circle keeps what the smoothing leaves of the quarter turn.
        let arc = CGFloat.pi / 2 * (1 - smoothing)
        let arcSide = sin(arc / 2) * radius * CGFloat(2).squareRoot()
        let angle = CGFloat.pi / 4 * smoothing
        let c = radius * tan(angle / 2) * cos(angle)
        let d = c * tan(angle)
        let b = (p - arcSide - c - d) / 3
        let a = 2 * b
        // Handle length of a cubic standing in for the arc.
        let k = 4 / 3 * tan(arc / 4) * radius
        let length = (c * c + d * d).squareRoot()
        let tangent: (u: CGFloat, v: CGFloat) = length > 0
            ? (u: c / length, v: d / length)
            : (u: 1, v: 0)

        // u runs along the first edge from where the corner starts, v along
        // the second. The corner is symmetric about its diagonal, so its second
        // half is the first mirrored, (u, v) → (p − v, p − u), in reverse.
        let arcStart: (u: CGFloat, v: CGFloat) = (u: a + b + c, v: d)
        let firstHalf: [(u: CGFloat, v: CGFloat)] = [
            (u: 0, v: 0), (u: a, v: 0), (u: a + b, v: 0), arcStart,
            (u: arcStart.u + k * tangent.u, v: arcStart.v + k * tangent.v),
        ]
        let secondHalf: [(u: CGFloat, v: CGFloat)] = firstHalf.reversed().map { (u: p - $0.v, v: p - $0.u) }
        let local = firstHalf + secondHalf

        // Placed from the vertex rather than from the start, so the points on
        // the second edge land on it exactly: (u − p) is zero there, not a
        // rounding error away from zero.
        return local.map { point in
            CGPoint(x: vertex.x + (point.u - p) * e1.dx + point.v * e2.dx,
                    y: vertex.y + (point.u - p) * e1.dy + point.v * e2.dy)
        }
    }
}
