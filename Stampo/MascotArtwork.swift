import CoreGraphics
import Foundation

/// The mascot's poses, exactly as Figma draws them.
///
/// Nine poses, three drawings: the rest are one of the three seen in a mirror
/// or standing a little lower. Kept as the `d` strings the export produced,
/// because a pose that changes then shows up in a review as the numbers that
/// changed — an SVG file in the bundle would be a thing nobody diffs.
///
/// Everything is in the artwork's own 12 × 12 box, y downward, which is how
/// Figma wrote it. The view puts it where it belongs.
nonisolated enum MascotArtwork {

    /// The box the poses are drawn in.
    static let side: CGFloat = 12

    /// Both ears up. The one every other pose is a variation of.
    static let earsUp = """
    M0.5 10.9264C0.500006 10.1761 0.500017 8.67614 0.875 7.92614C1.21502 7.24607 1.94562 \
    6.17614 3.50001 6.17614C3.50001 6.17614 0.437065 1.86015 2.50001 0.926142C3.94309 \
    0.272782 5.40816 1.63858 5.61304 3.20936L6.00001 6.17614L6.40981 2.76114C6.59401 \
    1.22618 8.09166 0.0385037 9.50001 0.676142C11.563 1.61015 8.50001 6.17614 8.50001 \
    6.17614C8.6513 6.17614 8.72694 6.17637 8.79178 6.17918C10.2832 6.24374 11.0357 \
    7.42614 11.25 8.17614C11.5357 9.17614 11.5 10.1764 11.5 10.9264
    """

    /// One ear folded over — the same silhouette with the left ear brought
    /// down. Drawn with two anchors more than `earsUp`, which is the whole
    /// reason `VectorPath.agreeing` exists.
    static let earFolded = """
    M0.5 11.4106C0.500006 10.6604 0.500017 9.16036 0.875 8.41036C1.21502 7.73028 1.94562 \
    6.66036 3.50001 6.66036L2.5 5.4108C0 5.4108 7.33137e-05 2.4108 1.99979 1.9108C3.69966 \
    1.48577 5.46336 2.546 5.68998 4.28348L6.00001 6.66036V2.76613C6.00001 1.28192 7.39793 \
    0.0486344 8.75001 0.660797C9.75666 1.11657 9.72136 2.55611 9.42128 3.9108C9.10641 \
    5.33229 8.50001 6.66036 8.50001 6.66036C8.6513 6.66036 8.72694 6.66059 8.79178 \
    6.66339C10.2832 6.72795 11.0357 7.91036 11.25 8.66036C11.5357 9.66036 11.5 10.6606 \
    11.5 11.4106
    """

    /// Ears wide, body low — the alert one. Three anchors more than `earsUp`.
    static let earsWide = """
    M0.5 11.2655C0.500006 10.5153 0.500017 9.0153 0.875 8.2653C1.21502 7.58523 1.94562 \
    6.5153 3.50001 6.5153L2.5 5.26574C2.38419e-07 5.26574 0.5 2.76491 1.49992 \
    2.26491C2.13241 1.94864 3.311 1.57574 4.50017 2.76491C5.68935 3.95409 6.00017 6.76491 \
    6.00017 6.76491C6.00017 6.76491 5.97587 5.03343 5.65728 3.88922C5.5388 3.4637 5.3886 \
    2.97121 5.23598 2.48907C4.89076 1.39848 5.69518 0.36206 6.82873 0.515757C8.06318 \
    0.683135 8.79178 1.56916 9 2.76491C9.20822 3.96067 8.50001 6.5153 8.50001 \
    6.5153C8.6513 6.5153 8.72694 6.51553 8.79178 6.51834C10.2832 6.58289 11.0357 7.7653 \
    11.25 8.5153C11.5357 9.5153 11.5 10.5155 11.5 11.2655
    """

    /// Which drawing a pose is made of, and what is done to it.
    struct Pose: Equatable {
        let name: String
        let drawing: String
        /// Seen in a mirror — and travelled backwards with it, so the anchors
        /// still describe the same ear in the same order. Mirrored alone, a
        /// pose pairs every point with the one across the axis and the morph
        /// walks the hare into a vertical line.
        var mirrored = false
        /// How far down the box it stands. Sleeping is the same drawing as
        /// awake, sitting 0.57 lower.
        var drop: CGFloat = 0
    }

    /// The nine, by the name each will answer to.
    static let poses: [Pose] = [
        Pose(name: "awake",        drawing: earsUp),
        Pose(name: "sleeping",     drawing: earsUp, drop: 0.5738),
        Pose(name: "earsWide",     drawing: earsWide),
        Pose(name: "earsWideLeft", drawing: earsWide, mirrored: true),
        Pose(name: "foldedRight",  drawing: earFolded),
        Pose(name: "foldedLeft",   drawing: earFolded, mirrored: true)
    ]

    /// Every pose as a path, all of them in agreement — same segments, same
    /// order, and each new anchor in the same place on the outline as its
    /// opposite number — so any one of them morphs into any other without an
    /// ear being pulled towards somebody's shoulder.
    static func agreeingPaths() -> [(name: String, path: VectorPath)] {
        let parsed = poses.map { pose -> (String, VectorPath) in
            guard var path = VectorPath.parse(pose.drawing.replacingOccurrences(of: "\n", with: "")) else {
                return (pose.name, VectorPath(segments: []))
            }
            if pose.mirrored { path = path.mirroredForMorphing(in: side) }
            if pose.drop != 0 {
                path = path.applying(CGAffineTransform(translationX: 0, y: pose.drop))
            }
            return (pose.name, path)
        }
        let agreed = VectorPath.aligned(parsed.map(\.1))
        return zip(parsed.map(\.0), agreed).map { (name: $0, path: $1) }
    }
}
