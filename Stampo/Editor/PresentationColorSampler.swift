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

    /// Average of a block of premultiplied RGBA8 pixels (internal for tests).
    static func averageColor(in pixels: UnsafeRawBufferPointer,
                             bytesPerRow: Int,
                             xRange: Range<Int>,
                             yRange: Range<Int>) -> Presentation.Color? {
        // Premultiplied channels and alpha are summed separately and divided
        // once at the end: Σ(colour × alpha) / Σ alpha is the average of the
        // *colours*, each weighted by how much of it there is. A transparent
        // pixel weighs nothing, and a faint shadow pixel weighs its alpha.
        // Dividing by the number of pixels instead — or un-premultiplying each
        // pixel first — turns the see-through margin of a window screenshot
        // into black, and the page's default colour came out darker than the
        // window it was taken from.
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
                red += CGFloat(pixels[offset])
                green += CGFloat(pixels[offset + 1])
                blue += CGFloat(pixels[offset + 2])
                alpha += CGFloat(pixels[offset + 3])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        // Nothing visible in the block: there is no colour to report.
        guard alpha > 0 else { return Presentation.Color(red: 0, green: 0, blue: 0, alpha: 0) }
        return Presentation.Color(red: min(1, red / alpha),
                                 green: min(1, green / alpha),
                                 blue: min(1, blue / alpha),
                                 alpha: alpha / (255 * count))
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
