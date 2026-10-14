import CoreGraphics
import Foundation

/// The density a scrolling image is saved at. The window was captured at the display's scale — two pixels to a
/// point on a Retina screen — and halved once when the image had to be fitted under the limit: the file says so,
/// so that a viewer shows it at the size the page had on the screen (Preview at "Actual Size", pasted into a
/// document) and not at one pixel to a point, twice as large and softer. The pixels and the limit are not touched.
nonisolated enum ScrollImageDensity {
    /// How many pixels of the image are a point of the screen the page was on: the display's scale, and half of it
    /// once the image was halved. A scale that is not a number to divide by is one pixel to a point.
    static func pixelsPerPoint(scale: CGFloat, shrunk: Bool) -> Double {
        let value = Double(scale)
        guard value.isFinite, value > 0 else { return 1 }
        return shrunk ? value / 2 : value
    }

    /// The density, in dots per inch: 144 for an image of a Retina screen, 72 halved, 72 for a screen of one pixel to
    /// a point and 36 halved.
    static func dpi(pixelsPerPoint: Double) -> Double {
        72 * pixelsPerPoint
    }

    /// The size, in points, an image of `pixelsWide` by `pixelsHigh` is saved to say it has (`NSBitmapImageRep.size`).
    static func pointSize(pixelsWide: Int, pixelsHigh: Int, pixelsPerPoint: Double) -> CGSize {
        let ratio = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
        return CGSize(width: Double(pixelsWide) / ratio, height: Double(pixelsHigh) / ratio)
    }
}

/// What a finished scrolling capture hands over: the image and how many of its pixels are a point of the screen.
struct ScrollingCaptureResult {
    let image: CGImage
    let pixelsPerPoint: Double
}
