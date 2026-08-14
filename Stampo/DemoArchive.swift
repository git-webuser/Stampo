#if DEBUG
import AppKit
import Foundation

/// Fills the archive with plausible-looking entries so the panel can be opened
/// and screenshotted with something in it, instead of the empty state a fresh
/// build always shows.
///
/// DEBUG only, and off unless explicitly asked for:
///
///     STAMPO_DEMO_ARCHIVE=1 open -a Stampo        # or the `-StampoDemoArchive`
///                                                 # launch argument in a scheme
///
/// The screenshots are drawn from scratch into a temporary folder — nothing is
/// read from the user's disk, and while demo mode is on the archive never
/// persists, so a real archive on this machine survives untouched.
nonisolated enum DemoArchive {
    static let isEnabled: Bool =
        ProcessInfo.processInfo.arguments.contains("-StampoDemoArchive")
            || ProcessInfo.processInfo.environment["STAMPO_DEMO_ARCHIVE"] == "1"

    /// Where the generated PNGs live for the lifetime of the run. A fixed name
    /// (not a random temp dir) so repeated launches reuse the same files rather
    /// than littering `$TMPDIR`.
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("StampoDemoArchive", isDirectory: true)
    }

    /// Entries are inserted at the front of the archive, so this list is walked
    /// back to front: the first element below ends up first in the panel.
    @MainActor
    static func populate(_ model: NotchArchiveModel) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        enum Entry {
            case shot(String, (CGContext, CGSize) -> Void)
            case color(String)
            /// `code` marks a payload rather than prose, so the demo archive
            /// exercises both kinds — the QR-shaped entries must not offer
            /// translation, and only real data proves that.
            case text(String, code: Bool = false)
        }

        let entries: [Entry] = [
            .shot("browser", drawBrowserWindow),
            .color("#FF6B4A"),
            .text("https://example.com/pricing?plan=team", code: true),
            .shot("chart", drawChart),
            .color("#2D6CDF"),
            .shot("terminal", drawTerminal),
            .text("""
                Stampo replaces the usual screenshot workflow with a panel that \
                opens when you click the notch.
                """),
            .color("#12B886"),
            .shot("poster", drawPoster),
            .color("#F4C744"),
            .text("WIFI:S:Demo Network;T:WPA;P:not-a-real-password;;", code: true),
            .color("#7B5CFF"),
        ]

        for entry in entries.reversed() {
            switch entry {
            case .shot(let name, let draw):
                if let url = writePNG(named: name, draw: draw) {
                    model.add(screenshotURL: url)
                }
            case .color(let hex):
                if let color = NSColor(hexString: hex) { model.add(color: color) }
            case .text(let text, let code):
                model.add(text: text, isCodePayload: code)
            }
        }
    }

    // MARK: - Image generation

    private static let size = CGSize(width: 1280, height: 800)

    /// Draws one demo capture and writes it as a PNG. Returns nil (and skips the
    /// entry) if the file can't be written — demo data is never worth a crash.
    private static func writePNG(named name: String, draw: (CGContext, CGSize) -> Void) -> URL? {
        let url = folder.appendingPathComponent("\(name).png")

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(context.cgContext, size)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Drawing helpers

    private static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        ctx.setFillColor(color.cgColor)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(rect)
        }
    }

    /// A run of grey bars standing in for a paragraph — the usual way a mockup
    /// says "text here" without inventing sentences nobody reads.
    private static func placeholderLines(
        _ ctx: CGContext,
        origin: CGPoint,
        width: CGFloat,
        count: Int,
        color: NSColor,
        lineHeight: CGFloat = 14,
        spacing: CGFloat = 24
    ) {
        for i in 0..<count {
            // Last line of a paragraph runs short, like real text does.
            let factor: CGFloat = (i == count - 1) ? 0.55 : (i % 3 == 1 ? 0.92 : 1.0)
            let rect = CGRect(
                x: origin.x,
                y: origin.y - CGFloat(i) * spacing,
                width: width * factor,
                height: lineHeight
            )
            fill(ctx, rect, color, radius: lineHeight / 2)
        }
    }

    /// Window chrome shared by the app mockups: title bar, traffic lights, and
    /// the rounded body the content is drawn into. Returns the content rect.
    private static func windowChrome(
        _ ctx: CGContext,
        size: CGSize,
        background: NSColor,
        chrome: NSColor
    ) -> CGRect {
        let frame = CGRect(origin: .zero, size: size).insetBy(dx: 48, dy: 48)
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        fill(ctx, frame, background, radius: 14)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        let barHeight: CGFloat = 52
        let bar = CGRect(x: frame.minX, y: frame.maxY - barHeight, width: frame.width, height: barHeight)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.clip()
        fill(ctx, bar, chrome)
        ctx.restoreGState()

        let lights: [NSColor] = [
            NSColor(srgbRed: 0.99, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 0.99, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1),
        ]
        for (i, color) in lights.enumerated() {
            let dot = CGRect(x: frame.minX + 22 + CGFloat(i) * 24, y: bar.midY - 7, width: 14, height: 14)
            fill(ctx, dot, color, radius: 7)
        }

        return frame.insetBy(dx: 0, dy: 0).divided(atDistance: barHeight, from: .maxYEdge).remainder
    }

    // MARK: - Demo captures

    private static func drawBrowserWindow(_ ctx: CGContext, size: CGSize) {
        fill(ctx, CGRect(origin: .zero, size: size), NSColor(srgbRed: 0.85, green: 0.88, blue: 0.94, alpha: 1))

        let content = windowChrome(
            ctx,
            size: size,
            background: .white,
            chrome: NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        )

        // Address bar.
        let address = CGRect(x: content.minX + 120, y: content.maxY + 14, width: content.width - 200, height: 24)
        fill(ctx, address, NSColor(srgbRed: 0.87, green: 0.88, blue: 0.91, alpha: 1), radius: 12)

        // Hero block, then two text columns.
        let hero = CGRect(x: content.minX + 40, y: content.maxY - 220, width: content.width - 80, height: 180)
        fill(ctx, hero, NSColor(srgbRed: 0.18, green: 0.42, blue: 0.87, alpha: 1), radius: 12)

        let columnWidth = (content.width - 120) / 2
        placeholderLines(
            ctx,
            origin: CGPoint(x: content.minX + 40, y: content.maxY - 280),
            width: columnWidth,
            count: 6,
            color: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.89, alpha: 1)
        )
        placeholderLines(
            ctx,
            origin: CGPoint(x: content.minX + 80 + columnWidth, y: content.maxY - 280),
            width: columnWidth,
            count: 6,
            color: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.89, alpha: 1)
        )
    }

    private static func drawTerminal(_ ctx: CGContext, size: CGSize) {
        fill(ctx, CGRect(origin: .zero, size: size), NSColor(srgbRed: 0.11, green: 0.12, blue: 0.16, alpha: 1))

        let content = windowChrome(
            ctx,
            size: size,
            background: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.11, alpha: 1),
            chrome: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1)
        )

        let green = NSColor(srgbRed: 0.42, green: 0.85, blue: 0.51, alpha: 1)
        let grey = NSColor(srgbRed: 0.55, green: 0.58, blue: 0.65, alpha: 1)
        let blue = NSColor(srgbRed: 0.38, green: 0.65, blue: 0.98, alpha: 1)

        // Alternating prompt/output lines: a short colored prompt, then a few
        // grey "output" bars of varying length.
        var y = content.maxY - 60
        let widths: [CGFloat] = [0.62, 0.48, 0.71, 0.35, 0.55, 0.80, 0.44, 0.66, 0.29]
        for (i, factor) in widths.enumerated() {
            let isPrompt = i % 3 == 0
            let color = isPrompt ? green : (i % 3 == 1 ? blue.withAlphaComponent(0.7) : grey.withAlphaComponent(0.55))
            if isPrompt {
                fill(ctx, CGRect(x: content.minX + 40, y: y, width: 18, height: 12), green, radius: 6)
            }
            let x = content.minX + (isPrompt ? 70 : 40)
            fill(ctx, CGRect(x: x, y: y, width: (content.width - 100) * factor, height: 12), color, radius: 6)
            y -= 34
        }
    }

    private static func drawChart(_ ctx: CGContext, size: CGSize) {
        fill(ctx, CGRect(origin: .zero, size: size), NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1))

        let card = CGRect(origin: .zero, size: size).insetBy(dx: 90, dy: 90)
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.12).cgColor)
        fill(ctx, card, .white, radius: 18)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Title bar of the card.
        fill(ctx, CGRect(x: card.minX + 40, y: card.maxY - 70, width: 260, height: 18),
             NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1), radius: 9)

        // Gridlines.
        let plot = CGRect(x: card.minX + 60, y: card.minY + 70, width: card.width - 120, height: card.height - 190)
        for i in 0...4 {
            let y = plot.minY + plot.height / 4 * CGFloat(i)
            fill(ctx, CGRect(x: plot.minX, y: y, width: plot.width, height: 1),
                 NSColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1))
        }

        // Bars.
        let values: [CGFloat] = [0.35, 0.52, 0.44, 0.68, 0.58, 0.82, 0.74, 0.95]
        let slot = plot.width / CGFloat(values.count)
        let barWidth = slot * 0.52
        for (i, value) in values.enumerated() {
            let x = plot.minX + slot * CGFloat(i) + (slot - barWidth) / 2
            let height = plot.height * value
            let tint = NSColor(srgbRed: 0.18, green: 0.42, blue: 0.87, alpha: 0.35 + 0.65 * value)
            fill(ctx, CGRect(x: x, y: plot.minY, width: barWidth, height: height), tint, radius: 6)
            // Axis label stub under each bar.
            fill(ctx, CGRect(x: x, y: plot.minY - 26, width: barWidth, height: 8),
                 NSColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 1), radius: 4)
        }
    }

    /// A flat poster — the "photo-ish" entry, so the archive isn't all UI.
    private static func drawPoster(_ ctx: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let colors = [
            NSColor(srgbRed: 0.11, green: 0.13, blue: 0.35, alpha: 1).cgColor,
            NSColor(srgbRed: 0.55, green: 0.19, blue: 0.52, alpha: 1).cgColor,
            NSColor(srgbRed: 0.98, green: 0.47, blue: 0.32, alpha: 1).cgColor,
        ]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 0.55, 1]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: rect.maxX, y: 0),
                options: []
            )
        }

        // A sun sinking into the horizon, sliced by bands that thin out upward.
        let horizon = rect.midY - 60
        let sun = CGRect(x: rect.midX - 150, y: horizon - 60, width: 300, height: 300)
        fill(ctx, sun, NSColor(srgbRed: 1.0, green: 0.86, blue: 0.42, alpha: 0.94), radius: sun.width / 2)
        ctx.saveGState()
        ctx.addEllipse(in: sun)
        ctx.clip()
        for i in 0..<4 {
            let height = 22 - CGFloat(i) * 4
            let y = horizon + 10 + CGFloat(i) * 46
            fill(ctx, CGRect(x: sun.minX, y: y, width: sun.width, height: height),
                 NSColor(srgbRed: 0.11, green: 0.13, blue: 0.35, alpha: 0.6))
        }
        ctx.restoreGState()
        fill(ctx, CGRect(x: 0, y: 0, width: rect.width, height: horizon),
             NSColor(srgbRed: 0.08, green: 0.09, blue: 0.24, alpha: 1))
    }
}
#endif
