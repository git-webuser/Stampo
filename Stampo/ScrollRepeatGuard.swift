/// A capture may make apparent progress while repeatedly visiting the same
/// footer. Keep small fingerprints of accepted frames, never their buffers.
nonisolated struct ScrollRepeatGuard {
    private struct Fingerprint: Equatable {
        let width: Int
        let height: Int
        let colors: [UInt16]
        let contentTiles: Int

        init(_ frame: CaptureFrame) {
            width = frame.width
            height = frame.height
            var colors: [UInt16] = []
            var sums = [Double](repeating: 0, count: 64)
            var squares = sums
            var counts = [Int](repeating: 0, count: 64)
            // Average each cell, retaining sub-byte precision: a thousandth
            // must mean the same thing here as in the original RGB pixels.
            for row in 0..<64 {
                let y0 = row * height / 64, y1 = (row + 1) * height / 64
                for column in 0..<64 {
                    let x0 = column * width / 64, x1 = (column + 1) * width / 64
                    var rgb = [Int](repeating: 0, count: 3), count = 0
                    let tile = row / 8 * ScrollStillness.grid + column / 8
                    for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 4)) {
                        for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 4)) {
                            let i = (y * width + x) * 4
                            for channel in 0..<3 { rgb[channel] += Int(frame.pixels[i + channel]) }
                            let brightness = Double(Int(frame.pixels[i]) + Int(frame.pixels[i + 1])
                                + Int(frame.pixels[i + 2])) / 765
                            sums[tile] += brightness
                            squares[tile] += brightness * brightness
                            counts[tile] += 1
                            count += 1
                        }
                    }
                    for channel in 0..<3 {
                        colors.append(UInt16(count > 0 ? (rgb[channel] * 256 + count / 2) / count : 0))
                    }
                }
            }
            self.colors = colors
            contentTiles = counts.indices.filter { tile in
                guard counts[tile] > 0 else { return false }
                let mean = sums[tile] / Double(counts[tile])
                return squares[tile] / Double(counts[tile]) - mean * mean >= 0.015 * 0.015
            }.count
        }

        func matches(_ other: Self) -> Bool {
            guard width == other.width, height == other.height else { return false }
            var difference = 0
            for i in colors.indices { difference += abs(Int(colors[i]) - Int(other.colors[i])) }
            return Double(difference) / Double(colors.count) / (255 * 256) < ScrollPush.changedFrom
        }
    }

    private var fingerprints: [Fingerprint] = []

    func isRepeat(_ frame: CaptureFrame, excluding previous: CaptureFrame?) -> Bool {
        let current = Fingerprint(frame)
        guard current.contentTiles >= 4 else { return false }
        let previous = previous.map(Fingerprint.init)
        // Standing on one page is not going round, even when it has already
        // stood for several accepted frames in an older capture's queue.
        if let previous, current.matches(previous) { return false }
        // Exclude just the preceding accepted frame, not all earlier visits
        // to its position. Push checks need not themselves have been accepted.
        let excluded = previous.flatMap { fingerprints.lastIndex(of: $0) }
        return fingerprints.indices.contains { $0 != excluded && current.matches(fingerprints[$0]) }
    }

    mutating func remember(_ frame: CaptureFrame) {
        fingerprints.append(Fingerprint(frame))
    }
}
