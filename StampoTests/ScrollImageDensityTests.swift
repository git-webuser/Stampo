import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Stampo

/// The density a scrolling image is saved at: how many of its pixels are a point of the screen it was captured on.
@Suite struct ScrollImageDensityTests {
    /// Retina: 144 dots to the inch, 72 when the image was halved to fit the limit; a screen of one pixel to a point:
    /// 72, and 36 halved.
    @Test func theDensityIsTheScaleOfTheScreenAndHalfOfItWhenTheImageWasHalved() {
        #expect(ScrollImageDensity.pixelsPerPoint(scale: 2, shrunk: false) == 2)
        #expect(ScrollImageDensity.pixelsPerPoint(scale: 2, shrunk: true) == 1)
        #expect(ScrollImageDensity.pixelsPerPoint(scale: 1, shrunk: false) == 1)
        #expect(ScrollImageDensity.pixelsPerPoint(scale: 1, shrunk: true) == 0.5)
        #expect(ScrollImageDensity.dpi(pixelsPerPoint: 2) == 144)
        #expect(ScrollImageDensity.dpi(pixelsPerPoint: 1) == 72)
        #expect(ScrollImageDensity.dpi(pixelsPerPoint: 0.5) == 36)
    }

    /// A scale that is nothing to divide by is one pixel to a point, in the size as well.
    @Test func aScaleThatIsNotANumberToDivideByIsOnePixelToAPoint() {
        #expect(ScrollImageDensity.pixelsPerPoint(scale: 0, shrunk: false) == 1)
        #expect(ScrollImageDensity.pixelsPerPoint(scale: -2, shrunk: true) == 1)
        #expect(ScrollImageDensity.pixelsPerPoint(scale: .nan, shrunk: false) == 1)
        let size = ScrollImageDensity.pointSize(pixelsWide: 100, pixelsHigh: 40, pixelsPerPoint: 0)
        #expect(size == CGSize(width: 100, height: 40))
    }

    @Test func theSizeInPointsIsThePixelsOverThePixelsToAPoint() {
        #expect(ScrollImageDensity.pointSize(pixelsWide: 2516, pixelsHigh: 14216, pixelsPerPoint: 2)
                == CGSize(width: 1258, height: 7108))
        #expect(ScrollImageDensity.pointSize(pixelsWide: 1258, pixelsHigh: 7108, pixelsPerPoint: 1)
                == CGSize(width: 1258, height: 7108))
        #expect(ScrollImageDensity.pointSize(pixelsWide: 100, pixelsHigh: 50, pixelsPerPoint: 0.5)
                == CGSize(width: 200, height: 100))
    }

    private func image(width: Int = 64, height: Int = 40) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 8, y: 8, width: width / 2, height: height / 2))
        return try #require(context.makeImage())
    }

    /// The density the file says: nil when it says none, which every viewer reads as 72.
    private func density(of data: Data) throws -> (width: Double?, height: Double?, pixelsWide: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return ((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
                (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
                try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue))
    }

    /// The density reaches the file in every format the settings offer, and the pixels are the same.
    @Test(arguments: ["png", "jpg", "tiff"]) func theEncodedFileSaysTheDensityInEveryFormat(format: String) throws {
        let picture = try image()
        for (pixelsPerPoint, dpi) in [(2.0, 144.0), (1.0, 72.0), (0.5, 36.0)] {
            let data = try #require(ScreenshotService.scrollingImageData(picture, pixelsPerPoint: pixelsPerPoint,
                                                                         format: format))
            let found = try density(of: data)
            // One pixel to a point is 72, which the encoders write as no density at all.
            let width = found.width ?? 72, height = found.height ?? 72
            #expect(abs(width - dpi) < 0.5, "\(format) at \(pixelsPerPoint): \(width) dpi")
            #expect(abs(height - dpi) < 0.5)
            #expect(found.pixelsWide == 64)
            // The two that are not 72 say so.
            #expect((found.width != nil) == (dpi != 72))
        }
    }
}
