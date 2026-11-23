import CoreGraphics
import Testing
@testable import Stampo

/// A scroll area whose frame is fractional in pixels: Accessibility reports points, so x = 10.5 is half a pixel
/// on a 1× screen, and a quarter of a point is half a pixel on a 2× one.
@Suite struct ScrollFractionalAreaTests {
    private let windowBounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    /// A window frame in which every pixel says where it is.
    private func windowFrame(scale: CGFloat) -> CaptureFrame {
        let width = Int(windowBounds.width * scale), height = Int(windowBounds.height * scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = UInt8(x & 255)
                bytes[index + 1] = UInt8(x >> 8)
                bytes[index + 2] = UInt8(y & 255)
                bytes[index + 3] = UInt8(y >> 8)
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func viewport(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> ScrollViewport {
        ScrollViewport(windowRect: CGRect(x: x, y: y, width: width, height: height),
                       relativeScrollPoint: CGPoint(x: 50, y: 50), windowBounds: windowBounds)
    }

    /// The chain of one capture: the area, the frame of the probe cut from it, the viewport that the probe's
    /// moving rectangle gives, and the next frame cut from that viewport. The next frame has to be the part of
    /// the window that the probe's frame was — `append` and the matcher refuse frames of unequal sizes.
    @MainActor
    @Test(arguments: [(CGFloat(1), CGFloat(0.5)), (CGFloat(2), CGFloat(0.25)), (CGFloat(3), CGFloat(0.5) / 3)])
    func theFrameAfterTheProbeHasTheSizeAndThePlaceOfTheProbeFrame(scale: CGFloat, fraction: CGFloat) throws {
        let window = windowFrame(scale: scale)
        let area = viewport(x: 10 + fraction, y: 20 + fraction, width: 120, height: 150)
        let initial = try #require(window.cropped(to: ScrollingCaptureSession.pixelRect(of: area, scale: scale)))
        // What the probe found moving, inside its frame, in whole pixels.
        let moving = CGRect(x: 6, y: 10, width: 50 * scale, height: 80 * scale)
        let first = try #require(initial.cropped(to: moving))

        let derived = try #require(area.cropped(to: moving, backingScale: scale))
        let next = try #require(window.cropped(to: ScrollingCaptureSession.pixelRect(of: derived, scale: scale)))
        #expect(next.width == first.width && next.height == first.height,
                "scale \(scale): \(next.width)×\(next.height) after \(first.width)×\(first.height)")
        #expect(next.pixels == first.pixels, "scale \(scale): the same part of the window")
    }

    /// An area that is whole in pixels is cut as it was before the rounding: the rectangle is the one the points
    /// give. Only values that are exact in binary are used, so that the expectation is not itself a rounding.
    @MainActor
    @Test(arguments: [
        (CGFloat(1), CGRect(x: 10, y: 20, width: 120, height: 150)),
        (CGFloat(1), CGRect(x: 0, y: 0, width: 400, height: 300)),
        (CGFloat(2), CGRect(x: 10, y: 20, width: 120, height: 150)),
        (CGFloat(2), CGRect(x: 10.5, y: 20.5, width: 120.5, height: 150.5)),
        (CGFloat(3), CGRect(x: 10, y: 20, width: 120, height: 150)),
        (CGFloat(3), CGRect(x: 0, y: 7, width: 400, height: 293)),
    ])
    func anAreaWholeInPixelsKeepsItsRectangle(scale: CGFloat, area: CGRect) {
        let rect = ScrollingCaptureSession.pixelRect(of: viewport(x: area.minX, y: area.minY,
                                                                 width: area.width, height: area.height),
                                                    scale: scale)
        #expect(rect == CGRect(x: area.minX * scale, y: area.minY * scale,
                               width: area.width * scale, height: area.height * scale))
    }

    /// A fractional edge is rounded: the start down, the length to the nearest pixel.
    @MainActor
    @Test func aFractionalEdgeIsRoundedToWholePixels() {
        let rect = ScrollingCaptureSession.pixelRect(of: viewport(x: 10.5, y: 20.75, width: 100.25, height: 50.5),
                                                    scale: 1)
        #expect(rect == CGRect(x: 10, y: 20, width: 100, height: 51))
    }
}
