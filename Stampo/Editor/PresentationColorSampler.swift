import AppKit

/// Extracts a small representative palette from a screenshot for the sampled
/// background. Downsampling to four quarter representatives avoids treating
/// window chrome at the exact corners as the whole image's palette.
enum PresentationColorSampler {
    static func colors(from image: CGImage) -> [Presentation.Color] {
        // Core Graphics' high-quality filter is designed for visual scaling,
        // not guaranteed area averaging when the destination is only 2×2.
        // Use a small thumbnail, then average each quadrant of that thumbnail;
        // this remains cheap in the inspector while making the representative
        // colors stable for window chrome, borders, and transparent corners.
        let thumbnailSize = 32
        guard let reduced = downsample(image,
                                       width: thumbnailSize,
                                       height: thumbnailSize),
              let data = reduced.dataProvider?.data else { return [] }
        let halfWidth = max(1, reduced.width / 2)
        let halfHeight = max(1, reduced.height / 2)
        return (data as Data).withUnsafeBytes { pixels in
            [(0, 0), (1, 0), (0, 1), (1, 1)].compactMap { column, row in
                averageColor(in: pixels, bytesPerRow: reduced.bytesPerRow,
                             xRange: (column * halfWidth)..<min(reduced.width,
                                                                (column + 1) * halfWidth),
                             yRange: (row * halfHeight)..<min(reduced.height,
                                                               (row + 1) * halfHeight))
            }
        }
    }

    private static func averageColor(in pixels: UnsafeRawBufferPointer,
                                     bytesPerRow: Int,
                                     xRange: Range<Int>,
                                     yRange: Range<Int>) -> Presentation.Color? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0
        for y in yRange {
            for x in xRange {
                // The thumbnail is sRGB RGBA. Read its bytes directly: colorAt
                // labels these numbers Generic RGB and shifts them on conversion.
                let offset = y * bytesPerRow + x * 4
                let a = CGFloat(pixels[offset + 3])
                if a > 0 {
                    red += CGFloat(pixels[offset]) / a
                    green += CGFloat(pixels[offset + 1]) / a
                    blue += CGFloat(pixels[offset + 2]) / a
                }
                alpha += a / 255
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Presentation.Color(red: red / count,
                                 green: green / count,
                                 blue: blue / count,
                                 alpha: alpha / count)
    }

    private static func downsample(_ image: CGImage,
                                   width: Int,
                                   height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()
    }
}
