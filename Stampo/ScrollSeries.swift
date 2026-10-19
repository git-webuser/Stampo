/// Which frames of an unreadable stretch are worth laying edge to edge. They
/// are not joined by a shift, so each has to stand as a screen of its own:
/// whole text and outlines, not a fill (a letter so large that the frame is one
/// colour), and not cut by the frame's edge. What a frame shows is measured, with
/// no word and no colour of any site in it: structure (`edges`), flat areas that
/// are not the page's background (`flat`), and what touches the top and the bottom
/// edge that is not in every frame (`cut`). Up to three frames of the best
/// structure go in, in the order of time; where more than three are as good as the
/// best, those are taken by their numbers, as before.
nonisolated enum ScrollSeries {
    /// A pixel is an edge when the luminance steps by more than this (out of 255)
    /// at two pixels, along and across, added.
    static let edgeStep = 38
    /// Blocks of this many pixels are flat when their luminance varies by less than
    /// `flatDeviation` (out of 255, 0.02) and differ from the background by more than `backgroundGap`.
    static let blockSize = 32
    static let flatDeviation = 5.1
    static let backgroundGap: Float = 0.25
    /// A frame is a fill when this share of its blocks is flat and not background, or
    /// its structure is less than this share of the best frame's.
    static let fillShare = 0.25
    static let structureShare = 0.5
    /// The outermost rows are a band of this share of the height, at least three rows.
    static let bandShare = 0.01
    /// A frame whose busiest row at an edge has this much more structure than that
    /// row has in the frame where it has least is cut there, and counts half.
    static let cutFrom = 0.04
    /// Frames whose score is this share of the best score are as good as it. When
    /// more than three are, the measures cannot tell which three are best, and
    /// they are taken by number, spread over the stretch: the first, a middle
    /// one and the last of them.
    static let closeToBest = 0.8

    struct Measure: Sendable, Equatable {
        /// The share of the frame's pixels that are edges.
        let edges: Double
        /// The share of edge pixels in each of the rows of the band at the top, from the third row, and at the bottom.
        let topRows: [Double]
        let bottomRows: [Double]
        /// Per block: its luminance (0 to 1) and whether it is flat.
        let blockLuminance: [Float]
        let blockIsFlat: [Bool]
    }

    static func measure(_ frame: CaptureFrame) -> Measure {
        let w = frame.width, h = frame.height
        guard w > blockSize, h > blockSize else {
            return Measure(edges: 0, topRows: [], bottomRows: [], blockLuminance: [], blockIsFlat: [])
        }
        var luminance = [UInt8](repeating: 0, count: w * h)
        frame.pixels.withUnsafeBufferPointer { pixels in
            for k in 0..<(w * h) {
                luminance[k] = UInt8((Int(pixels[k * 4]) * 299 + Int(pixels[k * 4 + 1]) * 587
                                      + Int(pixels[k * 4 + 2]) * 114) / 1000)
            }
        }
        let band = max(3, Int(Double(h) * bandShare))
        var topRows = [Double](), bottomRows = [Double]()
        var edgePixels = 0, total = 0
        luminance.withUnsafeBufferPointer { l in
            for y in 2..<h {
                var rowEdges = 0, n = 0, x = 2
                while x < w {
                    let k = y * w + x, v = Int(l[k])
                    if abs(v - Int(l[k - 2])) + abs(v - Int(l[k - 2 * w])) > edgeStep { rowEdges += 1 }
                    n += 1
                    x += 2
                }
                edgePixels += rowEdges
                total += n
                let share = Double(rowEdges) / Double(max(1, n))
                if y < band { topRows.append(share) }
                if y >= h - band { bottomRows.append(share) }
            }
        }
        var brightness = [Float](), flat = [Bool]()
        luminance.withUnsafeBufferPointer { l in
            for by in stride(from: 0, to: h - blockSize, by: blockSize) {
                for bx in stride(from: 0, to: w - blockSize, by: blockSize) {
                    var sum = 0.0, squares = 0.0, count = 0.0
                    for y in stride(from: by, to: by + blockSize, by: 4) {
                        for x in stride(from: bx, to: bx + blockSize, by: 4) {
                            let v = Double(l[y * w + x])
                            sum += v
                            squares += v * v
                            count += 1
                        }
                    }
                    let mean = sum / count
                    let deviation = max(0, squares / count - mean * mean).squareRoot()
                    brightness.append(Float(mean / 255))
                    flat.append(deviation < flatDeviation)
                }
            }
        }
        return Measure(edges: Double(edgePixels) / Double(max(1, total)), topRows: topRows, bottomRows: bottomRows,
                       blockLuminance: brightness, blockIsFlat: flat)
    }

    /// What the rule made of the frames, for the log.
    struct Selection: Equatable, Sendable {
        /// The frames laid, in the order of time.
        let indices: [Int]
        /// Frames dropped as fills.
        let fills: [Int]
        /// Frames whose score was halved for a cut edge.
        let cut: [Int]
        /// More than three frames were as good as the best, and they were taken by number.
        let byNumber: Bool
        /// What was measured of each frame, for the log and for the tests.
        let frames: [Frame]
        /// The frames that are no fills and score at least `closeToBest` of the best.
        let close: [Int]

        struct Frame: Equatable, Sendable {
            let edges: Double
            let flat: Double
            let isFill: Bool
            let isCut: Bool
            let score: Double
        }
    }

    /// The brightness of the page's background: the most frequent among the flat
    /// blocks of all the frames, in sixteenths. Nil when no block is flat.
    static func background(_ measures: [Measure]) -> Float? {
        var counts = [Int](repeating: 0, count: 16)
        for measure in measures {
            for (index, flat) in measure.blockIsFlat.enumerated() where flat {
                counts[min(15, Int(measure.blockLuminance[index] * 16))] += 1
            }
        }
        guard let most = counts.max(), most > 0, let bucket = counts.firstIndex(of: most) else { return nil }
        return (Float(bucket) + 0.5) / 16
    }

    /// `same(a, b)` says that two frames show the same page, the last frame laid being -1.
    static func choose(_ measures: [Measure], same: (Int, Int) -> Bool) -> Selection {
        let n = measures.count
        guard n > 0 else { return Selection(indices: [], fills: [], cut: [], byNumber: false, frames: [], close: []) }
        let background = background(measures)
        let flat: [Double] = measures.map { measure in
            guard let background, !measure.blockIsFlat.isEmpty else { return 0 }
            let apart = measure.blockIsFlat.indices.filter {
                measure.blockIsFlat[$0] && abs(measure.blockLuminance[$0] - background) > backgroundGap
            }.count
            return Double(apart) / Double(measure.blockIsFlat.count)
        }
        let best = measures.map(\.edges).max() ?? 0
        let isFill = (0..<n).map { flat[$0] >= fillShare || measures[$0].edges < structureShare * best }
        // What is fixed to the viewport is in every frame and cuts nothing.
        func least(_ rows: KeyPath<Measure, [Double]>) -> [Double] {
            let length = measures.map { $0[keyPath: rows].count }.min() ?? 0
            return (0..<length).map { row in measures.map { $0[keyPath: rows][row] }.min() ?? 0 }
        }
        let leastTop = least(\.topRows), leastBottom = least(\.bottomRows)
        func cutShare(_ rows: [Double], _ floor: [Double]) -> Double {
            zip(rows, floor).map { $0 - $1 }.max() ?? 0
        }
        let isCut = measures.map {
            cutShare($0.topRows, leastTop) >= cutFrom || cutShare($0.bottomRows, leastBottom) >= cutFrom
        }
        let score = (0..<n).map { isCut[$0] ? measures[$0].edges / 2 : measures[$0].edges }
        let fills = (0..<n).filter { isFill[$0] }
        var candidates = (0..<n).filter { !isFill[$0] }
        if candidates.isEmpty {
            // Everything is a fill: the one that is the least flat.
            candidates = [(0..<n).min { flat[$0] < flat[$1] || (flat[$0] == flat[$1] && score[$0] > score[$1]) }!]
        }
        let top = candidates.map { score[$0] }.max() ?? 0
        let close = candidates.filter { score[$0] >= closeToBest * top }
        let byNumber = close.count > ScrollUnreadableStretch.seriesLimit
        var taken: [Int]
        if byNumber {
            taken = ScrollUnreadableStretch.series(count: close.count) { a, b in
                same(a < 0 ? -1 : close[a], close[b])
            }.map { close[$0] }
        } else {
            taken = []
            for index in candidates.sorted(by: { score[$0] > score[$1] || (score[$0] == score[$1] && $0 < $1) })
            where taken.count < ScrollUnreadableStretch.seriesLimit {
                guard !same(-1, index), !taken.contains(where: { same($0, index) }) else { continue }
                taken.append(index)
            }
        }
        taken.sort()
        let details = (0..<n).map {
            Selection.Frame(edges: measures[$0].edges, flat: flat[$0], isFill: isFill[$0], isCut: isCut[$0], score: score[$0])
        }
        return Selection(indices: taken, fills: fills, cut: (0..<n).filter { isCut[$0] && !isFill[$0] },
                         byNumber: byNumber, frames: details, close: close)
    }
}
