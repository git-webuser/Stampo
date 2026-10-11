import CoreGraphics
import Testing
@testable import Stampo

/// How wide the moving area is across the scroll (`movingContentRect`): a web
/// page is shown in the width of the browser's window, whatever stands still in
/// it; anything else is narrowed by what stands still beside the moving rows,
/// and by nothing above or below them. A frame of `length` along the scroll and
/// `across` across it, as `SeamScenes` makes its pages.
@Suite struct ScrollWidthTests {
    let length = 600, across = 1000
    /// Rows (along the scroll) that move; the header above them is fixed.
    let headerRows = 40

    /// The pixel at `along`, `across`: a centre band of noise that moves by
    /// `shift` between the frames, a header of fixed text in the margins above
    /// it, and, if asked, a panel along the whole length on the near side.
    private func pixel(along: Int, across: Int, shift: Int, panel: Bool) -> UInt8 {
        if panel, across < 250 { return SeamScenes.page(along + 9_000, across) }
        if along < headerRows {
            if (40..<100).contains(across) || (900..<960).contains(across) { return SeamScenes.page(along + 5_000, across) }
            return 255
        }
        if (300..<700).contains(across) { return SeamScenes.page(along + shift, across) }
        return 255
    }

    private func frame(axis: ScrollAxis, shift: Int, panel: Bool) -> CaptureFrame {
        let width = axis == .vertical ? across : length, height = axis == .vertical ? length : across
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = axis == .vertical
                    ? pixel(along: y, across: x, shift: shift, panel: panel)
                    : pixel(along: x, across: y, shift: shift, panel: panel)
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func rect(_ axis: ScrollAxis, panel: Bool = false, wholeWidth: Bool = false) throws -> CGRect {
        try #require(ScrollingCaptureSession.movingContentRect(
            before: frame(axis: axis, shift: 0, panel: panel), after: frame(axis: axis, shift: 20, panel: panel),
            axis: axis, preserveCrossAxis: true, wholeWidth: wholeWidth))
    }

    /// Not a web page: the header's words above the moving rows are not what
    /// stands still beside them, and the box takes the margins in.
    @Test func whatStandsAboveTheMovingRowsDoesNotNarrowTheBox() throws {
        let found = try rect(.vertical)
        #expect(found.minX == 0 && found.width == CGFloat(across), "\(found)")
        #expect(found.minY == CGFloat(headerRows) && found.height == CGFloat(length - headerRows), "\(found)")
    }

    /// Not a web page: a panel along the whole length does stand beside them.
    @Test func aPanelAlongTheWholeLengthStillNarrowsTheBox() throws {
        let found = try rect(.vertical, panel: true)
        #expect(found.minX == 250, "\(found)")
        #expect(found.maxX == CGFloat(across), "\(found)")
    }

    /// A web page: the whole width, panel or not.
    @Test func aWebPageIsTheWholeWidthWhateverStandsStill() throws {
        for panel in [false, true] {
            let found = try rect(.vertical, panel: panel, wholeWidth: true)
            #expect(found.minX == 0 && found.width == CGFloat(across), "panel \(panel): \(found)")
            // Along the scroll the pinned header is still left out.
            #expect(found.minY == CGFloat(headerRows), "panel \(panel): \(found)")
        }
    }

    @Test func aHorizontalScrollIsTheSameTransposed() throws {
        let plain = try rect(.horizontal)
        #expect(plain.minY == 0 && plain.height == CGFloat(across), "\(plain)")
        #expect(plain.minX == CGFloat(headerRows) && plain.width == CGFloat(length - headerRows), "\(plain)")
        let withPanel = try rect(.horizontal, panel: true)
        #expect(withPanel.minY == 250 && withPanel.maxY == CGFloat(across), "\(withPanel)")
        let site = try rect(.horizontal, panel: true, wholeWidth: true)
        #expect(site.minY == 0 && site.height == CGFloat(across), "\(site)")
    }

    /// The probe's outcome for a web page: the first frame and the probe are
    /// cut to the whole width.
    @Test func theProbeOfAWebPageIsWholeWidth() throws {
        let before = frame(axis: .vertical, shift: 0, panel: true), after = frame(axis: .vertical, shift: 20, panel: true)
        let whole = CGRect(x: 0, y: 0, width: across, height: length)
        let site = try #require(ScrollingCaptureSession.probeOutcome(
            before: before, after: after, viewportPixels: whole, axis: .vertical,
            preserveCrossAxis: true, wholeWidth: true))
        #expect(site.first.width == across && site.probe.width == across)
        let other = try #require(ScrollingCaptureSession.probeOutcome(
            before: before, after: after, viewportPixels: whole, axis: .vertical, preserveCrossAxis: true))
        #expect(other.first.width == across - 250)
    }

    @Test func theWebPageMarkTravelsWithTheViewport() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let base = ScrollViewport(windowRect: bounds, relativeScrollPoint: .zero, windowBounds: bounds)
        #expect(!base.isWebPage)
        let page = ScrollViewport(windowRect: bounds, relativeScrollPoint: .zero, windowBounds: bounds, isWebPage: true)
        #expect(page.isWebPage)
        #expect(page.cropped(to: CGRect(x: 10, y: 10, width: 600, height: 400), backingScale: 2)?.isWebPage == true)
        #expect(page.excludingScrollbar(axis: .vertical, insetPoints: 15)?.isWebPage == true)
        #expect(page.insetWindowEdges(points: 8)?.isWebPage == true)
        #expect(base.excludingScrollbar(axis: .vertical, insetPoints: 15)?.isWebPage == false)
        #expect(base != page)
    }
}
