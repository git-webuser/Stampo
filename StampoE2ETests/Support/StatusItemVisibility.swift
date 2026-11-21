import Foundation
import CoreGraphics

/// Detect foreground in the center of the status item's own AX frame.
/// Neighboring menu-bar icons can overlap its outer edge when it is hidden.
enum StatusItemVisibility {
    struct Measurement: Codable {
        let frame: String
        let sampleFrame: String
        let backgroundRGB: [Int]
        let foregroundPixels: Int
        let samplePixels: Int
        let maximumContrast: Int
        let contrastThreshold: Int
        let minimumFraction: Double
        let foregroundFraction: Double
        let drawn: Bool
        let reason: String
    }

    struct Window: Codable {
        let number: Int?
        let layer: Int?
        let frame: String
        let onScreen: Bool
        let onScreenReported: Bool
        let alpha: Double?
        let matchesStatusFrame: Bool
    }

    static func measure(png: URL, frame: CGRect, display: CGRect) throws -> Measurement {
        let contrastThreshold = 80
        let minimumFraction = 0.05
        guard display.contains(frame), frame.width >= 14, frame.height >= 18 else {
            return Measurement(frame: NSStringFromRect(frame), sampleFrame: "unavailable", backgroundRGB: [],
                foregroundPixels: 0, samplePixels: 0, maximumContrast: 0,
                contrastThreshold: contrastThreshold, minimumFraction: minimumFraction,
                foregroundFraction: 0, drawn: false, reason: "AX frame is outside the primary display or too small")
        }
        let bitmap = try Files.Bitmap(png: png)
        let scale = CGFloat(bitmap.width) / display.width
        guard abs(CGFloat(bitmap.height) / display.height - scale) < 0.001 else {
            throw E2EFailure("Status screenshot has nonuniform display scale")
        }
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - display.minX) * scale, y: (rect.minY - display.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale).integral
        }
        let outer = pixels(frame)
        var channels = [[Int]](repeating: [], count: 3)
        // The median of the top/bottom 1 pt strips estimates the local bar
        // background without accepting the neighboring chevron as our glyph.
        for y in Int(outer.minY)..<Int(outer.maxY)
            where y < Int(outer.minY + scale) || y >= Int(outer.maxY - scale) {
            for x in Int(outer.minX)..<Int(outer.maxX) {
                let rgba = try bitmap.rgba(x: x, y: y)
                for channel in 0..<3 { channels[channel].append(Int(rgba[channel])) }
            }
        }
        let background = channels.map { $0.sorted()[$0.count / 2] }
        let sampleFrame = CGRect(x: frame.midX - 7, y: frame.midY - 9, width: 14, height: 18)
        let sample = pixels(sampleFrame)
        var foreground = 0
        var total = 0
        var maximum = 0
        for y in Int(sample.minY)..<Int(sample.maxY) {
            for x in Int(sample.minX)..<Int(sample.maxX) {
                let rgba = try bitmap.rgba(x: x, y: y)
                let contrast = (0..<3).map { abs(Int(rgba[$0]) - background[$0]) }.max() ?? 0
                if contrast >= contrastThreshold { foreground += 1 }
                total += 1
                maximum = max(maximum, contrast)
            }
        }
        let fraction = Double(foreground) / Double(total)
        return Measurement(frame: NSStringFromRect(frame), sampleFrame: NSStringFromRect(sampleFrame),
            backgroundRGB: background, foregroundPixels: foreground, samplePixels: total,
            maximumContrast: maximum, contrastThreshold: contrastThreshold,
            minimumFraction: minimumFraction, foregroundFraction: fraction,
            drawn: fraction >= minimumFraction, reason: "central foreground contrast")
    }

    static func windows(pid: pid_t, statusFrame: CGRect) throws -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw E2EFailure("Cannot read status-item WindowServer diagnostics")
        }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) }.map { info in
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let rect = CGRect(x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                              y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                              width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                              height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
            return Window(number: info[kCGWindowNumber as String] as? Int,
                layer: info[kCGWindowLayer as String] as? Int, frame: NSStringFromRect(rect),
                onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                onScreenReported: info[kCGWindowIsOnscreen as String] != nil,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                matchesStatusFrame: rect.width <= statusFrame.width + 4 && rect.height <= statusFrame.height + 8
                    && rect.contains(CGPoint(x: statusFrame.midX, y: statusFrame.midY)))
        }
    }
}
