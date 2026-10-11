import AppKit
import CoreGraphics

nonisolated enum ScrollCaptureCancellationBoundary {
    /// Await an injectable operation and refuse to continue if the session was
    /// cancelled while the operation was suspended.
    static func awaitActive<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        let value = try await operation()
        guard !Task.isCancelled else { throw CancellationError() }
        return value
    }
}

/// The only direction a scrolling capture may advance.
nonisolated enum ScrollAxis: String, CaseIterable, Equatable, Sendable {
    case vertical
    case horizontal
}

/// A compact, immutable RGBA frame. Pixel coordinates use the same top-left
/// origin as CGImage and ScreenCaptureKit.
nonisolated struct CaptureFrame: Equatable, Sendable {
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    let width: Int
    let height: Int
    let pixels: [UInt8]
    /// The capture's own color space. Pixels stay in it, and the stitched
    /// image is tagged with it, so its profile matches a plain window shot.
    let colorSpace: CGColorSpace

    init(width: Int, height: Int, pixels: [UInt8],
         colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.colorSpace = colorSpace
    }

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 12_000, h <= 12_000,
              w * h <= 25_000_000 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: Self.bitmapInfo)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }
        self.init(width: w, height: h, pixels: bytes, colorSpace: space)
    }

    subscript(x: Int, y: Int, channel: Int) -> UInt8 {
        pixels[(y * width + x) * 4 + channel]
    }

    func cropped(to rect: CGRect) -> CaptureFrame? {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        var out = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 4)
        for row in 0..<(y1 - y0) {
            let source = ((y0 + row) * width + x0) * 4
            let target = row * (x1 - x0) * 4
            out.replaceSubrange(target..<(target + (x1 - x0) * 4), with: pixels[source..<(source + (x1 - x0) * 4)])
        }
        return CaptureFrame(width: x1 - x0, height: y1 - y0, pixels: out, colorSpace: colorSpace)
    }
}

nonisolated struct FrameMatch: Equatable, Sendable {
    /// Positive pixels by which the viewport content advanced.
    let offset: Int
    let confidence: Double
    let independentRegions: Int
    /// The tiles of the grid (row × columns + column) that stood still while
    /// the rest moved: a bar fixed to the viewport, or a part of the page that
    /// does not scroll with the rest.
    var standing: Set<Int> = []
    /// Tiles that put the page a little way off the offset found, neither for it
    /// nor against it (`FrameMatcher.nearRange(of:)`).
    var near = 0
}

nonisolated enum FrameMatchError: Error, Equatable, LocalizedError {
    case noReliableMotion
    case ambiguousMotion
    case crossAxisMotion
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .noReliableMotion: return "The area doesn't scroll. Click inside the page or table and start again."
        case .ambiguousMotion: return "Frames couldn't be aligned."
        case .crossAxisMotion: return "Frames couldn't be aligned."
        case .outputLimitExceeded: return "The scrolling image reached the configured size limit."
        }
    }
}

/// Matches several spatially separated patches so a repeated line of text or
/// a small animation cannot independently decide the whole-frame offset.
///
/// The frame is cut into a grid of tiles on both axes. A video, an animation, a
/// sticky header or a banner shows up as tiles that say nothing about the
/// scroll — they change by themselves, or do not move at all — and those are
/// left out; the rest each vote on the offset the whole of them found.
nonisolated enum FrameMatcher {
    /// The offset between two frames of a scroll. A frame whose content is a
    /// thin band across the scroll — two lines of text in a white page — is
    /// matched on that band alone (`contentBand`): the sample the matcher takes
    /// across the frame would otherwise fall between the lines.
    static func match(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                      maximumOffset: Int, minimumConfidence: Double = 0.72) throws -> FrameMatch {
        if let (_, narrowedPrevious, narrowedCurrent) = narrowed(previous, current, axis: axis) {
            // Tile numbers of the band's grid are not those of the frame's: nothing
            // is pinned from a match on a band.
            var found = try matchWhole(previous: narrowedPrevious, current: narrowedCurrent, axis: axis,
                                       maximumOffset: maximumOffset, minimumConfidence: minimumConfidence)
            found.standing = []
            return found
        }
        return try matchWhole(previous: previous, current: current, axis: axis,
                              maximumOffset: maximumOffset, minimumConfidence: minimumConfidence)
    }

    /// The band across the scroll that holds all the content of a frame, when
    /// that is thin — shorter than a third of the frame across. Lines across the
    /// scroll (a column of a vertical scroll, a row of a horizontal one) whose
    /// brightness varies along it by as much as a tile needs to be said to have
    /// content are looked for, sparsely along the scroll, and the band runs from
    /// the first to the last of them, with eight pixels to spare. Nil for a page
    /// with content all across, which is matched as it always was.
    static func contentBand(of frame: CaptureFrame, axis: ScrollAxis) -> Range<Int>? {
        let along = axis == .vertical ? frame.height : frame.width
        let cross = axis == .vertical ? frame.width : frame.height
        guard along >= 40, cross >= 60 else { return nil }
        let step = max(1, along / 300)
        var first: Int?, last: Int?
        for position in 0..<cross {
            var sum = 0.0, squares = 0.0, count = 0.0
            for index in stride(from: 0, to: along, by: step) {
                let x = axis == .vertical ? position : index
                let y = axis == .vertical ? index : position
                let i = (y * frame.width + x) * 4
                let value = Double(Int(frame.pixels[i]) + Int(frame.pixels[i + 1]) + Int(frame.pixels[i + 2])) / 765
                sum += value; squares += value * value; count += 1
            }
            let mean = sum / count
            if max(0, squares / count - mean * mean).squareRoot() >= contentSpread {
                if first == nil { first = position }
                last = position
                // Already as wide as a third with its margins, and it can only
                // grow: no band, and no need to look at the rest of the frame.
                if (position - (first ?? position) + 1 + 16) * 3 >= cross { return nil }
            }
        }
        guard let first, let last else { return nil }
        let band = max(0, first - 8)..<min(cross, last + 1 + 8)
        return band.count * 3 < cross ? band : nil
    }

    /// Both frames cut to the previous one's content band, if it has a thin one.
    private static func narrowed(_ previous: CaptureFrame, _ current: CaptureFrame, axis: ScrollAxis)
        -> (band: Range<Int>, previous: CaptureFrame, current: CaptureFrame)? {
        guard previous.width == current.width, previous.height == current.height,
              let band = contentBand(of: previous, axis: axis) else { return nil }
        let rect = axis == .vertical
            ? CGRect(x: band.lowerBound, y: 0, width: band.count, height: previous.height)
            : CGRect(x: 0, y: band.lowerBound, width: previous.width, height: band.count)
        guard let a = previous.cropped(to: rect), let b = current.cropped(to: rect) else { return nil }
        return (band, a, b)
    }

    private static func matchWhole(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                                   maximumOffset: Int, minimumConfidence: Double) throws -> FrameMatch {
        guard previous.width == current.width, previous.height == current.height else {
            throw FrameMatchError.noReliableMotion
        }
        let w = previous.width, h = previous.height
        let axisLength = axis == .vertical ? h : w
        let crossLength = axis == .vertical ? w : h
        let limit = min(maximumOffset, max(0, axisLength * 3 / 4))
        guard limit >= 2 else { throw FrameMatchError.noReliableMotion }

        let tiles = tileCurves(previous: previous, current: current, axis: axis, limit: limit)
        let (tileSum, tileCnt, minSamples) = (tiles.sum, tiles.count, tiles.minimumSamples)
        let tileRows = Self.tileRows, tileCols = Self.tileColumns, tileCount = Self.tileRows * Self.tileColumns
        let tileCost = tiles.cost

        // A tile that fits no offset is changing by itself (a video, an
        // animation); a tile that fits standing still as well as anywhere is
        // fixed on screen or blank. Neither says anything about the scroll.
        var moving: [Int] = []
        for t in 0..<tileCount {
            let curve = tileCost[t]
            guard let lowest = curve.filter(\.isFinite).min(), lowest <= fitThreshold else { continue }
            let still = curve[0...min(2, limit)].filter(\.isFinite).min() ?? .infinity
            if still - lowest <= tolerance { continue }
            moving.append(t)
        }
        guard !moving.isEmpty else { throw FrameMatchError.noReliableMotion }

        var agg = [Double](repeating: .infinity, count: limit + 1)
        for d in 1...limit {
            var s = 0.0, n = 0
            for t in moving where tileCnt[t][d] >= minSamples { s += tileSum[t][d]; n += tileCnt[t][d] }
            if n > 0 { agg[d] = s / Double(n) }
        }
        let coarseBest = agg.indices.min { agg[$0] < agg[$1] } ?? 0
        guard coarseBest > 0, agg[coarseBest] < 0.20 else { throw FrameMatchError.noReliableMotion }

        // Settle the last pixel on every row, within the moving tiles only.
        let movingSet = Set(moving)
        let acrossCount = min(48, crossLength)
        let crossPos = (0..<acrossCount).map { min(crossLength - 1, Int((Double($0) + 0.5) / Double(acrossCount) * Double(crossLength))) }
        let crossCols = crossPos.enumerated().map { ($0.element, $0.offset * tileCols / acrossCount) }
        func denseCost(_ delta: Int) -> Double {
            var sum = 0, samples = 0
            for along in 0..<(axisLength - delta) {
                let row = min(tileRows - 1, along * tileRows / axisLength)
                for (cross, col) in crossCols where movingSet.contains(row * tileCols + col) {
                    let i = axis == .vertical ? ((along + delta) * w + cross) * 4 : (cross * w + along + delta) * 4
                    let j = axis == .vertical ? (along * w + cross) * 4 : (cross * w + along) * 4
                    sum += abs(Int(previous.pixels[i]) - Int(current.pixels[j]))
                        + abs(Int(previous.pixels[i + 1]) - Int(current.pixels[j + 1]))
                        + abs(Int(previous.pixels[i + 2]) - Int(current.pixels[j + 2]))
                    samples += 1
                }
            }
            return samples == 0 ? .infinity : Double(sum) / Double(samples)
        }
        var best = coarseBest, bestDense = denseCost(coarseBest)
        for delta in max(1, coarseBest - 2)...min(limit, coarseBest + 2) where delta != coarseBest {
            let cost = denseCost(delta)
            if cost < bestDense { best = delta; bestDense = cost }
        }

        let orthogonal = axis == .vertical ? ScrollAxis.horizontal : .vertical
        let crossLimit = min(20, (orthogonal == .vertical ? h : w) / 10)
        let residual = bestOrthogonalResidual(previous: previous, current: current,
                                             primaryAxis: axis, primaryOffset: best,
                                             limit: crossLimit)
        if abs(residual.offset) > 3, residual.error < 12 {
            throw FrameMatchError.crossAxisMotion
        }

        var agreeing = 0, decisive = 0, against = 0, near = 0, tileMargin = 0.0
        for t in moving {
            let curve = tileCost[t]
            let atBest = curve[best]
            guard atBest.isFinite, let lowest = curve.filter(\.isFinite).min() else { continue }
            guard atBest - lowest <= tolerance else {
                if let other = uniqueBest(curve, tolerance: tolerance) {
                    if abs(other - best) <= nearRange(of: best) { near += 1 } else { against += 1 }
                }
                continue
            }
            agreeing += 1
            let alternative = curve.indices.lazy.filter { abs($0 - best) > 2 }.map { curve[$0] }.filter(\.isFinite).min() ?? .infinity
            if alternative - atBest > tolerance {
                decisive += 1
                tileMargin = max(tileMargin, (alternative - atBest) / max(alternative, 0.015))
            }
        }
        let alternative = agg.enumerated().filter { abs($0.offset - best) > 2 }.map(\.element).filter(\.isFinite).min() ?? 1
        let frameMargin = (alternative - agg[best]) / max(alternative, 0.015)
        // Coverage: of the tiles that have something to compare at this offset,
        // at least half must line up. Where the rest is a video that changed,
        // a lone tile lining up by chance is not a match; blank areas have
        // nothing to compare and do not count, so a column at the edge of an
        // otherwise empty page still passes.
        //
        // Unless several of them line up exactly. A page that holds still
        // matches pixel for pixel, where the chance matches inside a changing
        // video are nearly always approximate — and a heading with a video
        // under it, the heading alone surrounded by dark nothing, is a page
        // whose few tiles with content are the ones that matter.
        var comparable = 0, lined = 0, exact = 0
        for t in 0..<tileCount where tileCost[t][best].isFinite && tiles.hasContent[t][best] {
            comparable += 1
            if tileCost[t][best] <= fitThreshold { lined += 1 }
            if tileCost[t][best] <= exactFit { exact += 1 }
        }
        guard comparable > 0,
              exact >= exactTilesToSkipCoverage
                  || Double(lined) >= coverageRequired * Double(comparable) else {
            throw FrameMatchError.ambiguousMotion
        }
        guard decisive >= 1 || frameMargin >= 0.5, against <= max(1, moving.count / 5) else { throw FrameMatchError.ambiguousMotion }
        let margin = max(0, min(1, max(frameMargin, tileMargin)))
        let confidence = min(1, (1 - agg[best]) * 0.55 + margin * 0.45)
        guard confidence >= minimumConfidence else { throw FrameMatchError.ambiguousMotion }
        return FrameMatch(offset: best, confidence: confidence, independentRegions: agreeing,
                          standing: standingTiles(tiles), near: near)
    }

    /// The tiles that stand still: they have something in them, and their one
    /// best fit is at no offset to speak of. A blank tile fits any offset and a
    /// tile that changes by itself fits none, so neither is said to stand.
    private static func standingTiles(_ tiles: TileCurves) -> Set<Int> {
        var standing = Set<Int>()
        for t in 0..<tiles.cost.count where tiles.hasContent[t][0] {
            let curve = tiles.cost[t]
            if let best = uniqueBest(curve, tolerance: tolerance), best <= 2, curve[best] <= fitThreshold {
                standing.insert(t)
            }
        }
        return standing
    }

    /// Tiles the sample grid is cut into: `tileRows` along the scroll, `tileColumns`
    /// across it, a tile's number being its row times `tileColumns` plus its column.
    static let tileRows = 4, tileColumns = 5
    /// How far from an offset a tile's one best fit may lie and the tile still
    /// be neither for the offset nor against it: `nearFraction` of the offset,
    /// and two pixels at the least. Two columns of a page that the page's
    /// script moves a little faster and a little slower than the rest — a
    /// parallax of ±3.1 % on claude.com's use-case library, up to 3.7 % in
    /// others — are each rigid and exact at their own offset, and a few of
    /// their tiles are enough to refuse a step whose centre is exact; a pixel of
    /// play between frames is the same thing at a smaller scale. Four percent
    /// leaves a margin over the parallax and is far under the 12.5 % that a list
    /// of lines 80 px apart makes of a step of 640, where a tile that knows
    /// better is a different line of the list.
    static let nearFraction = 0.04
    static func nearRange(of offset: Int) -> Int {
        max(2, Int((Double(offset) * nearFraction).rounded()))
    }

    /// How far a tile's cost may sit above its own best and still be said to
    /// agree with an offset, and the cost under which a tile fits at all.
    private static let tolerance = 0.005, fitThreshold = 0.03
    /// The spread of brightness (standard deviation, 0…1) from which a tile's
    /// samples have something in them to compare, and the share of such tiles
    /// that must line up with an offset for it to be believed.
    static let contentSpread = 0.015
    private static let coverageRequired = 0.5
    /// A tile lines up exactly under this cost, and this many such tiles are
    /// enough to believe an offset whatever the rest of the frame is doing.
    /// Two let a wrong offset through the fuzz; three do not.
    private static let exactFit = 0.002, exactTilesToSkipCoverage = 3

    /// The inner loop of `tileCurves`: about a million samples a match.
    private static func accumulate(before: UnsafeBufferPointer<UInt8>, after: UnsafeBufferPointer<UInt8>,
                                   width w: Int, axis: ScrollAxis, limit: Int,
                                   alongPos: [Int], crossPos: [Int],
                                   tileRowOfAlong: [Int], tileOfCross: [Int],
                                   into accumulators: UnsafeMutablePointer<Double>) {
        let fields = 6, stride = limit + 1
        let axisLength = axis == .vertical ? before.count / (w * 4) : w
        for delta in 0...limit {
            for ai in 0..<alongPos.count {
                let cAxis = alongPos[ai]
                guard cAxis + delta < axisLength else { continue }
                let rowTile = tileRowOfAlong[ai] * tileColumns
                for ci in 0..<crossPos.count {
                    let cross = crossPos[ci]
                    let i: Int, j: Int
                    if axis == .vertical { i = ((cAxis + delta) * w + cross) * 4; j = (cAxis * w + cross) * 4 }
                    else { i = (cross * w + cAxis + delta) * 4; j = (cross * w + cAxis) * 4 }
                    let p0 = Int(before[i]), p1 = Int(before[i + 1]), p2 = Int(before[i + 2])
                    let c0 = Int(after[j]), c1 = Int(after[j + 1]), c2 = Int(after[j + 2])
                    let error = Double(abs(p0 - c0) + abs(p1 - c1) + abs(p2 - c2)) / 765.0
                    let was = Double(p0 + p1 + p2) / 765.0
                    let now = Double(c0 + c1 + c2) / 765.0
                    let slot = accumulators + ((rowTile + tileOfCross[ci]) * stride + delta) * fields
                    slot[0] += error; slot[1] += 1
                    slot[2] += was; slot[3] += was * was
                    slot[4] += now; slot[5] += now * now
                }
            }
        }
    }

    /// Cost of every offset from 0 to `limit`, tile by tile.
    ///
    /// Samples sit at fixed places in the CURRENT frame; an offset is scored on
    /// the samples whose source row still lies in the previous frame, so a
    /// large offset is judged on fewer of them — and an offset where a tile has
    /// fewer than a quarter of its samples is not scored at all (infinite).
    ///
    /// Besides the cost, each tile at each offset reports whether it has
    /// content: whether the brightness of the samples compared, on either side,
    /// varies at all. A blank area lines up with anything and says nothing.
    private typealias TileCurves = (sum: [[Double]], count: [[Int]], cost: [[Double]],
                                    minimumSamples: Int, hasContent: [[Bool]])

    private static func tileCurves(previous: CaptureFrame, current: CaptureFrame,
                                   axis: ScrollAxis, limit: Int) -> TileCurves {
        let w = previous.width, h = previous.height
        let axisLength = axis == .vertical ? h : w
        let crossLength = axis == .vertical ? w : h
        let alongCount = min(96, axisLength), acrossCount = min(48, crossLength)
        let tileCount = tileRows * tileColumns
        let alongPos = (0..<alongCount).map { min(axisLength - 1, Int((Double($0) + 0.5) / Double(alongCount) * Double(axisLength))) }
        let crossPos = (0..<acrossCount).map { min(crossLength - 1, Int((Double($0) + 0.5) / Double(acrossCount) * Double(crossLength))) }
        let tileOfCross = (0..<acrossCount).map { $0 * tileColumns / acrossCount }
        let tileRowOfAlong = (0..<alongCount).map { $0 * tileRows / alongCount }

        // Per tile and offset, in one flat buffer so the inner loop touches
        // memory in one place: the summed error and the sample count, then the
        // sum and sum of squares of the brightness on each side.
        let fields = 6
        let stride = limit + 1
        let accumulators = UnsafeMutablePointer<Double>.allocate(capacity: tileCount * stride * fields)
        accumulators.initialize(repeating: 0, count: tileCount * stride * fields)
        defer { accumulators.deallocate() }

        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { after in
                accumulate(before: before, after: after, width: w, axis: axis, limit: limit,
                           alongPos: alongPos, crossPos: crossPos,
                           tileRowOfAlong: tileRowOfAlong, tileOfCross: tileOfCross,
                           into: accumulators)
            }
        }

        func spread(_ sum: Double, _ squares: Double, _ n: Double) -> Double {
            guard n > 0 else { return 0 }
            let mean = sum / n
            return max(0, squares / n - mean * mean).squareRoot()
        }
        let perTile = max(1, (alongCount / tileRows) * (acrossCount / tileColumns))
        let minSamples = max(4, perTile / 4)
        var sums = [[Double]](), counts = [[Int]](), costs = [[Double]](), contents = [[Bool]]()
        for t in 0..<tileCount {
            var tileSum = [Double](), tileCount_ = [Int](), tileCost = [Double](), tileContent = [Bool]()
            for d in 0...limit {
                let slot = accumulators + (t * stride + d) * fields
                let n = Int(slot[1])
                tileSum.append(slot[0]); tileCount_.append(n)
                tileCost.append(n >= minSamples ? slot[0] / Double(n) : .infinity)
                tileContent.append(max(spread(slot[2], slot[3], slot[1]),
                                       spread(slot[4], slot[5], slot[1])) >= contentSpread)
            }
            sums.append(tileSum); counts.append(tileCount_); costs.append(tileCost); contents.append(tileContent)
        }
        return (sums, counts, costs, minSamples, contents)
    }

    /// What the frames of a step the matcher could not place still say.
    struct StepEvidence: Equatable {
        /// Tiles standing still (see `FrameMatch.standing`).
        let standing: Set<Int>
        /// Of the tiles that move at all, how many fit the distance asked
        /// about and how many know better. Zero when none was asked about.
        let consistent: Int
        let against: Int
        /// More tiles know better than a fifth of those that move, or the
        /// distance cannot be looked at: the frames contradict it.
        let contradicted: Bool
        /// Tiles whose one best fit is near the distance asked about
        /// (`nearRange(of:)`): not counted for it nor against it.
        var near = 0
    }

    /// One pass over the tiles of two frames the matcher could not place: which
    /// stand still, and — if `offset` is the distance the page is expected to
    /// have moved — whether the tiles that move are consistent with it. Every
    /// tile that fits some offset well must fit this one about as well; tiles
    /// that change by themselves, stand still or are blank have no say.
    static func evidence(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                         offset: Int?, searchLimit: Int) -> StepEvidence {
        // On the band alone, as `match` is, when the content is a thin one.
        if let (_, narrowedPrevious, narrowedCurrent) = narrowed(previous, current, axis: axis) {
            let found = evidenceWhole(previous: narrowedPrevious, current: narrowedCurrent, axis: axis,
                                      offset: offset, searchLimit: searchLimit)
            // The tile numbers are those of the band's grid, not the frame's:
            // as with a match on a band, nothing that stands is reported.
            return StepEvidence(standing: [], consistent: found.consistent, against: found.against,
                                contradicted: found.contradicted, near: found.near)
        }
        return evidenceWhole(previous: previous, current: current, axis: axis,
                             offset: offset, searchLimit: searchLimit)
    }

    private static func evidenceWhole(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                                      offset: Int?, searchLimit: Int) -> StepEvidence {
        let axisLength = axis == .vertical ? previous.height : previous.width
        let limit = min(max((offset ?? 0) + 2, searchLimit), axisLength * 3 / 4)
        guard previous.width == current.width, previous.height == current.height, limit >= 2,
              offset.map({ $0 > 0 && $0 <= limit }) ?? true
        else { return StepEvidence(standing: [], consistent: 0, against: 0, contradicted: offset != nil) }
        let tiles = tileCurves(previous: previous, current: current, axis: axis, limit: limit)
        let standing = standingTiles(tiles)
        guard let offset else { return StepEvidence(standing: standing, consistent: 0, against: 0, contradicted: false) }
        var consistent = 0, against = 0, near = 0, moving = 0
        for t in 0..<tiles.cost.count {
            let curve = tiles.cost[t]
            guard let lowest = curve.filter(\.isFinite).min(), lowest <= fitThreshold else { continue }
            let still = curve[0...2].filter(\.isFinite).min() ?? .infinity
            if still - lowest <= tolerance { continue }
            moving += 1
            guard curve[offset].isFinite else { continue }
            if curve[offset] - lowest <= tolerance { consistent += 1 }
            else if let other = uniqueBest(curve, tolerance: tolerance) {
                if abs(other - offset) <= nearRange(of: offset) { near += 1 } else { against += 1 }
            }
        }
        // Tiles near the distance are neutral only beside a tile that is exact at
        // it: the columns of a parallax are off by a little while the rest of the
        // page is where it was asked. With none exact, nothing says the page
        // moved by that distance, and tiles that are all a little off it are what
        // a picture growing as the page scrolls looks like (2026-10-11-115436:
        // one tile at 635 against the 640 asked, the rest changing by
        // themselves). Then they are against, as they were.
        if consistent == 0 {
            against += near
            near = 0
        }
        return StepEvidence(standing: standing, consistent: consistent, against: against,
                            contradicted: against > max(0, moving / 5), near: near)
    }

    /// Whether `offset` is consistent with the frames when they cannot pin it
    /// down themselves (see `evidence`). Nil when the frames contradict the
    /// prediction.
    static func verifyPredicted(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                                offset: Int, searchLimit: Int) -> (consistent: Int, against: Int)? {
        let found = evidence(previous: previous, current: current, axis: axis, offset: offset,
                             searchLimit: searchLimit)
        return found.contradicted ? nil : (found.consistent, found.against)
    }

    /// A tile votes against an offset only when it knows better: its own best
    /// fit is unique. A mostly blank tile, or one whose content changes, can
    /// fit some far offset by chance; that is no evidence.
    static func uniqueBest(_ curve: [Double], tolerance: Double) -> Int? {
        guard let arg = curve.indices.filter({ curve[$0].isFinite }).min(by: { curve[$0] < curve[$1] }) else { return nil }
        let rival = curve.indices.lazy.filter { abs($0 - arg) > 2 }.map { curve[$0] }.filter(\.isFinite).min() ?? .infinity
        return rival - curve[arg] > tolerance ? arg : nil
    }

    static func bestOrthogonalResidual(previous: CaptureFrame, current: CaptureFrame,
                                       primaryAxis: ScrollAxis, primaryOffset: Int,
                                       limit: Int) -> (offset: Int, error: Double) {
        let width = previous.width, height = previous.height
        let range = primaryAxis == .vertical ? width : height
        let residualLimit = min(max(0, limit), max(0, range / 4))
        guard residualLimit > 0 else { return (0, .infinity) }

        func meanError(at residual: Int) -> Double? {
            var error = 0.0, samples = 0
            if primaryAxis == .vertical {
                let crossStart = max(0, -residual)
                let crossEnd = min(width, width - residual)
                let alongEnd = height - primaryOffset
                guard crossEnd > crossStart, alongEnd > 0 else { return nil }
                for x in stride(from: crossStart, to: crossEnd, by: max(1, (crossEnd - crossStart) / 24)) {
                    for y in stride(from: 0, to: alongEnd, by: max(1, alongEnd / 48)) {
                        let previousIndex = ((y + primaryOffset) * width + x + residual) * 4
                        let currentIndex = (y * width + x) * 4
                        error += channelError(previous.pixels, previousIndex, current.pixels, currentIndex)
                        samples += 3
                    }
                }
            } else {
                let crossStart = max(0, -residual)
                let crossEnd = min(height, height - residual)
                let alongEnd = width - primaryOffset
                guard crossEnd > crossStart, alongEnd > 0 else { return nil }
                for y in stride(from: crossStart, to: crossEnd, by: max(1, (crossEnd - crossStart) / 24)) {
                    for x in stride(from: 0, to: alongEnd, by: max(1, alongEnd / 48)) {
                        let previousIndex = ((y + residual) * width + x + primaryOffset) * 4
                        let currentIndex = (y * width + x) * 4
                        error += channelError(previous.pixels, previousIndex, current.pixels, currentIndex)
                        samples += 3
                    }
                }
            }
            return error / Double(max(1, samples))
        }

        // No sideways movement is the default. Content without vertical
        // detail (full-width bands) fits every residual equally, so a
        // non-zero residual has to be clearly better than zero to count.
        guard let zero = meanError(at: 0) else { return (0, .infinity) }
        var best = (offset: 0, error: Double.infinity)
        for residual in (-residualLimit)...residualLimit where residual != 0 {
            if let score = meanError(at: residual), score < best.error { best = (residual, score) }
        }
        guard best.error <= zero - 2, best.error <= zero * 0.75 else { return (0, zero) }
        return best
    }

    private static func channelError(_ lhs: [UInt8], _ lhsIndex: Int,
                                     _ rhs: [UInt8], _ rhsIndex: Int) -> Double {
        Double(abs(Int(lhs[lhsIndex]) - Int(rhs[rhsIndex]))
             + abs(Int(lhs[lhsIndex + 1]) - Int(rhs[rhsIndex + 1]))
             + abs(Int(lhs[lhsIndex + 2]) - Int(rhs[rhsIndex + 2])))
    }
}

nonisolated struct CaptureStrip: Sendable {
    /// The band, at the resolution of the image being assembled.
    let frame: CaptureFrame
    /// Where it begins along the image, in that resolution's pixels.
    let start: Int
}

/// Keeps independent bands until the one final allocation, avoiding repeated
/// reallocation and copy of an ever-growing bitmap at every scroll step.
///
/// It can drop the whole image to half resolution once (`shrinkToHalf`), which
/// is how a capture that has reached its limit can go on: the bands collected
/// are halved and every later one is halved before it is added. Movements are
/// kept in the pixels of the frames (`fullLength`) and a band is laid at half
/// of where it began, rounded down, so the halves tile exactly — rounding each
/// band's own length instead would add its error up over fifty of them.
nonisolated struct ImageAssembler: Sendable {
    let axis: ScrollAxis
    /// The longest the image may be along the scroll, in its own pixels. The
    /// most it may hold follows: this many by the frame's other side.
    let maxLength: Int
    /// The frames' pixels to a point, which is how long a stretch of the seam's
    /// search has to be (`ScrollSeam`).
    let scale: CGFloat
    private(set) var strips: [CaptureStrip] = []
    /// Length of the image so far, in its own pixels — half of `fullLength`
    /// once shrunk. This is what the limit is compared with.
    private(set) var totalLength = 0
    /// What the movements add up to, in the pixels of the frames.
    private(set) var fullLength = 0
    private(set) var isShrunk = false
    private(set) var viewportWidth = 0
    private(set) var viewportHeight = 0
    /// The last frame laid, whole, and the rows of it the seam before it left
    /// to the frame before: what the next seam is chosen against.
    private(set) var lastFrame: CaptureFrame?
    private var lastSkip = 0
    /// How far the last frame laid was from the one before it, and where the
    /// seam before it fell in that one: together they say how much of the last
    /// frame the one before it had already given (`replaceLast`).
    private var lastMovement = 0
    private var skipBeforeLast = 0
    /// The seam of the last frame laid, and why it fell there.
    private(set) var lastSeam: ScrollSeam.Choice?

    init(axis: ScrollAxis, maxLength: Int = ScrollLengthLimit.default, scale: CGFloat = 1) {
        self.axis = axis
        self.maxLength = maxLength
        self.scale = scale
    }

    /// The image's other side in its own pixels: the frame's, or half of it
    /// once shrunk. Zero before there is a frame.
    var outputCrossSize: Int {
        let cross = axis == .vertical ? viewportWidth : viewportHeight
        return isShrunk ? (cross + 1) / 2 : cross
    }

    /// Where the image stops growing: `maxLength`, or less if holding that much
    /// at this width would pass the memory ceiling.
    var effectiveLimit: Int {
        ScrollLengthLimit.effectiveLimit(limit: maxLength, crossSize: outputCrossSize)
    }

    /// How long the image would be after `movement` more pixels of the frames.
    func lengthAfterAdding(_ movement: Int) -> Int {
        isShrunk ? (fullLength + movement) / 2 : fullLength + movement
    }

    mutating func begin(with frame: CaptureFrame) {
        guard strips.isEmpty else { return }
        viewportWidth = frame.width
        viewportHeight = frame.height
        let length = axis == .vertical ? frame.height : frame.width
        strips.append(CaptureStrip(frame: frame, start: 0))
        totalLength = length
        fullLength = length
        lastFrame = frame
        lastSkip = 0
        lastMovement = 0
        skipBeforeLast = 0
        lastSeam = nil
    }

    /// Adds a frame that is `movement` pixels further along than the last one.
    /// The two overlap by `frameLength − movement` pixels and the seam is laid
    /// in the middle of that: the earlier frame keeps the first half, the later
    /// one gives the rest. What a page does as it scrolls into view (a heading
    /// sliding in, an image fading up) is finished in the later frame and
    /// half-way in the earlier, so the later frame's half is the newer. One
    /// that is still arriving across the middle is taken whole from the later
    /// frame by moving the seam up to where the frames agree (`ScrollSeam`).
    /// And what is fixed to an edge of the viewport — a site's bar at the top,
    /// a banner at the bottom — and so repeats in every frame, is cut off the
    /// new frame's top and off the collected image's end, as long as it is no
    /// deeper than half the overlap, instead of reappearing at every seam.
    /// The collected image is cut back to the seam and the rest of the frame
    /// laid from there, so at any time the image costs about its own size and
    /// one frame.
    ///
    /// Direction is normalized so the assembled document reads top-to-bottom /
    /// left-to-right.
    mutating func append(_ frame: CaptureFrame, movement: Int) throws {
        let frameLength = axis == .vertical ? frame.height : frame.width
        guard !strips.isEmpty, frame.width == viewportWidth, frame.height == viewportHeight,
              movement > 0, movement < frameLength
        else { throw FrameMatchError.noReliableMotion }
        let overlap = frameLength - movement
        guard fullLength >= overlap else { throw FrameMatchError.noReliableMotion }
        // The rows of the new frame that the earlier one keeps, and where the
        // seam falls in the image, in the frames' pixels.
        let choice = lastFrame.map {
            ScrollSeam.choose(frame: frame, after: $0, axis: axis, movement: movement,
                              previousSkip: lastSkip, scale: scale)
        } ?? ScrollSeam.Choice(skip: overlap / 2, reason: .middleAgrees)
        let skip = choice.skip
        let seam = fullLength - overlap + skip
        guard let rest = Self.dropping(skip, from: frame, axis: axis) else { throw FrameMatchError.noReliableMotion }
        if isShrunk {
            // In the output's pixels, from the same floor as ever: the rest of
            // the frame begins at half of where it begins in its own, and ends
            // at half of where it ends, so what is cut and what is laid tile
            // exactly.
            let start = seam / 2, end = (fullLength + movement) / 2
            trim(to: start)
            // A frame can round to nothing only in a degenerate case; the image
            // then simply ends where the cut left it, and the next begins there.
            if end > start, let halved = Self.halved(rest, axis: axis, length: end - start) {
                strips.append(CaptureStrip(frame: halved, start: start))
            }
            fullLength += movement
            totalLength = fullLength / 2
        } else {
            trim(to: seam)
            strips.append(CaptureStrip(frame: rest, start: seam))
            totalLength += movement
            fullLength += movement
        }
        skipBeforeLast = lastSkip
        lastMovement = movement
        lastFrame = frame
        lastSkip = skip
        lastSeam = choice
    }

    /// Lays `frame` over the last frame laid, at the same place: the page did
    /// not move, something on it did — a section pinned to the viewport changed
    /// its stage — and the image is to have it as it is now. The image is as
    /// long as it was. The new frame gives everything from the floor, where the
    /// seam before the last frame left off (the rows above it are the earlier
    /// frame's and stay), so that it covers as much as it can; in the halved
    /// image the same, in its pixels. The next frame is laid against this one.
    mutating func replaceLast(with frame: CaptureFrame) throws {
        guard lastFrame != nil, !strips.isEmpty,
              frame.width == viewportWidth, frame.height == viewportHeight
        else { throw FrameMatchError.noReliableMotion }
        let frameLength = axis == .vertical ? frame.height : frame.width
        let floor = max(0, skipBeforeLast - lastMovement)
        let seam = fullLength - frameLength + floor
        guard seam >= 0, let rest = Self.dropping(floor, from: frame, axis: axis)
        else { throw FrameMatchError.noReliableMotion }
        if isShrunk {
            let start = seam / 2, end = fullLength / 2
            trim(to: start)
            if end > start, let halved = Self.halved(rest, axis: axis, length: end - start) {
                strips.append(CaptureStrip(frame: halved, start: start))
            }
        } else {
            trim(to: seam)
            strips.append(CaptureStrip(frame: rest, start: seam))
        }
        lastFrame = frame
        lastSkip = floor
        lastSeam = nil
    }

    /// `frame` without its first `count` rows (columns, along a horizontal
    /// scroll). Whole when there is nothing to drop.
    private static func dropping(_ count: Int, from frame: CaptureFrame, axis: ScrollAxis) -> CaptureFrame? {
        guard count > 0 else { return frame }
        let rect = axis == .vertical
            ? CGRect(x: 0, y: count, width: frame.width, height: frame.height - count)
            : CGRect(x: count, y: 0, width: frame.width - count, height: frame.height)
        return frame.cropped(to: rect)
    }

    /// Cuts the image back to `length` of its own pixels along the scroll: the
    /// bands beyond go, and the one the cut falls in loses its end.
    private mutating func trim(to length: Int) {
        while let last = strips.last, last.start >= length { strips.removeLast() }
        guard let last = strips.last else { return }
        let size = axis == .vertical ? last.frame.height : last.frame.width
        let keep = length - last.start
        guard keep < size else { return }
        let rect = axis == .vertical
            ? CGRect(x: 0, y: 0, width: last.frame.width, height: keep)
            : CGRect(x: 0, y: 0, width: keep, height: last.frame.height)
        if let cropped = last.frame.cropped(to: rect) {
            strips[strips.count - 1] = CaptureStrip(frame: cropped, start: last.start)
        }
    }

    /// Halves what is collected, once. Every band goes to half its size on
    /// both sides; those added from now on are halved as they come. No-op when
    /// already halved.
    mutating func shrinkToHalf() {
        guard !isShrunk, !strips.isEmpty else { return }
        var halved: [CaptureStrip] = []
        for strip in strips {
            let size = axis == .vertical ? strip.frame.height : strip.frame.width
            let start = strip.start / 2, end = (strip.start + size) / 2
            guard end > start, let frame = Self.halved(strip.frame, axis: axis, length: end - start) else { continue }
            halved.append(CaptureStrip(frame: frame, start: start))
        }
        strips = halved
        isShrunk = true
        totalLength = fullLength / 2
    }

    /// `frame` at half its size across the scroll and `length` pixels along it.
    private static func halved(_ frame: CaptureFrame, axis: ScrollAxis, length: Int) -> CaptureFrame? {
        let width = axis == .vertical ? (frame.width + 1) / 2 : length
        let height = axis == .vertical ? length : (frame.height + 1) / 2
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(frame.pixels) as CFData),
              let source = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: frame.colorSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: CaptureFrame.bitmapInfo),
                                   provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: frame.colorSpace,
                                      bitmapInfo: CaptureFrame.bitmapInfo),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                                count: context.bytesPerRow * height))
        return CaptureFrame(width: width, height: height, pixels: bytes, colorSpace: frame.colorSpace)
    }

    mutating func reset() {
        strips.removeAll(keepingCapacity: false)
        totalLength = 0
        fullLength = 0
        isShrunk = false
        viewportWidth = 0
        viewportHeight = 0
        lastFrame = nil
        lastSkip = 0
        lastMovement = 0
        skipBeforeLast = 0
        lastSeam = nil
    }

    func makeImage(maxPixels: Int? = nil) throws -> CGImage {
        guard let first = strips.first else { throw FrameMatchError.noReliableMotion }
        let width = axis == .vertical ? first.frame.width : totalLength
        let height = axis == .vertical ? totalLength : first.frame.height
        let along = axis == .vertical ? height : width
        let crossSize = axis == .vertical ? width : height
        let limit = ScrollLengthLimit.effectiveLimit(limit: maxLength, crossSize: crossSize)
        let pixelLimit = maxPixels ?? limit * crossSize
        guard width > 0, height > 0, along <= limit,
              width * height <= pixelLimit else { throw FrameMatchError.outputLimitExceeded }
        // Bands go straight into the one output buffer: no intermediate copy.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: first.frame.colorSpace,
                                      bitmapInfo: CaptureFrame.bitmapInfo),
              let data = context.data
        else { throw FrameMatchError.outputLimitExceeded }
        let output = data.assumingMemoryBound(to: UInt8.self)
        let outputRow = context.bytesPerRow
        for strip in strips {
            let rowBytes = strip.frame.width * 4
            strip.frame.pixels.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                for y in 0..<strip.frame.height {
                    let target = axis == .vertical
                        ? (strip.start + y) * outputRow
                        : y * outputRow + strip.start * 4
                    (output + target).update(from: base + y * rowBytes, count: rowBytes)
                }
            }
        }
        guard let image = context.makeImage() else { throw FrameMatchError.outputLimitExceeded }
        return image
    }
}
