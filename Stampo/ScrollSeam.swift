import CoreGraphics
import Foundation

/// Where the seam between two frames of a scrolling capture falls.
///
/// In the middle of the overlap, as a rule: the earlier frame keeps the first
/// half, the later one gives the rest, and whatever a page does as it scrolls
/// into view is further on in the later frame. But an element that is still
/// appearing when the earlier frame is taken — a heading fading up and sliding
/// into place — can lie across the middle. Then the seam cuts it: the top of it
/// from the earlier frame, pale and a little low, the bottom from the later one.
///
/// So when the two frames disagree at the middle, the seam goes up to where
/// they agree again, if they agree there for a stretch (`runPoints`): the
/// element is then taken whole from the later frame. Rows are rows along the
/// scroll, whichever the axis: for a horizontal capture they are columns.
nonisolated enum ScrollSeam {
    /// What was chosen, and why it is where it is.
    struct Choice: Equatable {
        /// The rows of the later frame the earlier one keeps.
        let skip: Int
        let reason: Reason

        /// The seam in a few words: how far it rose, or that it stayed in the
        /// middle and why not.
        var summary: String {
            switch reason {
            case .middleAgrees: return "middle"
            case .moved(let rows): return "−\(rows) px"
            case .floor: return "middle (floor)"
            case .noRun: return "middle (no run)"
            case .details: return "middle (details)"
            }
        }

        /// For the log of a step. Nothing when the middle agreed, which is the
        /// usual seam.
        var note: String? {
            reason == .middleAgrees ? nil : "seam \(summary)"
        }
    }

    enum Reason: Equatable {
        /// The frames are the same page at the middle row.
        case middleAgrees
        /// The seam went up this many rows.
        case moved(Int)
        /// Nowhere to go: every row above the middle is under the floor, or
        /// disagrees.
        case floor
        /// Rows that agree above the middle, but never for `runPoints` in a row.
        case noRun
        /// A run was found, but the earlier frame has more in the band that
        /// the seam would skip than the later one: text would be lost.
        case details
    }

    /// A row of the later frame agrees with the earlier one's if the mean
    /// difference per channel, out of 255, is no more than this.
    static let tolerance: Float = 2
    /// Rows that agree in a row, in points, before the seam moves up to them.
    static let runPoints: CGFloat = 8
    /// The share of a row's pixels that stand still, on an edge, for the row
    /// to count as fixed to the viewport.
    static let fixedShare: Float = 0.01
    /// How much more detail the earlier frame may have in the skipped band
    /// than the later one before the seam stays where it was.
    static let detailsRatio: Float = 3

    /// The seam for `frame`, laid `movement` pixels along from `previous`.
    /// `previousSkip` is where the seam before this one fell in `previous`: this
    /// one never rises above it, so that only rows `previous` gave are replaced.
    static func choose(frame: CaptureFrame, after previous: CaptureFrame, axis: ScrollAxis,
                       movement: Int, previousSkip: Int, scale: CGFloat) -> Choice {
        let length = axis == .vertical ? frame.height : frame.width
        let overlap = length - movement
        let middle = overlap / 2
        guard previous.width == frame.width, previous.height == frame.height,
              movement > 0, overlap > 0
        else { return Choice(skip: max(0, middle), reason: .middleAgrees) }

        // A row is a line across the scroll; `along` steps from one to the
        // next and `across` along it, in bytes.
        let across = axis == .vertical ? frame.width : frame.height
        let along = axis == .vertical ? frame.width * 4 : 4
        let step = axis == .vertical ? 4 : frame.width * 4
        let run = max(1, Int((runPoints * scale).rounded()))

        return frame.pixels.withUnsafeBufferPointer { later in
            previous.pixels.withUnsafeBufferPointer { earlier in
                // Row `r` of the later frame is row `r + movement` of the earlier.
                // Rows are worked out when asked for: most seams ask for one.
                var differences = [Float](repeating: -1, count: overlap)

                func difference(_ r: Int) -> Float {
                    if differences[r] >= 0 { return differences[r] }
                    var total = 0
                    var i = r * along, j = (r + movement) * along
                    for _ in 0..<across {
                        total &+= abs(Int(later[i]) - Int(earlier[j]))
                            &+ abs(Int(later[i + 1]) - Int(earlier[j + 1]))
                            &+ abs(Int(later[i + 2]) - Int(earlier[j + 2]))
                        i += step; j += step
                    }
                    let value = Float(total) / Float(3 * across)
                    differences[r] = value
                    return value
                }

                func agrees(_ r: Int) -> Bool { difference(r) <= tolerance }

                /// The share of row `r`'s pixels that stand where they stood in
                /// the earlier frame, are not where the scroll would have put
                /// them, and lie on an edge: text, a border, a button of a bar
                /// that floats over the page. Blank ground agrees both ways
                /// and an edge-less blur is no one's.
                func standingShare(_ r: Int) -> Float {
                    var count = 0
                    var i = r * along, same = r * along, moved = (r + movement) * along
                    for x in 0..<across {
                        if abs(Int(later[i]) - Int(earlier[same])) <= 8,
                           abs(Int(later[i + 1]) - Int(earlier[same + 1])) <= 8,
                           abs(Int(later[i + 2]) - Int(earlier[same + 2])) <= 8,
                           !(abs(Int(later[i]) - Int(earlier[moved])) <= 8
                             && abs(Int(later[i + 1]) - Int(earlier[moved + 1])) <= 8
                             && abs(Int(later[i + 2]) - Int(earlier[moved + 2])) <= 8),
                           x + 1 < across {
                            let edge = max(abs(Int(later[i]) - Int(later[i + step])),
                                           abs(Int(later[i + 1]) - Int(later[i + step + 1])),
                                           abs(Int(later[i + 2]) - Int(later[i + step + 2])))
                            if edge > 24 { count += 1 }
                        }
                        i += step; same += step; moved += step
                    }
                    return Float(count) / Float(across)
                }

                /// How much there is to see in row `r` of a frame: the mean
                /// difference, per channel, between neighbours along the row.
                func detail(_ pixels: UnsafeBufferPointer<UInt8>, _ r: Int) -> Float {
                    var total = 0
                    var i = r * along
                    for _ in 0..<(across - 1) {
                        total &+= abs(Int(pixels[i]) - Int(pixels[i + step]))
                            &+ abs(Int(pixels[i + 1]) - Int(pixels[i + step + 1]))
                            &+ abs(Int(pixels[i + 2]) - Int(pixels[i + step + 2]))
                        i += step
                    }
                    return Float(total) / Float(3 * across)
                }

                if agrees(middle) { return Choice(skip: middle, reason: .middleAgrees) }

                // Not above the seam before, and not above a bar that stays
                // where it is while the page moves under it: that is the frame's
                // own, and laying the seam over it would put the bar in the image.
                var floorRow = max(0, previousSkip - movement)
                var fixed = middle - 1
                while fixed >= 0 && standingShare(fixed) < fixedShare { fixed -= 1 }
                if fixed >= 0 { floorRow = max(floorRow, fixed + 1) }

                var r = middle - 1
                var reason = Reason.floor
                while true {
                    while r >= floorRow && !agrees(r) { r -= 1 }
                    if r < floorRow { break }
                    let candidate = r
                    // Short stretches that agree, a line of an image that
                    // happens to be the same, are passed over.
                    var holds = true
                    for q in stride(from: candidate, to: candidate - run, by: -1) where q < floorRow || !agrees(q) {
                        holds = false
                        r = q
                        break
                    }
                    if holds {
                        // The band the seam skips: from below the candidate to
                        // the end of the disagreement that runs through the
                        // middle. If the earlier frame has the better part of
                        // the detail there, the later frame has not yet drawn
                        // it, and the middle is the better seam.
                        var end = middle
                        while end + 1 < overlap && !agrees(end + 1) { end += 1 }
                        var newDetail = Float(0), oldDetail = Float(0)
                        for q in (candidate + 1)...end {
                            newDetail += detail(later, q)
                            oldDetail += detail(earlier, q + movement)
                        }
                        if oldDetail > detailsRatio * max(newDetail, 0.001) {
                            reason = .details
                            break
                        }
                        return Choice(skip: candidate, reason: .moved(middle - candidate))
                    }
                    reason = .noRun
                    if r < floorRow { reason = .floor; break }
                }
                return Choice(skip: middle, reason: reason)
            }
        }
    }
}
