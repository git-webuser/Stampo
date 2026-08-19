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
                                       height: thumbnailSize) else { return [] }
        let bitmap = NSBitmapImageRep(cgImage: reduced)
        let halfWidth = max(1, bitmap.pixelsWide / 2)
        let halfHeight = max(1, bitmap.pixelsHigh / 2)
        return [
            (0, 0), (1, 0), (0, 1), (1, 1)
        ].compactMap { column, row in
            averageColor(in: bitmap,
                         xRange: (column * halfWidth)..<min(bitmap.pixelsWide,
                                                            (column + 1) * halfWidth),
                         yRange: (row * halfHeight)..<min(bitmap.pixelsHigh,
                                                           (row + 1) * halfHeight))
        }
    }

    private static func averageColor(in bitmap: NSBitmapImageRep,
                                     xRange: Range<Int>,
                                     yRange: Range<Int>) -> Presentation.Color? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0
        for y in yRange {
            for x in xRange {
                guard let source = bitmap.colorAt(x: x, y: y),
                      let color = source.usingColorSpace(.sRGB) else { continue }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                alpha += color.alphaComponent
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
