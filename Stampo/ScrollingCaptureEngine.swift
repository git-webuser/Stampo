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

    var cgAxis: CGVector { self == .vertical ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0) }
}

/// A compact, immutable RGBA frame. Pixel coordinates use the same top-left
/// origin as CGImage and ScreenCaptureKit.
nonisolated struct CaptureFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 12_000, h <= 12_000,
              w * h <= 25_000_000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard rendered else { return nil }
        self.init(width: w, height: h, pixels: bytes)
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
        return CaptureFrame(width: x1 - x0, height: y1 - y0, pixels: out)
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
        case .noReliableMotion: return "The scrolling area did not move enough to match frames. Try clicking inside the page or table and start again."
        case .ambiguousMotion: return "The visible content repeats too much to align reliably. The capture stopped to avoid a damaged image."
        case .crossAxisMotion: return "The window moved in both directions. Keep the window size stable and scroll in one direction."
        case .outputLimitExceeded: return "The scrolling image reached the configured size limit."
        }
    }
}

/// Matches several spatially separated patches so a repeated line of text or
/// a small animation cannot independently decide the whole-frame offset.
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

        // A very small coarse grid is cheap at Retina sizes and samples both
        // text/edges and smooth image regions. Candidate offsets are one pixel
        // apart; the result is the measured movement, not the event delta.
        let alongCount = min(96, axisLength)
        let acrossCount = min(48, crossLength)
        let along = stride(from: 0, to: alongCount, by: 1).map { (Double($0) + 0.5) / Double(alongCount) }
        let across = stride(from: 0, to: acrossCount, by: 1).map { (Double($0) + 0.5) / Double(acrossCount) }
        let regionCount = 5
        var costs = [Double](repeating: .infinity, count: limit + 1)
        var regionCosts = Array(repeating: [Double](repeating: .infinity, count: limit + 1), count: regionCount)

        for delta in 0...limit {
            let usable = axisLength - delta
            guard usable > 0 else { continue }
            var allCost = 0.0, allSamples = 0
            var sums = [Double](repeating: 0, count: regionCount)
            var counts = [Int](repeating: 0, count: regionCount)
            for a in along {
                let pAxis = min(axisLength - 1, Int(a * Double(usable)))
                let cAxis = pAxis
                // Region scores are split on the cross axis and vote separately.
                for (crossIndex, c) in across.enumerated() {
                    let cross = min(crossLength - 1, Int(c * Double(crossLength)))
                    let px: Int, py: Int, cx: Int, cy: Int
                    if axis == .vertical {
                        px = cross; py = pAxis + delta; cx = cross; cy = cAxis
                    } else {
                        px = pAxis + delta; py = cross; cx = cAxis; cy = cross
                    }
                    let i = (py * w + px) * 4, j = (cy * w + cx) * 4
                    let d0 = abs(Int(previous.pixels[i]) - Int(current.pixels[j]))
                    let d1 = abs(Int(previous.pixels[i + 1]) - Int(current.pixels[j + 1]))
                    let d2 = abs(Int(previous.pixels[i + 2]) - Int(current.pixels[j + 2]))
                    let error = Double(d0 + d1 + d2) / 765.0
                    allCost += error; allSamples += 1
                    let region = min(regionCount - 1, crossIndex * regionCount / max(1, across.count))
                    sums[region] += error; counts[region] += 1
                }
            }
            costs[delta] = allCost / Double(max(1, allSamples))
            for r in 0..<regionCount where counts[r] > 0 { regionCosts[r][delta] = sums[r] / Double(counts[r]) }
        }

        // A constant offset across independent patches is stronger than a
        // single low color error. We down-rank candidates that only fit one
        // part of the window (e.g. a blinking caret).
        let best = costs.indices.min { costs[$0] < costs[$1] } ?? 0
        guard best > 0, costs[best] < 0.20 else { throw FrameMatchError.noReliableMotion }

        // Measure perpendicular movement only after aligning the primary
        // displacement. Checking raw frame pairs confounds diagonal movement
        // with the much larger intended shift.
        let orthogonal = axis == .vertical ? ScrollAxis.horizontal : .vertical
        let crossLimit = min(20, (orthogonal == .vertical ? h : w) / 10)
        let residual = bestOrthogonalResidual(previous: previous, current: current,
                                             primaryAxis: axis, primaryOffset: best,
                                             limit: crossLimit)
        if abs(residual.offset) > 3, residual.error < 12 {
            throw FrameMatchError.crossAxisMotion
        }

        var agreeing = 0
        for region in regionCosts {
            if let candidate = region.indices.min(by: { region[$0] < region[$1] }),
               abs(candidate - best) <= 2, region[candidate] < 0.24 { agreeing += 1 }
        }
        guard agreeing >= 3 else { throw FrameMatchError.ambiguousMotion }
        let alternative = costs.enumerated().filter { abs($0.offset - best) > 2 }.map(\.element).min() ?? 1
        let margin = max(0, min(1, (alternative - costs[best]) / max(alternative, 0.015)))
        let confidence = min(1, (1 - costs[best]) * 0.55 + margin * 0.45)
        guard confidence >= minimumConfidence else { throw FrameMatchError.ambiguousMotion }

        return FrameMatch(offset: best, confidence: confidence, independentRegions: agreeing)
    }

    static func bestOrthogonalResidual(previous: CaptureFrame, current: CaptureFrame,
                                       primaryAxis: ScrollAxis, primaryOffset: Int,
                                       limit: Int) -> (offset: Int, error: Double) {
        let width = previous.width, height = previous.height
        let range = primaryAxis == .vertical ? width : height
        let residualLimit = min(max(0, limit), max(0, range / 4))
        guard residualLimit > 0 else { return (0, .infinity) }
        var best = (offset: 0, error: Double.infinity)

        for residual in (-residualLimit)...residualLimit {
            var error = 0.0, samples = 0
            if primaryAxis == .vertical {
                let crossStart = max(0, -residual)
                let crossEnd = min(width, width - residual)
                let alongEnd = height - primaryOffset
                guard crossEnd > crossStart, alongEnd > 0 else { continue }
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
                guard crossEnd > crossStart, alongEnd > 0 else { continue }
                for y in stride(from: crossStart, to: crossEnd, by: max(1, (crossEnd - crossStart) / 24)) {
                    for x in stride(from: 0, to: alongEnd, by: max(1, alongEnd / 48)) {
                        let previousIndex = ((y + residual) * width + x + primaryOffset) * 4
                        let currentIndex = (y * width + x) * 4
                        error += channelError(previous.pixels, previousIndex, current.pixels, currentIndex)
                        samples += 3
                    }
                }
            }
            let score = error / Double(max(1, samples))
            if score < best.error { best = (residual, score) }
        }
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

    func makeImage(maxPixels: Int) throws -> CGImage {
        guard let first = strips.first else { throw FrameMatchError.noReliableMotion }
        let width = axis == .vertical ? first.frame.width : totalLength
        let height = axis == .vertical ? totalLength : first.frame.height
        guard width > 0, height > 0, width <= 20_000, height <= 20_000,
              width * height <= maxPixels else { throw FrameMatchError.outputLimitExceeded }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for strip in strips {
            let rowWidth = strip.frame.width
            if axis == .vertical {
                for y in 0..<strip.frame.height {
                    let src = y * rowWidth * 4, dst = (strip.start + y) * width * 4
                    bytes.replaceSubrange(dst..<(dst + rowWidth * 4), with: strip.frame.pixels[src..<(src + rowWidth * 4)])
                }
            } else {
                for y in 0..<height {
                    let src = y * rowWidth * 4, dst = (y * width + strip.start) * 4
                    bytes.replaceSubrange(dst..<(dst + rowWidth * 4), with: strip.frame.pixels[src..<(src + rowWidth * 4)])
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FrameMatchError.noReliableMotion }
        return image
    }
}
