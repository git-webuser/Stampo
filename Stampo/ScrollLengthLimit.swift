import CoreGraphics
import Foundation

/// How long a scrolling capture may grow, and what that comes to in screens
/// and bytes — the answer the Settings row shows beside the choice.
nonisolated enum ScrollLengthLimit {
    /// The lengths offered, in pixels along the scroll. Memory follows the
    /// choice: the image is this long by as wide as the window, at four bytes a
    /// pixel while it is assembled.
    static let options = [10_000, 20_000, 40_000]
    /// The longest on offer: a long page — a product page, say — reaches its
    /// footer without a trip to Settings. The shorter two are there for a
    /// smaller file.
    static let `default` = 40_000

    /// The most pixels the assembled image may hold, whatever the length chosen:
    /// 120 M is about half a gigabyte of RGBA, and the image is held whole while
    /// it is written. The longest it can be is this over its width — so a wide
    /// window reaches its limit sooner than a narrow one.
    static let maxOutputPixels = 120_000_000

    /// The length at which a capture actually stops: the one chosen, or what the
    /// memory ceiling allows at this width if that is less. `crossSize` is the
    /// image's other side in its own pixels — half the window's after a shrink,
    /// which is how the shrink makes room twice over.
    static func effectiveLimit(limit: Int, crossSize: Int) -> Int {
        guard crossSize > 0 else { return limit }
        return min(limit, maxOutputPixels / crossSize)
    }

    /// A stored value that is not one of the options (a hand-edited default, a
    /// later version's) reads as the default rather than as an unbounded image.
    static func validated(_ stored: Int?) -> Int {
        guard let stored, options.contains(stored) else { return `default` }
        return stored
    }

    enum Action: Equatable {
        /// The next step fits under the limit.
        case fits
        /// It does not, and the image can drop to half resolution to make room.
        case shrink
        /// It does not, and nothing more can be done: save what there is.
        case stop
    }

    /// What to do when a step of the capture is about to be added. At the limit
    /// the image goes to half resolution — once, and only if the frames are
    /// above 1x, where half is still the resolution of an ordinary screenshot —
    /// and carries on; otherwise it stops there and saves.
    static func action(lengthAfterAdding: Int, limit: Int, shrinkToFit: Bool,
                       frameScale: CGFloat, alreadyShrunk: Bool) -> Action {
        if lengthAfterAdding <= limit { return .fits }
        return shrinkToFit && frameScale > 1 && !alreadyShrunk ? .shrink : .stop
    }

    struct Estimate: Equatable {
        /// About how many screens of the page the limit holds.
        let screens: Int
        /// Size of the saved file, in bytes. A range for the compressed
        /// formats, whose size depends on how busy the page is; one value for
        /// TIFF, which is not compressed.
        let bytes: ClosedRange<Int64>
    }

    /// Bytes a pixel takes in the saved file, low and high. Measured rather than
    /// derived: a page of text and flat colour compresses to a fraction of a
    /// photograph's size.
    static func bytesPerPixel(format: String) -> ClosedRange<Double> {
        switch format {
        case "jpg", "jpeg": return 0.1...0.3
        case "tiff", "tif": return 4.0...4.0
        default:            return 0.15...0.6   // PNG
        }
    }

    /// What `limit` pixels of scroll come to on a screen of `screenPoints` at
    /// `backingScale`. A step is 0.8 of a screen's height, as the capture's
    /// frames overlap; the width of the image is the screen's width, which is
    /// the most a maximised window gives.
    static func estimate(limit: Int, format: String, screenPoints: CGSize,
                         backingScale: CGFloat) -> Estimate {
        let scale = max(1, backingScale)
        let stepPixels = max(1, Double(screenPoints.height) * Double(scale) * 0.8)
        let screens = max(1, Int((Double(limit) / stepPixels).rounded()))
        let pixels = Double(limit) * Double(screenPoints.width) * Double(scale)
        let perPixel = bytesPerPixel(format: format)
        return Estimate(screens: screens,
                        bytes: Int64(pixels * perPixel.lowerBound)...Int64(pixels * perPixel.upperBound))
    }
}
