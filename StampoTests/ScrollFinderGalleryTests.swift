import CoreGraphics
import Foundation
import Testing
@testable import Stampo

/// What moves in Finder's gallery is a strip of thumbnails under a large preview, and the scroll area Accessibility
/// gives is the whole of it (2026-10-14-195753: the strip is 716…770 on the screen, 54 points). The strip is the
/// first element from the pointer up that is as long as the area and narrower across (`ScrollStrip`).
@Suite struct ScrollStripTests {
    /// The gallery of 195753 in shape: the area is the preview over the strip, and the strip's elements go up from a
    /// thumbnail: the image, its group, the list of thumbnails (as long as the area, 54 high), the list of the pane.
    private let area = CGRect(x: 244, y: 560, width: 936, height: 210)
    private var gallery: [CGRect] {
        [CGRect(x: 300, y: 716, width: 54, height: 54),
         CGRect(x: 300, y: 716, width: 54, height: 54),
         CGRect(x: 244, y: 716, width: 936, height: 54),
         CGRect(x: 244, y: 560, width: 936, height: 210)]
    }

    @Test func theStripOfTheGalleryIsTheFirstListAsLongAsTheArea() throws {
        let span = try #require(ScrollStrip.crossSpan(elements: gallery, area: area, axis: .horizontal))
        #expect(span == 716...770)
        #expect(span.upperBound - span.lowerBound == 54)
    }

    /// A scroll down in a list: every row is as wide as the area, so none is narrower and there is no strip.
    @Test func aRowAsWideAsTheAreaIsNotAStrip() {
        let list = CGRect(x: 0, y: 100, width: 300, height: 600)
        let rows = [CGRect(x: 0, y: 140, width: 300, height: 24), CGRect(x: 0, y: 100, width: 300, height: 600)]
        #expect(ScrollStrip.crossSpan(elements: rows, area: list, axis: .vertical) == nil)
        #expect(ScrollStrip.crossSpan(elements: [], area: list, axis: .vertical) == nil)
    }

    /// Thumbnails and their group are shorter than the area along the scroll: they are passed over, and with nothing
    /// else there is no strip.
    @Test func anElementShorterThanTheAreaAlongTheScrollIsPassedOver() {
        let shorter = Array(gallery.prefix(2))
        #expect(ScrollStrip.crossSpan(elements: shorter, area: area, axis: .horizontal) == nil)
        // The same frames for a scroll down: nothing is as tall as the area and narrower than it.
        #expect(ScrollStrip.crossSpan(elements: gallery, area: area, axis: .vertical) == nil)
    }

    /// The same, down: a column as tall as the area and narrower than it (a sidebar next to the list in one area).
    @Test func aColumnOfTheAreaIsAStripForAScrollDown() throws {
        let wide = CGRect(x: 0, y: 0, width: 800, height: 500)
        let column = CGRect(x: 600, y: 0, width: 200, height: 500)
        let span = try #require(ScrollStrip.crossSpan(elements: [CGRect(x: 640, y: 40, width: 100, height: 20), column],
                                                     area: wide, axis: .vertical))
        #expect(span == 600...800)
    }

    /// The first one counts, not the narrowest: the chain goes up, and what is nearer the pointer is what moves.
    @Test func theFirstElementThatFitsIsTheOne() throws {
        let inner = CGRect(x: 244, y: 700, width: 936, height: 70)
        let outer = CGRect(x: 244, y: 716, width: 936, height: 54)
        #expect(try #require(ScrollStrip.crossSpan(elements: [inner, outer], area: area, axis: .horizontal))
                == 700...770)
    }

    /// An element that runs out of the area is cut to it; one outside it gives nothing.
    @Test func theSpanStaysInsideTheArea() throws {
        let past = CGRect(x: 244, y: 740, width: 936, height: 90)
        #expect(try #require(ScrollStrip.crossSpan(elements: [past], area: area, axis: .horizontal)) == 740...770)
        let below = CGRect(x: 244, y: 800, width: 936, height: 40)
        #expect(ScrollStrip.crossSpan(elements: [below], area: area, axis: .horizontal) == nil)
    }

    /// The limit narrows what the probe found, and never widens it.
    @Test func theLimitOnlyNarrows() {
        let found = CGRect(x: 0, y: 40, width: 600, height: 200)
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: 100...160) == CGRect(x: 0, y: 100, width: 600, height: 60))
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: 0...400) == found)
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: nil) == found)
        let tall = CGRect(x: 40, y: 0, width: 200, height: 600)
        #expect(ScrollStrip.narrowed(tall, axis: .vertical, to: 100...160) == CGRect(x: 100, y: 0, width: 60, height: 600))
        // Part of the limit outside what was found: the common part.
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: 200...500) == CGRect(x: 0, y: 200, width: 600, height: 40))
    }

    /// Nothing, or next to nothing, of what was found lies in the limit: the limit is wrong and is not believed.
    @Test func aLimitThatLeavesNothingIsNotBelieved() {
        let found = CGRect(x: 0, y: 40, width: 600, height: 100)
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: 300...400) == found)
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: 135...300) == found)
        #expect(ScrollStrip.narrowed(found, axis: .horizontal, to: 128...300) != found)
    }

    @Test func theLimitIsInThePixelsOfTheCrop() throws {
        // The window starts at 100 points; the strip is 716…770 on the screen, the crop starts 900 pixels down.
        let limit = try #require(ScrollStrip.pixelLimit(of: 716...770, windowOrigin: 100, cropOrigin: 900, scale: 2))
        #expect(limit == 332...440)
        #expect(ScrollStrip.pixelLimit(of: nil, windowOrigin: 100, cropOrigin: 900, scale: 2) == nil)
        #expect(ScrollStrip.pixelLimit(of: 716...770, windowOrigin: 100, cropOrigin: 3000, scale: 2) == -1768 ... -1660)
    }

    /// The strip belongs to the area: whatever is cut from the area keeps it.
    @Test func theStripTravelsWithTheViewport() throws {
        let bounds = CGRect(x: 100, y: 100, width: 1280, height: 800)
        let base = ScrollViewport(windowRect: area, relativeScrollPoint: .zero, windowBounds: bounds,
                                  crossSpan: 716...770)
        #expect(base.cropped(to: CGRect(x: 20, y: 400, width: 800, height: 100), backingScale: 2)?.crossSpan == 716...770)
        #expect(base.excludingScrollbar(axis: .horizontal, insetPoints: 10)?.crossSpan == 716...770)
        #expect(base.insetWindowEdges(points: 8)?.crossSpan == 716...770)
        let plain = ScrollViewport(windowRect: area, relativeScrollPoint: .zero, windowBounds: bounds)
        #expect(plain.crossSpan == nil)
        #expect(plain != base)
    }

    /// The probe, in a gallery: the preview above stands still and something at the foot (a scroll bar that fades)
    /// changes with the strip, so the box of what moves is taller than the strip; with the limit it is the strip.
    @Test func theProbeOfAGalleryTakesTheStripAndNothingOfThePreview() throws {
        let length = 600, across = 300
        func frame(shift: Int, bar: Bool) -> CaptureFrame {
            var bytes = [UInt8](repeating: 255, count: length * across * 4)
            for y in 0..<across {
                for x in 0..<length {
                    var value: UInt8 = 255
                    if (100..<160).contains(y) { value = SeamScenes.page(x + shift, y) }
                    else if y < 100, (100..<500).contains(x) { value = SeamScenes.page(x + 7_000, y) }
                    else if bar, y >= 150 + 130, (40..<560).contains(x) { value = 150 }
                    let i = (y * length + x) * 4
                    bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
                }
            }
            return CaptureFrame(width: length, height: across, pixels: bytes)
        }
        let before = frame(shift: 0, bar: false), after = frame(shift: 24, bar: true)
        let whole = CGRect(x: 0, y: 0, width: length, height: across)
        let free = try #require(ScrollingCaptureSession.probeOutcome(
            before: before, after: after, viewportPixels: whole, axis: .horizontal, preserveCrossAxis: true))
        let strip = try #require(ScrollingCaptureSession.probeOutcome(
            before: before, after: after, viewportPixels: whole, axis: .horizontal, preserveCrossAxis: true,
            crossLimit: 100...160))
        #expect(strip.movingRect.minY == 100 && strip.movingRect.height == 60, "\(strip.movingRect)")
        #expect(strip.first.height == 60 && strip.probe.height == 60)
        #expect(free.movingRect.height > strip.movingRect.height, "\(free.movingRect)")
    }
}

/// The scroll bars of macOS are drawn over the content and go a moment after the wheel stops. At the foot of the
/// gallery's strip the bar hides the last points of the thumbnails, and cutting the edge loses them; the capture
/// leaves the edge and waits for the bar (`ScrollOverlayScroller`).
@Suite struct ScrollOverlayScrollerTests {
    private func decide(exclude: Bool = true, site: Bool = false, overlay: Bool = true, inset: CGFloat? = 14,
                        overStrip: Bool = true) -> ScrollOverlayScroller.Decision {
        ScrollOverlayScroller.decision(excludeScrollbars: exclude, isWebPage: site, overlayStyle: overlay,
                                       axisScrollbarInset: inset, overMovingStrip: overStrip, fallbackPoints: 10)
    }

    @Test func theWaitIsOneSecond() {
        #expect(ScrollOverlayScroller.minimumDelay == 1.0)
    }

    /// An overlay bar that Accessibility found over the area, not on a site: the edge stays and the frames wait.
    @Test func anOverlayBarOverTheAreaIsWaitedFor() {
        #expect(decide() == .wait)
    }

    @Test func withTheSettingOffNothingIsCut() {
        #expect(decide(exclude: false) == .leave)
        #expect(decide(exclude: false, site: true, overlay: false, inset: nil) == .leave)
    }

    /// A site is cut as it always was, whatever the style of the bar.
    @Test func aSiteIsCutAsBefore() {
        #expect(decide(site: true) == .cut(points: 14))
        #expect(decide(site: true, inset: nil) == .cut(points: 10))
    }

    /// The bars that are always shown stand over the content for good: they are cut as before.
    @Test func aLegacyBarIsCutAsBefore() {
        #expect(decide(overlay: false) == .cut(points: 14))
        #expect(decide(overlay: false, inset: nil) == .cut(points: 10))
    }

    /// No bar in the tree: the fixed reserve, as before. A bar beside the area (0 points) is not over it.
    @Test func withoutABarGeometryTheFixedReserveIsCut() {
        #expect(decide(inset: nil) == .cut(points: 10))
        #expect(decide(inset: 0) == .cut(points: 0))
    }

    /// A bar in a part of the area where nothing moves is no reason to wait.
    @Test func aBarOutsideTheStripIsCutAsBefore() {
        #expect(decide(overStrip: false) == .cut(points: 14))
    }

    @Test func theBarLiesOverTheStripWhenTheStripReachesTheEdge() {
        let area = CGRect(x: 244, y: 560, width: 936, height: 210)
        // 195753: the strip ends at the foot of the area, where the bar is.
        #expect(ScrollOverlayScroller.barLiesOver(strip: 716...770, area: area, axis: .horizontal, inset: 14))
        // A strip that ends above the bar.
        #expect(!ScrollOverlayScroller.barLiesOver(strip: 640...700, area: area, axis: .horizontal, inset: 14))
        // No strip: the area moves as a whole, and the bar lies over it.
        #expect(ScrollOverlayScroller.barLiesOver(strip: nil, area: area, axis: .horizontal, inset: 14))
        // Down: the bar is at the right edge.
        let tall = CGRect(x: 0, y: 0, width: 800, height: 500)
        #expect(ScrollOverlayScroller.barLiesOver(strip: 600...800, area: tall, axis: .vertical, inset: 12))
        #expect(!ScrollOverlayScroller.barLiesOver(strip: 100...500, area: tall, axis: .vertical, inset: 12))
    }

    /// A frame is taken no earlier than a second after the wheel, and the time that passed already counts.
    @Test func aFrameWaitsForWhatIsLeftOfTheSecond() {
        #expect(ScrollOverlayScroller.remainingWait(sinceWheel: 0) == 1.0)
        #expect(abs(ScrollOverlayScroller.remainingWait(sinceWheel: 0.4) - 0.6) < 1e-9)
        #expect(ScrollOverlayScroller.remainingWait(sinceWheel: 1.0) == 0)
        #expect(ScrollOverlayScroller.remainingWait(sinceWheel: 7) == 0)
        // Before any wheel (the distant past), and a clock that went back: neither makes a wait longer than the second.
        #expect(ScrollOverlayScroller.remainingWait(sinceWheel: Date().timeIntervalSince(.distantPast)) == 0)
        #expect(ScrollOverlayScroller.remainingWait(sinceWheel: -5) == 1.0)
    }
}
