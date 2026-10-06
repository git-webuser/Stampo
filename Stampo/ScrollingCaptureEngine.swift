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
}

nonisolated enum FrameMatchError: Error, Equatable, LocalizedError {
    case noReliableMotion
    case ambiguousMotion
    case crossAxisMotion
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .noReliableMotion: return "The area doesn't scroll. Click inside the page or table and start again."
        case .ambiguousMotion: return "The content is too uniform to align. The capture stopped to avoid a broken image."
        case .crossAxisMotion: return "The content moved sideways. Don't move the window during the capture."
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
    static func match(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                      maximumOffset: Int, minimumConfidence: Double = 0.72) throws -> FrameMatch {
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

        var agreeing = 0, decisive = 0, against = 0, tileMargin = 0.0
        for t in moving {
            let curve = tileCost[t]
            let atBest = curve[best]
            guard atBest.isFinite, let lowest = curve.filter(\.isFinite).min() else { continue }
            guard atBest - lowest <= tolerance else {
                if uniqueBest(curve, tolerance: tolerance) != nil { against += 1 }
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
        guard decisive >= 1 || frameMargin >= 0.5, against <= max(1, moving.count / 5) else { throw FrameMatchError.ambiguousMotion }
        let margin = max(0, min(1, max(frameMargin, tileMargin)))
        let confidence = min(1, (1 - agg[best]) * 0.55 + margin * 0.45)
        guard confidence >= minimumConfidence else { throw FrameMatchError.ambiguousMotion }
        return FrameMatch(offset: best, confidence: confidence, independentRegions: agreeing)
    }

    /// Tiles the sample grid is cut into, along each axis of the frame.
    private static let tileRows = 4, tileColumns = 5
    /// How far a tile's cost may sit above its own best and still be said to
    /// agree with an offset, and the cost under which a tile fits at all.
    private static let tolerance = 0.005, fitThreshold = 0.03

    /// Cost of every offset from 0 to `limit`, tile by tile.
    ///
    /// Samples sit at fixed places in the CURRENT frame; an offset is scored on
    /// the samples whose source row still lies in the previous frame, so a
    /// large offset is judged on fewer of them — and an offset where a tile has
    /// fewer than a quarter of its samples is not scored at all (infinite).
    private static func tileCurves(previous: CaptureFrame, current: CaptureFrame,
                                   axis: ScrollAxis, limit: Int)
        -> (sum: [[Double]], count: [[Int]], cost: [[Double]], minimumSamples: Int) {
        let w = previous.width, h = previous.height
        let axisLength = axis == .vertical ? h : w
        let crossLength = axis == .vertical ? w : h
        let alongCount = min(96, axisLength), acrossCount = min(48, crossLength)
        let tileCount = tileRows * tileColumns
        let alongPos = (0..<alongCount).map { min(axisLength - 1, Int((Double($0) + 0.5) / Double(alongCount) * Double(axisLength))) }
        let crossPos = (0..<acrossCount).map { min(crossLength - 1, Int((Double($0) + 0.5) / Double(acrossCount) * Double(crossLength))) }
        var tileSum = Array(repeating: [Double](repeating: 0, count: limit + 1), count: tileCount)
        var tileCnt = Array(repeating: [Int](repeating: 0, count: limit + 1), count: tileCount)
        for delta in 0...limit {
            for (ai, cAxis) in alongPos.enumerated() where cAxis + delta < axisLength {
                let row = ai * tileRows / alongCount
                for (ci, cross) in crossPos.enumerated() {
                    let i: Int, j: Int
                    if axis == .vertical { i = ((cAxis + delta) * w + cross) * 4; j = (cAxis * w + cross) * 4 }
                    else { i = (cross * w + cAxis + delta) * 4; j = (cross * w + cAxis) * 4 }
                    let e = Double(abs(Int(previous.pixels[i]) - Int(current.pixels[j]))
                                 + abs(Int(previous.pixels[i + 1]) - Int(current.pixels[j + 1]))
                                 + abs(Int(previous.pixels[i + 2]) - Int(current.pixels[j + 2]))) / 765.0
                    let t = row * tileColumns + ci * tileColumns / acrossCount
                    tileSum[t][delta] += e; tileCnt[t][delta] += 1
                }
            }
        }
        let perTile = max(1, (alongCount / tileRows) * (acrossCount / tileColumns))
        let minSamples = max(4, perTile / 4)
        let cost: [[Double]] = (0..<tileCount).map { t in
            (0...limit).map { d in tileCnt[t][d] >= minSamples ? tileSum[t][d] / Double(tileCnt[t][d]) : .infinity }
        }
        return (tileSum, tileCnt, cost, minSamples)
    }

    /// Whether `offset` is consistent with the frames when they cannot pin it
    /// down themselves: every tile that fits some offset well must fit this
    /// one about as well. Tiles that change by themselves, stand still or are
    /// blank have no say. Nil when the frames contradict the prediction.
    static func verifyPredicted(previous: CaptureFrame, current: CaptureFrame, axis: ScrollAxis,
                                offset: Int, searchLimit: Int) -> (consistent: Int, against: Int)? {
        let axisLength = axis == .vertical ? previous.height : previous.width
        let limit = min(max(offset + 2, searchLimit), axisLength * 3 / 4)
        guard offset > 0, offset <= limit else { return nil }
        let tiles = tileCurves(previous: previous, current: current, axis: axis, limit: limit)
        var consistent = 0, against = 0, moving = 0
        for t in 0..<tiles.cost.count {
            let curve = tiles.cost[t]
            guard let lowest = curve.filter(\.isFinite).min(), lowest <= fitThreshold else { continue }
            let still = curve[0...2].filter(\.isFinite).min() ?? .infinity
            if still - lowest <= tolerance { continue }
            moving += 1
            guard curve[offset].isFinite else { continue }
            if curve[offset] - lowest <= tolerance { consistent += 1 }
            else if uniqueBest(curve, tolerance: tolerance) != nil { against += 1 }
        }
        guard against <= max(0, moving / 5) else { return nil }
        return (consistent, against)
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
    let frame: CaptureFrame
    let start: Int
}

/// Keeps independent bands until the one final allocation, avoiding repeated
/// reallocation and copy of an ever-growing bitmap at every scroll step.
nonisolated struct ImageAssembler: Sendable {
    /// The stitched image stops growing at either limit (60 M pixels is
    /// about 240 MB of RGBA).
    static let maxOutputPixels = 60_000_000
    static let maxOutputLength = 20_000

    let axis: ScrollAxis
    private(set) var strips: [CaptureStrip] = []
    private(set) var totalLength = 0
    private(set) var viewportWidth = 0
    private(set) var viewportHeight = 0

    mutating func begin(with frame: CaptureFrame) {
        guard strips.isEmpty else { return }
        viewportWidth = frame.width
        viewportHeight = frame.height
        let length = axis == .vertical ? frame.height : frame.width
        strips.append(CaptureStrip(frame: frame, start: 0))
        totalLength = length
    }

    mutating func append(_ frame: CaptureFrame, movement: Int) throws {
        guard !strips.isEmpty, frame.width == viewportWidth, frame.height == viewportHeight,
              movement > 0, movement < (axis == .vertical ? frame.height : frame.width)
        else { throw FrameMatchError.noReliableMotion }
        // Add only the newly exposed band. Direction is normalized so the
        // assembled document reads top-to-bottom / left-to-right.
        let band = axis == .vertical
            ? frame.cropped(to: CGRect(x: 0, y: frame.height - movement, width: frame.width, height: movement))
            : frame.cropped(to: CGRect(x: frame.width - movement, y: 0, width: movement, height: frame.height))
        guard let band else { throw FrameMatchError.noReliableMotion }
        strips.append(CaptureStrip(frame: band, start: totalLength))
        totalLength += movement
    }

    mutating func reset() {
        strips.removeAll(keepingCapacity: false)
        totalLength = 0
        viewportWidth = 0
        viewportHeight = 0
    }

    func makeImage(maxPixels: Int = ImageAssembler.maxOutputPixels) throws -> CGImage {
        guard let first = strips.first else { throw FrameMatchError.noReliableMotion }
        let width = axis == .vertical ? first.frame.width : totalLength
        let height = axis == .vertical ? totalLength : first.frame.height
        guard width > 0, height > 0, width <= Self.maxOutputLength, height <= Self.maxOutputLength,
              width * height <= maxPixels else { throw FrameMatchError.outputLimitExceeded }
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
