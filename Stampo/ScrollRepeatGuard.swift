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
            colors.reserveCapacity(64 * 64 * 3)
            let tileSize = 64 / ScrollStillness.grid
            var sums = [Double](repeating: 0, count: ScrollStillness.grid * ScrollStillness.grid)
            var squares = sums
            var counts = [Int](repeating: 0, count: sums.count)
            // Keep sub-byte precision so sparse one-byte noise stays within
            // one level without hiding larger changes in a few cells.
            for row in 0..<64 {
                let y0 = row * height / 64, y1 = (row + 1) * height / 64
                for column in 0..<64 {
                    let x0 = column * width / 64, x1 = (column + 1) * width / 64
                    var red = 0, green = 0, blue = 0, count = 0
                    let tile = row / tileSize * ScrollStillness.grid + column / tileSize
                    for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 4)) {
                        for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 4)) {
                            let i = (y * width + x) * 4
                            let r = Int(frame.pixels[i]), g = Int(frame.pixels[i + 1]), b = Int(frame.pixels[i + 2])
                            red += r
                            green += g
                            blue += b
                            let brightness = Double(r + g + b) / 765
                            sums[tile] += brightness
                            squares[tile] += brightness * brightness
                            counts[tile] += 1
                            count += 1
                        }
                    }
                    colors.append(UInt16(count > 0 ? (red * 256 + count / 2) / count : 0))
                    colors.append(UInt16(count > 0 ? (green * 256 + count / 2) / count : 0))
                    colors.append(UInt16(count > 0 ? (blue * 256 + count / 2) / count : 0))
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
            // A moved line of text on a fixed background changes only a few
            // cells. An average across the frame would hide those changes.
            for i in colors.indices {
                if abs(Int(colors[i]) - Int(other.colors[i])) > 256 { return false }
            }
            return true
        }
    }

    /// Whether two frames show the same page, as the guard sees it. A flat
    /// frame is the same as another flat one: this is no test for going round.
    static func isSamePage(_ a: CaptureFrame, _ b: CaptureFrame) -> Bool {
        Fingerprint(a).matches(Fingerprint(b))
    }

    private var fingerprints: [Fingerprint] = []
    private var checked: Fingerprint?

    func isRepeat(_ frame: CaptureFrame, excluding previous: CaptureFrame?) -> Bool {
        isRepeat(Fingerprint(frame), excluding: previous)
    }

    /// The capture checks a candidate before accepting it. Keep that check's
    /// fingerprint for acceptance while leaving isRepeat a pure query.
    mutating func checkForRepeat(_ frame: CaptureFrame, excluding previous: CaptureFrame?) -> Bool {
        let current = Fingerprint(frame)
        checked = current
        return isRepeat(current, excluding: previous)
    }

    private func isRepeat(_ current: Fingerprint, excluding previous: CaptureFrame?) -> Bool {
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
        checked = nil
    }

    /// Call only after accepting the frame most recently passed to checkForRepeat.
    /// No frame buffer is retained, and its fingerprint need not be made twice.
    mutating func rememberCheckedFrame() {
        guard let checked else { preconditionFailure("No frame checked for repeats") }
        fingerprints.append(checked)
        self.checked = nil
    }
}
