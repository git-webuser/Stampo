import XCTest
import CoreGraphics
import ImageIO

@MainActor
final class BitmapTests: XCTestCase {
    func testDecodedRowsUseTopLeftOrigin() throws {
        let artifacts = try Artifacts(test: self)
        // An asymmetric raw raster proves orientation; the red/blue fixture's
        // vertical symmetry could not reveal an inverted screenshot decoder.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                              0, 0, 255, 255, 255, 255, 0, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 8, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .relativeColorimetric))
        let png = artifacts.directory.appendingPathComponent("asymmetric-origin.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bitmap = try Files.Bitmap(png: png)
        XCTAssertEqual(try bitmap.rgba(x: 0, y: 0), [255, 0, 0, 255], "Top-left must be red")
        XCTAssertEqual(try bitmap.rgba(x: 1, y: 0), [0, 255, 0, 255], "Top-right must be green")
        XCTAssertEqual(try bitmap.rgba(x: 0, y: 1), [0, 0, 255, 255], "Bottom-left must be blue")
        XCTAssertEqual(try bitmap.rgba(x: 1, y: 1), [255, 255, 0, 255], "Bottom-right must be yellow")
    }
}
