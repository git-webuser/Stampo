import Foundation

nonisolated enum ScrollBackgroundFilter {
    /// Remove a smooth viewport background without erasing the edges that
    /// identify scrolling text. The clipped box keeps small frames well defined.
    static func highPass(_ frame: CaptureFrame, radius: Int) -> CaptureFrame {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0 else { return frame }
        let r = min(max(0, radius), max(w, h))
        let stride = w + 1
        var output = frame.pixels
        // Reuse one channel's summed-area table to bound the working memory.
        var integral = [Int](repeating: 0, count: stride * (h + 1))
        for channel in 0..<3 {
            for y in 0..<h {
                var row = 0
                for x in 0..<w {
                    row += Int(frame.pixels[(y * w + x) * 4 + channel])
                    integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
                }
            }
            for y in 0..<h {
                let y0 = max(0, y - r), y1 = min(h, y + r + 1)
                for x in 0..<w {
                    let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                    let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1]
                        - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                    let mean = Double(sum) / Double((x1 - x0) * (y1 - y0))
                    let index = (y * w + x) * 4 + channel
                    output[index] = UInt8(max(0, min(255, (128 + Double(frame.pixels[index]) - mean).rounded())))
                }
            }
        }
        // Alpha and the color profile belong to the capture, not its background.
        return CaptureFrame(width: w, height: h, pixels: output, colorSpace: frame.colorSpace)
    }
}

nonisolated enum ScrollSecondLook {
    struct Result: Sendable {
        var match: FrameMatch?
        var evidence: FrameMatcher.StepEvidence
        var note: String
    }

    /// Called only after an undecided matcher refusal. A calibrated vertical
    /// step with silent raw tiles is the only one that needs another view.
    static func inspect(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                        maximumOffset: Int, searchLimit: Int, expected: Int?, radius: Int,
                        raw: FrameMatcher.StepEvidence) -> Result {
        guard axis == .vertical, let expected, raw.consistent == 0, raw.against == 0 else {
            return Result(evidence: raw, note: "")
        }
        let before = ScrollBackgroundFilter.highPass(previous, radius: radius)
        let after = ScrollBackgroundFilter.highPass(current, radius: radius)
        if let match = try? FrameMatcher.match(previous: before, current: after, axis: axis,
                                               maximumOffset: maximumOffset),
           abs(match.offset - expected) <= FrameMatcher.nearRange(of: expected) {
            return Result(match: match, evidence: raw, note: " · second look: match \(match.offset)")
        }
        let filtered = FrameMatcher.evidence(previous: before, current: after, axis: axis,
                                              offset: expected, searchLimit: searchLimit)
        let evidence = addingSupport(from: filtered, to: raw)
        let supporting = filtered.contradicted ? 0 : filtered.consistent
        return Result(evidence: evidence, note: " · second look: \(supporting) tiles for")
    }

    static func addingSupport(from filtered: FrameMatcher.StepEvidence,
                              to raw: FrameMatcher.StepEvidence) -> FrameMatcher.StepEvidence {
        // Removing the background can add proof of motion, never a reason to
        // retry: the raw pixels alone retain the right to contradict a step.
        let consistent = filtered.contradicted ? raw.consistent : max(raw.consistent, filtered.consistent)
        return .init(standing: raw.standing, consistent: consistent, against: raw.against,
                     contradicted: raw.contradicted, near: raw.near, sticking: raw.sticking)
    }
}
