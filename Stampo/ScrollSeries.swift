/// Which frames of an unreadable stretch are worth laying edge to edge. They
/// are not joined by a shift, so each has to stand as a screen of its own:
/// whole text and outlines, not a fill (a letter so large that the frame is one
/// colour), and not cut by the frame's edge. What a frame shows is measured, with
/// no word and no colour of any site in it: structure (`edges`), flat areas that
/// are not the page's background (`flat`), and ink on the outermost rows and columns
/// that is not in every frame (`cut`: something runs off the frame there). Whole
/// frames of the best structure go in first, up to three, in the order of time;
/// where more than three are as good as the best, those are taken by their numbers,
/// as before. The frames cut the least make up the number, and then the flat ones.
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
    /// The outermost rows and columns at each edge that are looked at for ink, and how far (out of 255) from
    /// the page's own brightness a pixel is ink. A word that stops short of the edge is not in them; a
    /// letter that runs off the frame is. Edges, which `edges` counts, are the wrong thing here: the body of a
    /// stroke that is cut by the side has none there.
    static let edgeDepth = 3
    static let inkGap: Int32 = 64
    /// A frame whose busiest outermost row or column has this much more ink than that row or column has in
    /// the frame where it has least is cut at that edge. What is fixed to the viewport is in every frame
    /// and cuts nothing.
    static let cutFrom = 0.04
    /// Whole frames whose structure is this share of the best one's are as good as it. When
    /// more than three are, the measures cannot tell which three are best, and
    /// they are taken by number, spread over the stretch: the first, a middle
    /// one and the last of them.
    static let closeToBest = 0.8

    struct Measure: Sendable, Equatable {
        /// The share of the frame's pixels that are edges.
        let edges: Double
        /// The share of the columns in which each of the outermost rows, at the top and at the bottom, is ink.
        let topRows: [Double]
        let bottomRows: [Double]
        /// The share of the rows in which each of the outermost columns, at the left and at the right, is ink.
        var leftColumns: [Double] = []
        var rightColumns: [Double] = []
        /// Per block: its luminance (0 to 1) and whether it is flat.
        let blockLuminance: [Float]
        let blockIsFlat: [Bool]
    }

    static func measure(_ frame: CaptureFrame) -> Measure {
        let w = frame.width, h = frame.height
        guard w > blockSize, h > blockSize else {
            return Measure(edges: 0, topRows: [], bottomRows: [], blockLuminance: [], blockIsFlat: [])
        }
        // Raw pointers and plain integer arithmetic throughout, as `ScrollBackgroundFilter`: in a Debug build the
        // checked subscripts of an array and the generic conversions between integer types cost seconds in these
        // loops for a stretch.
        var luminance = [Int32](repeating: 0, count: w * h)
        frame.pixels.withUnsafeBufferPointer { pixels in
            luminance.withUnsafeMutableBufferPointer { out in
                guard let source = pixels.baseAddress, let target = out.baseAddress else { return }
                let wide = UnsafeRawPointer(source).assumingMemoryBound(to: UInt32.self)
                var k = 0
                let count = w &* h
                while k < count {
                    // A pixel is four bytes, red first.
                    let pixel = wide[k]
                    let red = pixel & 0xFF, green = (pixel &>> 8) & 0xFF, blue = (pixel &>> 16) & 0xFF
                    target[k] = Int32(bitPattern: (red &* 299 &+ green &* 587 &+ blue &* 114) / 1000)
                    k &+= 1
                }
            }
        }
        var topRows = [Double](), bottomRows = [Double]()
        var brightness = [Float](), flat = [Bool]()
        var leftColumns = [Double](), rightColumns = [Double]()
        var edgePixels = 0, total = 0
        luminance.withUnsafeBufferPointer { buffer in
            guard let l = buffer.baseAddress else { return }
            let threshold = Int32(edgeStep)
            for y in 2..<h {
                var rowEdges = 0, n = 0, x = 2
                let row = y &* w
                while x < w {
                    let k = row &+ x, v = l[k]
                    let along = v &- l[k &- 2], across = v &- l[k &- 2 &* w]
                    if (along < 0 ? 0 &- along : along) &+ (across < 0 ? 0 &- across : across) > threshold {
                        rowEdges &+= 1
                    }
                    n &+= 1
                    x &+= 2
                }
                edgePixels &+= rowEdges
                total &+= n
            }
            for by in stride(from: 0, through: h - blockSize, by: blockSize) {
                for bx in stride(from: 0, through: w - blockSize, by: blockSize) {
                    var sum = 0, squares = 0, count = 0
                    var y = by
                    while y < by + blockSize {
                        var x = bx
                        while x < bx + blockSize {
                            let v = Int(l[y &* w &+ x])
                            sum &+= v
                            squares &+= v &* v
                            count &+= 1
                            x &+= 4
                        }
                        y &+= 4
                    }
                    let mean = Double(sum) / Double(count)
                    let deviation = max(0, Double(squares) / Double(count) - mean * mean).squareRoot()
                    brightness.append(Float(mean / 255))
                    flat.append(deviation < flatDeviation)
                }
            }
            // Ink in the outermost columns, down the whole height: what lies against the page's background there.
            // A letter cut by the side of the frame is ink in these columns; a word that stops short of them is not.
            let page = pageBrightness(brightness, flat)
            func ink(_ columns: Range<Int>) -> [Double] {
                columns.map { x in
                    var count = 0, y = 2
                    while y < h {
                        let d = l[y &* w &+ x] &- page
                        if (d < 0 ? 0 &- d : d) > inkGap { count &+= 1 }
                        y &+= 1
                    }
                    return Double(count) / Double(max(1, h - 2))
                }
            }
            leftColumns = ink(0..<edgeDepth)
            rightColumns = ink((w - edgeDepth)..<w)
            func inkRows(_ rows: Range<Int>) -> [Double] {
                rows.map { y in
                    var count = 0, x = 0
                    while x < w {
                        let d = l[y &* w &+ x] &- page
                        if (d < 0 ? 0 &- d : d) > inkGap { count &+= 1 }
                        x &+= 1
                    }
                    return Double(count) / Double(max(1, w))
                }
            }
            topRows = inkRows(0..<edgeDepth)
            bottomRows = inkRows((h - edgeDepth)..<h)
        }
        return Measure(edges: Double(edgePixels) / Double(max(1, total)), topRows: topRows, bottomRows: bottomRows,
                       leftColumns: leftColumns, rightColumns: rightColumns,
                       blockLuminance: brightness, blockIsFlat: flat)
    }

    /// The brightness of one frame's page, out of 255: the most frequent among its flat blocks, else its mean.
    private static func pageBrightness(_ brightness: [Float], _ flat: [Bool]) -> Int32 {
        var counts = [Int](repeating: 0, count: 16)
        for (index, isFlat) in flat.enumerated() where isFlat { counts[min(15, Int(brightness[index] * 16))] += 1 }
        if let most = counts.max(), most > 0, let bucket = counts.firstIndex(of: most) {
            return Int32((Float(bucket) + 0.5) * 255 / 16)
        }
        return Int32((brightness.reduce(0, +) / Float(max(1, brightness.count))) * 255)
    }

    /// What the rule made of the frames, for the log.
    struct Selection: Equatable, Sendable {
        /// The frames laid, in the order of time.
        let indices: [Int]
        /// Frames dropped as fills.
        let fills: [Int]
        /// Frames taken though they are flat, for want of three that are not (not those of too little structure).
        let toppedUp: [Int]
        /// Frames that are cut at an edge, and are laid only for want of whole ones.
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
            /// How far the frame is cut: its worst edge, as a share of the rows or columns that touch it.
            let cut: Double
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
        guard n > 0 else {
            return Selection(indices: [], fills: [], toppedUp: [], cut: [], byNumber: false, frames: [], close: [])
        }
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
        let leastLeft = least(\.leftColumns), leastRight = least(\.rightColumns)
        func cutShare(_ rows: [Double], _ floor: [Double]) -> Double {
            zip(rows, floor).map { $0 - $1 }.max() ?? 0
        }
        // How far each frame is cut: its worst edge, against the least that edge has in any frame.
        let severity: [Double] = measures.map {
            max(cutShare($0.topRows, leastTop), cutShare($0.bottomRows, leastBottom),
                cutShare($0.leftColumns, leastLeft), cutShare($0.rightColumns, leastRight))
        }
        let isCut = severity.map { $0 >= cutFrom }
        let score = measures.map(\.edges)
        var fills = (0..<n).filter { isFill[$0] }
        let candidates = (0..<n).filter { !isFill[$0] }
        // Flat, and yet of the structure of a page: a large card, not a letter grown past the frame. The frame of
        // the best structure is no fill for want of structure, so when every frame is a fill it is among these.
        let flatOnly = fills.filter { measures[$0].edges >= structureShare * best }
        func order(_ indices: [Int]) -> [Int] {
            indices.sorted { score[$0] > score[$1] || (score[$0] == score[$1] && $0 < $1) }
        }
        func fresh(_ index: Int, _ taken: [Int]) -> Bool {
            !same(-1, index) && !taken.contains(where: { same($0, index) })
        }
        // Whole frames first: those of the best structure, or, when more than three are as good as the best, spread
        // over the stretch by number.
        let whole = candidates.filter { !isCut[$0] }
        let top = whole.map { score[$0] }.max() ?? 0
        let close = whole.filter { score[$0] >= closeToBest * top }
        let byNumber = close.count > ScrollUnreadableStretch.seriesLimit
        var taken: [Int]
        if byNumber {
            taken = ScrollUnreadableStretch.series(count: close.count) { a, b in
                same(a < 0 ? -1 : close[a], close[b])
            }.map { close[$0] }
        } else {
            taken = []
            for index in order(whole) where taken.count < ScrollUnreadableStretch.seriesLimit && fresh(index, taken) {
                taken.append(index)
            }
        }
        // Fewer than three whole: the frames that are cut the least make up the number.
        for index in candidates.filter({ isCut[$0] })
            .sorted(by: { severity[$0] < severity[$1] || (severity[$0] == severity[$1] && score[$0] > score[$1]) })
        where taken.count < ScrollUnreadableStretch.seriesLimit && fresh(index, taken) {
            taken.append(index)
        }
        var toppedUp: [Int] = []
        if candidates.count < ScrollUnreadableStretch.seriesLimit {
            // Fewer than three that are no fills: the best of the flat ones make up the number.
            for index in order(flatOnly) where taken.count < ScrollUnreadableStretch.seriesLimit && fresh(index, taken) {
                taken.append(index)
                toppedUp.append(index)
            }
            fills.removeAll { toppedUp.contains($0) }
        }
        taken.sort()
        let details = (0..<n).map {
            Selection.Frame(edges: measures[$0].edges, flat: flat[$0], isFill: isFill[$0], isCut: isCut[$0],
                            cut: severity[$0], score: score[$0])
        }
        return Selection(indices: taken, fills: fills, toppedUp: toppedUp.sorted(),
                         cut: candidates.filter { isCut[$0] }, byNumber: byNumber, frames: details, close: close)
    }
}
