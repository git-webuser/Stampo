/// Vertical structure survives sideways card motion and changing videos. Fixed
/// textured rows need a three-frame mask, or a sidebar can hide real scrolling.
nonisolated enum ScrollRowProfile {
    struct Result: Equatable, Sendable {
        let best: Int
        let minimum: Double
        let zero: Double
        let expected: Double
        let maskedRows: Int

        var stands: Bool {
            zero.isFinite && expected.isFinite && minimum.isFinite
                && zero <= 1.25 * minimum && zero <= 0.6 * expected
        }
    }

    static func inspect(history: CaptureFrame, previous: CaptureFrame, current: CaptureFrame,
                        expected: Int) -> Result? {
        let w = previous.width, h = previous.height
        guard w > 2, h > 0, expected > 0, expected < h,
              history.width == w, history.height == h, current.width == w, current.height == h
        else { return nil }
        let older = profile(history), before = profile(previous), now = profile(current)
        let earlierChange = rowChange(history, previous), change = rowChange(previous, current)
        var fixed = [Bool](repeating: false, count: h)
        for y in 0..<h {
            fixed[y] = earlierChange[y] < ScrollPush.changedFrom && change[y] < ScrollPush.changedFrom
                && older[y] >= ScrollPush.changedFrom && before[y] >= ScrollPush.changedFrom
                && now[y] >= ScrollPush.changedFrom
        }
        func cost(_ offset: Int) -> Double {
            var sum = 0.0, count = 0
            for y in 0..<(h - offset) where !fixed[y] && !fixed[y + offset] {
                sum += abs(before[y + offset] - now[y])
                count += 1
            }
            guard count > 0, count * 4 >= h - offset else { return .infinity }
            return sum / Double(count)
        }
        var best = 0, minimum = Double.infinity
        for offset in 0...(h * 3 / 4) {
            let value = cost(offset)
            if value < minimum { best = offset; minimum = value }
        }
        return Result(best: best, minimum: minimum, zero: cost(0), expected: cost(expected),
                      maskedRows: fixed.filter { $0 }.count)
    }

    private static func profile(_ frame: CaptureFrame) -> [Double] {
        let w = frame.width
        return frame.pixels.withUnsafeBufferPointer { pixels in
            (0..<frame.height).map { y in
                var sum = 0, count = 0
                for x in stride(from: 2, to: w, by: 3) {
                    let i = (y * w + x) * 4, j = i - 8
                    let a = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                    let b = Int(pixels[j]) + Int(pixels[j + 1]) + Int(pixels[j + 2])
                    sum += abs(a - b)
                    count += 1
                }
                return Double(sum) / Double(count) / 765
            }
        }
    }

    private static func rowChange(_ before: CaptureFrame, _ current: CaptureFrame) -> [Double] {
        let w = before.width
        return before.pixels.withUnsafeBufferPointer { a in
            current.pixels.withUnsafeBufferPointer { b in
                (0..<before.height).map { y in
                    var sum = 0
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        for channel in 0..<3 { sum += abs(Int(a[i + channel]) - Int(b[i + channel])) }
                    }
                    return Double(sum) / Double(w * 3) / 255
                }
            }
        }
    }
}
