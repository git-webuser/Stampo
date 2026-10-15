import CoreGraphics
import Testing
@testable import Stampo

/// Where the box of what moves ends along the scroll (`movingContentRect`, `extendToTrailingEdge`): Finder's
/// columns, scrolled right, end in a column that is almost empty when the probe is taken (one line in it, too faint
/// to count as moving), and a box that ended there cut the column off when it came in (2026-10-14-233345, 234809,
/// 2026-10-10-163756: the last column lacked 83 points on the right). In an area that is not a page the box runs on
/// to the edge the content comes from, over lines that hold nothing or that changed, and stops before one that
/// holds something that stands still.
@Suite struct ScrollTrailingEdgeTests {
    let along = 900, across = 400
    /// The moving columns end here; to the edge there is the last column.
    let movingEnd = 700
    let shift = 20

    /// What the last column holds.
    enum Edge { case blank, oneLine, standingText, standingAfterBlank, standingAbove }

    /// The pixel at `position` along the scroll and `line` across it: noise that moves (page rows 20…380) up to
    /// `movingEnd`; then the last column's contents.
    private func pixel(position: Int, line: Int, shift: Int, edge: Edge) -> UInt8 {
        if position < movingEnd { return (20..<380).contains(line) ? SeamScenes.page(position + shift, line) : 255 }
        switch edge {
        case .blank:
            return 255
        case .oneLine:
            // Six lines of text that moved with the page: faint in the mean of the whole line across.
            return (60..<66).contains(line) ? SeamScenes.page(position + shift, line) : 255
        case .standingText:
            // A strip at the edge that does not move, with text in it, from 820.
            return position >= 820 && (20..<380).contains(line) ? SeamScenes.page(position + 9_000, line) : 255
        case .standingAbove:
            // A preview that stands still over the strip: rows 20…100, from 820 on; the strip (100…380) is blank.
            return position >= 820 && (20..<100).contains(line) ? SeamScenes.page(position + 9_000, line) : 255
        case .standingAfterBlank:
            // The same, but only from 880: 180 blank lines between.
            return position >= 880 && (20..<380).contains(line) ? SeamScenes.page(position + 9_000, line) : 255
        }
    }

    private func frame(_ axis: ScrollAxis, shift: Int, edge: Edge) -> CaptureFrame {
        let width = axis == .vertical ? across : along, height = axis == .vertical ? along : across
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = axis == .vertical
                    ? pixel(position: y, line: x, shift: shift, edge: edge)
                    : pixel(position: x, line: y, shift: shift, edge: edge)
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func rect(_ axis: ScrollAxis, _ edge: Edge, extend: Bool = true,
                      wholeWidth: Bool = false) throws -> CGRect {
        try #require(ScrollingCaptureSession.movingContentRect(
            before: frame(axis, shift: 0, edge: edge), after: frame(axis, shift: shift, edge: edge),
            axis: axis, preserveCrossAxis: true, wholeWidth: wholeWidth, extendToTrailingEdge: extend))
    }

    private func end(of rect: CGRect, _ axis: ScrollAxis) -> CGFloat { axis == .vertical ? rect.maxY : rect.maxX }
    private func start(of rect: CGRect, _ axis: ScrollAxis) -> CGFloat { axis == .vertical ? rect.minY : rect.minX }

    /// The case that was wrong: the box ends where the moving columns do, and the last column is cut.
    @Test func withoutTheEdgeTheBoxEndsWhereTheFaintColumnBegins() throws {
        for axis in [ScrollAxis.horizontal, .vertical] {
            let found = try rect(axis, .oneLine, extend: false)
            #expect(end(of: found, axis) == CGFloat(movingEnd), "\(axis) \(found)")
        }
    }

    /// (a) A column that is almost empty and moved by 20: the box takes it in, to the edge of the area.
    @Test func anAlmostEmptyColumnAtTheEdgeIsTakenIn() throws {
        for axis in [ScrollAxis.horizontal, .vertical] {
            let found = try rect(axis, .oneLine)
            #expect(end(of: found, axis) == CGFloat(along), "\(axis) \(found)")
            #expect(start(of: found, axis) == 0, "\(axis) \(found)")
        }
    }

    /// (b) A strip with text that stands still at the edge: the box stops before it.
    @Test func aStripOfTextThatStandsStillIsNotTakenIn() throws {
        for axis in [ScrollAxis.horizontal, .vertical] {
            let found = try rect(axis, .standingText)
            #expect(end(of: found, axis) == 820, "\(axis) \(found)")
        }
        // Blank between the moving rows and the text: the blank is taken in, the text is not.
        #expect(end(of: try rect(.horizontal, .standingAfterBlank), .horizontal) == 880)
    }

    /// (c) An empty background at the edge: taken in, to the edge.
    @Test func anEmptyBackgroundIsTakenIn() throws {
        for axis in [ScrollAxis.horizontal, .vertical] {
            #expect(end(of: try rect(axis, .blank), axis) == CGFloat(along))
        }
    }

    /// The leading edge is where the probe found it, and so is the extent across the scroll.
    @Test func theLeadingEdgeAndTheExtentAcrossAreTheSame() throws {
        for edge in [Edge.blank, .oneLine, .standingText] {
            for axis in [ScrollAxis.horizontal, .vertical] {
                let was = try rect(axis, edge, extend: false), now = try rect(axis, edge)
                #expect(start(of: now, axis) == start(of: was, axis), "\(axis) \(edge)")
                if axis == .vertical {
                    #expect(now.minX == was.minX && now.width == was.width, "\(edge) \(now) \(was)")
                } else {
                    #expect(now.minY == was.minY && now.height == was.height, "\(edge) \(now) \(was)")
                }
            }
        }
    }

    /// A page is as it was: the box of a site scrolled down already runs to the bottom of the window, and the
    /// session does not ask a site's strip for the edge.
    @Test func aPageScrolledDownIsAsBefore() throws {
        let page = try rect(.vertical, .standingText, extend: false, wholeWidth: true)
        let asked = try rect(.vertical, .standingText, extend: true, wholeWidth: true)
        #expect(page == asked)
        #expect(page.maxY == CGFloat(along))
    }

    /// The strip of a gallery (`ScrollStrip`) is the box across the scroll: what stands still over it, at the
    /// edge, is not in the frames and does not stop the edge.
    @Test func whatLiesOutsideTheStripDoesNotStopTheEdge() throws {
        let before = frame(.horizontal, shift: 0, edge: .standingAbove)
        let after = frame(.horizontal, shift: shift, edge: .standingAbove)
        let free = try #require(ScrollingCaptureSession.movingContentRect(
            before: before, after: after, axis: .horizontal, preserveCrossAxis: true, extendToTrailingEdge: true))
        #expect(free.maxX == 820, "\(free)")
        let strip = try #require(ScrollingCaptureSession.movingContentRect(
            before: before, after: after, axis: .horizontal, preserveCrossAxis: true, extendToTrailingEdge: true,
            crossLimit: 100...380))
        #expect(strip.maxX == CGFloat(along) && strip.minY == 100 && strip.maxY == 380, "\(strip)")
    }

    /// A single line that holds something still, or a few, is not a strip: the selected row of a column, a band wider
    /// than the step, is the same in both frames between the letters of its text (233345).
    @Test func aFewStillLinesDoNotStopTheEdge() throws {
        func scene(_ shift: Int) -> CaptureFrame {
            var bytes = [UInt8](repeating: 255, count: along * across * 4)
            for y in 0..<across {
                for x in 0..<along {
                    // The moving columns, and at the edge a band (rows 100…150) with text: the text moves, the band's
                    // interior is the same, and so are the lines between the letters.
                    var value: UInt8 = 255
                    if x < movingEnd { value = (20..<380).contains(y) ? SeamScenes.page(x + shift, y) : 255 }
                    else if (100..<150).contains(y) { value = (x - shift) % 12 < 4 ? 40 : 120 }
                    let i = (y * along + x) * 4
                    bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
                }
            }
            return CaptureFrame(width: along, height: across, pixels: bytes)
        }
        let found = try #require(ScrollingCaptureSession.movingContentRect(
            before: scene(0), after: scene(shift), axis: .horizontal, preserveCrossAxis: true,
            extendToTrailingEdge: true))
        #expect(found.maxX == CGFloat(along), "\(found)")
    }

    /// The default is no edge: callers that do not ask get the box of before.
    @Test func theEdgeIsOffByDefault() throws {
        let before = frame(.horizontal, shift: 0, edge: .oneLine), after = frame(.horizontal, shift: shift, edge: .oneLine)
        let found = try #require(ScrollingCaptureSession.movingContentRect(
            before: before, after: after, axis: .horizontal, preserveCrossAxis: true))
        #expect(found.maxX == CGFloat(movingEnd))
    }

    /// The probe's frames are cut to the box, so the first look and the probe take the column in as well; a page
    /// (the session passes false for it) keeps the cut.
    @Test func theProbeFramesTakeTheColumnIn() throws {
        let before = frame(.horizontal, shift: 0, edge: .oneLine), after = frame(.horizontal, shift: shift, edge: .oneLine)
        let whole = CGRect(x: 0, y: 0, width: along, height: across)
        let outcome = try #require(ScrollingCaptureSession.probeOutcome(
            before: before, after: after, viewportPixels: whole, axis: .horizontal, preserveCrossAxis: true,
            extendToTrailingEdge: true))
        #expect(outcome.movingRect.maxX == CGFloat(along))
        #expect(outcome.first.width == along && outcome.probe.width == along)
        let cut = try #require(ScrollingCaptureSession.probeOutcome(
            before: before, after: after, viewportPixels: whole, axis: .horizontal, preserveCrossAxis: true))
        #expect(cut.first.width == movingEnd)
    }
}
