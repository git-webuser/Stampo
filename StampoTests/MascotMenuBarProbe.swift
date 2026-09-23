import AppKit
import Testing
@testable import Stampo

/// The mascot where it lives: a menu bar at its own size, light and dark.
///
/// Every other picture of it has been a magnification, and a magnification
/// answers the wrong question. What matters is whether a hare eighteen points
/// tall reads as a hare beside a clock — and whether the states can be told
/// apart at that size without being pointed at.
@MainActor @Suite struct MascotMenuBarProbe {

    @Test func menuBar() throws {
        let states: [(String, MascotState)] = [
            ("asleep", .sleeping),
            ("awake", .awake),
            ("waiting", .waiting),
            ("looking left", .colorPicking(.leftCenter)),
            ("looking right", .colorPicking(.rightCenter)),
            ("counting down", .countdown)
        ]
        let scale: CGFloat = 2                 // a retina menu bar
        let barHeight: CGFloat = 24
        let width: CGFloat = 340
        let rowGap: CGFloat = 10
        let height = (barHeight + rowGap) * CGFloat(states.count) * 2 + rowGap * 3

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let ctx = context.cgContext
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var y = height - rowGap - barHeight
        for dark in [true, false] {
            for (label, state) in states {
                draw(bar: CGRect(x: rowGap, y: y, width: width - rowGap * 2, height: barHeight),
                     dark: dark, label: label, state: state, in: ctx)
                y -= barHeight + rowGap
            }
            y -= rowGap
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/mascot-menubar.png"))
        print("BAR /tmp/mascot-menubar.png")
    }

    /// One menu bar: the mascot where the status item puts it, a clock beside
    /// it, and the state's name at the left so the strip can be read.
    private func draw(bar: CGRect, dark: Bool, label: String,
                      state: MascotState, in ctx: CGContext) {
        ctx.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.96, alpha: 1))
        ctx.fill(bar)
        let ink = dark ? NSColor(calibratedWhite: 0.9, alpha: 1)
                       : NSColor(calibratedWhite: 0.1, alpha: 1)

        let caption = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: ink.withAlphaComponent(0.45)
        ])
        caption.draw(at: CGPoint(x: bar.minX + 8, y: bar.midY - 6))

        let clock = NSAttributedString(string: "Пт 16:52", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: ink
        ])
        let clockWidth = clock.size().width
        clock.draw(at: CGPoint(x: bar.maxX - clockWidth - 10, y: bar.midY - 8))

        // The status item: 30 points wide, the view 22 × 18 inside it.
        let view = MascotStatusView(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.setState(state)
        view.layoutSubtreeIfNeeded()
        ctx.saveGState()
        ctx.translateBy(x: bar.maxX - clockWidth - 10 - 30 + 4, y: bar.midY - 9)
        view.layer?.render(in: ctx)
        ctx.restoreGState()
    }
}
