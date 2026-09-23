import AppKit
import Testing
@testable import Stampo

/// The mascot as the menu bar will draw it: the real view, at the real size,
/// rendered without a screen.
///
/// `CALayer.render(in:)` walks the model layers, so no window and no display is
/// needed — which matters, because the one thing that cannot be checked by
/// reasoning is whether a 1pt outline still reads as a hare at eighteen points
/// tall.
@MainActor @Suite struct MascotViewProbe {

    @Test func sheet() throws {
        let states: [(String, MascotState)] = [
            ("sleeping", .sleeping),
            ("awake", .awake),
            ("waiting", .waiting),
            ("looking left", .colorPicking(.leftCenter)),
            ("looking right", .colorPicking(.rightCenter)),
            ("countdown", .countdown)
        ]
        let cell = CGSize(width: 22, height: 18)
        let zooms: [CGFloat] = [1, 2, 8]
        let gap: CGFloat = 6
        let rowHeight = cell.height * (zooms.max() ?? 1) + gap
        let width = zooms.reduce(0) { $0 + cell.width * $1 + gap } + gap
        let height = rowHeight * CGFloat(states.count) + gap

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width * 4), pixelsHigh: Int(height * 4),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let ctx = context.cgContext
        ctx.scaleBy(x: 4, y: 4)
        ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (row, state) in states.enumerated() {
            let view = MascotStatusView(frame: NSRect(origin: .zero, size: cell))
            view.appearance = NSAppearance(named: .darkAqua)
            view.setState(state.1)
            view.layoutSubtreeIfNeeded()
            guard let layer = view.layer else { continue }

            var x = gap
            for zoom in zooms {
                ctx.saveGState()
                ctx.translateBy(x: x,
                                y: height - gap - rowHeight * CGFloat(row) - cell.height * zoom)
                ctx.scaleBy(x: zoom, y: zoom)
                layer.render(in: ctx)
                ctx.restoreGState()
                x += cell.width * zoom + gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/mascot-view.png"))
        print("VIEW /tmp/mascot-view.png")
    }
}
