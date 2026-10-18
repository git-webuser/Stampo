import Foundation

nonisolated enum ScrollBackgroundFilter {
    /// On a fixed WebGL background, scrolling text aligns while the smooth
    /// background beneath it does not. Subtract its local mean so text edges
    /// can identify the motion. The clipped box keeps small frames well defined.
    static func highPass(_ frame: CaptureFrame, radius: Int) -> CaptureFrame {
        let w = frame.width, h = frame.height
        guard w > 0, h > 0 else { return frame }
        let r = min(max(0, radius), max(w, h))
        let stride = w + 1
        var output = frame.pixels
        // Reuse one channel's summed-area table to bound the working memory.
        var integral = [Int](repeating: 0, count: stride * (h + 1))
        frame.pixels.withUnsafeBufferPointer { pixels in
            output.withUnsafeMutableBufferPointer { destination in
                integral.withUnsafeMutableBufferPointer { table in
                    let source = pixels.baseAddress!, target = destination.baseAddress!, sums = table.baseAddress!
                    var channel = 0
                    while channel < 3 {
                        var y = 0
                        while y < h {
                            var row = 0, x = 0
                            let above = sums + y * stride
                            let below = above + stride
                            let inputRow = source + y * w * 4 + channel
                            while x < w {
                                row += Int(inputRow[x * 4])
                                below[x + 1] = above[x + 1] + row
                                x += 1
                            }
                            y += 1
                        }
                        y = 0
                        while y < h {
                            let y0 = y > r ? y - r : 0
                            let y1 = y + r + 1 < h ? y + r + 1 : h
                            let top = sums + y0 * stride, bottom = sums + y1 * stride
                            let inputRow = source + y * w * 4 + channel
                            let outputRow = target + y * w * 4 + channel
                            var x = 0
                            while x < w {
                                let x0 = x > r ? x - r : 0
                                let x1 = x + r + 1 < w ? x + r + 1 : w
                                let sum = bottom[x1] - top[x1] - bottom[x0] + top[x0]
                                let count = (x1 - x0) * (y1 - y0)
                                // Round the positive result exactly before clipping; integer
                                // division avoids per-pixel floating conversion costs in Debug.
                                let numerator = (128 + Int(inputRow[x * 4])) * count - sum
                                let value = numerator > 0 ? (numerator + count / 2) / count : 0
                                outputRow[x * 4] = UInt8(value < 255 ? value : 255)
                                x += 1
                            }
                            y += 1
                        }
                        channel += 1
                    }
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
        var consistent = 0
        var note = ""
    }

    /// Only silent raw tiles need help: their votes must never be overruled.
    /// An unchanged frame already proves a stop and needs no expensive filter.
    static func isNeeded(axis: ScrollAxis, expected: Int?, raw: FrameMatcher.StepEvidence,
                         frameChanged: Bool) -> Bool {
        frameChanged && axis == .vertical && expected != nil && raw.consistent == 0 && raw.against == 0
    }

    /// Called after an undecided refusal on text moving over a fixed background.
    /// Filtering removes information, so a match must stay within the calibrated
    /// four percent: a repeat one period away cannot place the step instead.
    static func inspect(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                        maximumOffset: Int, searchLimit: Int, expected: Int?, radius: Int,
                        raw: FrameMatcher.StepEvidence, frameChanged: Bool) -> Result {
        guard isNeeded(axis: axis, expected: expected, raw: raw, frameChanged: frameChanged),
              let expected else { return Result() }
        let before = ScrollBackgroundFilter.highPass(previous, radius: radius)
        let after = ScrollBackgroundFilter.highPass(current, radius: radius)
        if let match = try? FrameMatcher.match(previous: before, current: after, axis: axis,
                                               maximumOffset: maximumOffset),
           abs(match.offset - expected) <= FrameMatcher.nearRange(of: expected) {
            return Result(match: match, note: " · second look: match \(match.offset)")
        }
        let filtered = FrameMatcher.evidence(previous: before, current: after, axis: axis,
                                              offset: expected, searchLimit: searchLimit)
        let supporting = addingSupport(from: filtered)
        return Result(consistent: supporting, note: " · second look: \(supporting) tiles for")
    }

    /// Background-free tiles only prevent a false stop. Their weaker proof must
    /// neither confirm a queued distance nor make a section check undo a push.
    /// Negative votes are ignored: removing the background must not add retries.
    static func addingSupport(from filtered: FrameMatcher.StepEvidence) -> Int {
        filtered.contradicted ? 0 : filtered.consistent
    }
}
