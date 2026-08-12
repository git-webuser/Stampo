import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// Panel behaviour that only exists once something is drawn.
///
/// Not golden images: a committed PNG would fail on the next macOS that
/// changes font hinting or antialiasing, and would fail identically whether the
/// panel had regressed or Apple had simply moved a curve by a pixel. What is
/// asserted here is the handful of structural facts the panel kept losing —
/// content staying inside the shape, the softened ends of a scroll, glyphs in
/// the shoulders they belong to — each stated as a property of the rendered
/// pixels rather than as the pixels themselves.
@MainActor
@Suite struct PanelRenderTests {

    // MARK: Harness

    /// Renders a view offscreen and hands back its pixels.
    ///
    /// The window and the run-loop pump are not ceremony: SwiftUI lays out and
    /// draws on a real display cycle, and a view asked for its bitmap before
    /// that has happened comes back empty. Same arrangement as
    /// `ArchiveCellHitTests`.
    private func render(_ view: some View, size: NSSize) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Mean brightness of a horizontal band, in points from the top.
    private func brightness(_ rep: NSBitmapImageRep, rows: Range<Int>) -> Double {
        let scale = rep.pixelsHigh / max(1, Int(rep.size.height))
        var total = 0.0
        var count = 0
        for y in (rows.lowerBound * scale)..<(rows.upperBound * scale) where y < rep.pixelsHigh {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                total += Double(c.brightnessComponent) * Double(c.alphaComponent)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// Mean brightness of a vertical band, in points from the left.
    private func brightness(_ rep: NSBitmapImageRep, columns: Range<Int>) -> Double {
        let scale = rep.pixelsWide / max(1, Int(rep.size.width))
        var total = 0.0
        var count = 0
        for x in (columns.lowerBound * scale)..<(columns.upperBound * scale) where x < rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                total += Double(c.brightnessComponent) * Double(c.alphaComponent)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private var metrics: NotchMetrics { .fallback() }

    private func translator(_ text: String) -> some View {
        TranslationPanelModel.shared.present(.preview(of: text), bodyWidth: 440)
        // Top-aligned, and the alignment is load-bearing: a plain ZStack
        // centres, which would put a 168pt panel in the middle of the canvas
        // and make every row measured below a measurement of empty space.
        return ZStack(alignment: .top) {
            Color.black
            NotchTranslateView(metrics: metrics, model: TranslationPanelModel.shared,
                               isPinned: false, onBack: {}, onPickLanguage: { _, _ in },
                               onTogglePin: {})
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private let paragraph = String(
        repeating: "Снимок экрана, сканер и палитра цветов для macOS с вырезом. ", count: 12)

    // MARK: The translator body

    @Test func textNeverPaintsBelowThePanel() throws {
        let model = TranslationPanelModel.shared
        let rep = try render(translator(paragraph), size: NSSize(width: 520, height: 260))
        let panelBottom = Int(metrics.panelHeight + model.bodyHeight)

        // Everything under the panel is transparent, whatever the text is
        // doing. This is the one that used to fail while the panel collapsed,
        // with lines of a translation left hanging below the shape.
        #expect(brightness(rep, rows: (panelBottom + 6)..<(panelBottom + 40)) < 0.01)
    }

    /// The softened ends, checked as arithmetic rather than as pixels.
    ///
    /// A 7pt ramp over 17pt lines cannot be measured by sampling bands: they
    /// land between the lines as often as on them, and the reading swings by
    /// more than the effect. What is worth holding still is that the band is a
    /// fixed number of points at every height — the same 7pt whether the body
    /// is at its floor or its ceiling, which is why it stays clear of a short
    /// translation's text and only ever touches a long one's.
    @Test func theSoftenedBandIsTheSameSizeAtEveryHeight() {
        for height in [NotchTranslateView.minBodyHeight, 80, NotchTranslateView.maxBodyHeight] {
            let scroll = height - NotchTranslateView.bodyPadding
            let stop = NotchTranslateView.fadeStop(bodyHeight: height)
            #expect(abs(stop * scroll - NotchTranslateView.fadeInset) < 0.01,
                    "at body height \(height)")
        }
    }

    @Test func aDegenerateHeightCannotSwallowTheWholeBody() {
        // Half is the cap: the two ends meeting in the middle would fade
        // everything, which is what a naive ratio does when the height it
        // divides by arrives as zero.
        #expect(NotchTranslateView.fadeStop(bodyHeight: 0) == 0.5)
        #expect(NotchTranslateView.fadeStop(bodyHeight: NotchTranslateView.bodyPadding) == 0.5)
    }

    @Test func aShortTranslationIsNotDimmed() throws {
        // The fade is unconditional, but at 7pt it lands inside the body's own
        // padding. A two-line translation must still read at full strength.
        let rep = try render(translator("Снимок экрана и сканер для macOS."),
                             size: NSSize(width: 520, height: 260))
        let bodyTop = Int(metrics.panelHeight)
        #expect(brightness(rep, rows: (bodyTop + 10)..<(bodyTop + 22)) > 0.05)
    }

    // MARK: The waiting strip

    @Test func theStripPutsItsGlyphsInTheShoulders() throws {
        let width = TranslatingView.stripWidth(metrics)
        let rep = try render(
            ZStack(alignment: .top) {
                Color.black
                TranslatingView(metrics: metrics, interaction: NotchPanelInteractionState())
            },
            size: NSSize(width: width, height: metrics.panelHeight))

        let inset = Int(metrics.edgeSafe)
        let cell = Int(metrics.cellWidth)
        let left = brightness(rep, columns: inset..<(inset + cell))
        let right = brightness(rep, columns: (Int(width) - inset - cell)..<(Int(width) - inset))
        let middle = brightness(rep, columns: (Int(width) / 2 - 20)..<(Int(width) / 2 + 20))

        #expect(left > middle, "the translator glyph belongs on the leading shoulder")
        #expect(right > middle, "the ring belongs on the trailing shoulder")
        #expect(middle < 0.02, "nothing is drawn between them")
    }

    @Test func theStripIsNarrowerThanEveryRoute() {
        // Two glyphs do not need the main strip's width, and the arithmetic is
        // what puts them 5pt inside the shape's walls.
        let width = TranslatingView.stripWidth(metrics)
        #expect(width < metrics.notchGap + 2 * 182)
        #expect(width == metrics.edgeSafe * 2 + metrics.cellWidth * 2 + 166)
    }
}
