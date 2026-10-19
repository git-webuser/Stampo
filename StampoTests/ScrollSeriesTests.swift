import Testing
@testable import Stampo

@Suite struct ScrollSeriesTests {
    private struct Box {
        var x: Int, y: Int, width: Int, height: Int, value: UInt8
    }

    private let width = 320, height = 192

    /// A page of `background` with boxes on it, grey, in the same pixels as a capture.
    private func frame(background: UInt8, _ boxes: [Box]) -> CaptureFrame {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<3 { pixels[pixel * 4 + channel] = background }
        }
        for box in boxes {
            for y in max(0, box.y)..<min(height, box.y + box.height) {
                for x in max(0, box.x)..<min(width, box.x + box.width) {
                    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = box.value }
                }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    /// Glyph-like boxes, `count` of them, from a seed: text, as far as edges go.
    private func glyphs(_ count: Int, seed: Int, ink: UInt8, keepOff top: Int = 14, bottom: Int = 14) -> [Box] {
        var state = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 12345)
        func next(_ limit: Int) -> Int {
            state = state &* 1664525 &+ 1013904223
            return Int((state >> 8) % UInt32(limit))
        }
        return (0..<count).map { _ in
            Box(x: next(width - 12), y: top + next(height - top - bottom - 12), width: 3 + next(4), height: 6 + next(5),
                value: ink)
        }
    }

    /// A page that is one fill: a box of this colour over a third of the frame and more.
    private func fill(background: UInt8, color: UInt8, seed: Int, ink: UInt8) -> CaptureFrame {
        frame(background: background, [Box(x: 40, y: 30, width: 224, height: 100, value: color)]
              + glyphs(6, seed: seed, ink: ink))
    }

    private func notSame(_ a: Int, _ b: Int) -> Bool { false }

    // MARK: The measures

    @Test func textHasEdgesAndAFillHasFlatBlocksOfItsOwnColour() {
        let text = ScrollSeries.measure(frame(background: 5, glyphs(60, seed: 1, ink: 230)))
        let letters = ScrollSeries.measure(fill(background: 5, color: 235, seed: 2, ink: 230))
        #expect(text.edges > letters.edges)
        #expect(!text.blockIsFlat.isEmpty && text.blockIsFlat.count == letters.blockIsFlat.count)
        // The fill's blocks are flat and bright, where the page is dark.
        let brightFlat = zip(letters.blockIsFlat, letters.blockLuminance).filter { $0 && $1 > 0.5 }.count
        #expect(brightFlat >= 12)
        #expect(zip(text.blockIsFlat, text.blockLuminance).filter { $0 && $1 > 0.5 }.count == 0)
    }

    @Test func theBackgroundIsWhatMostFlatBlocksOfTheWholeQueueAre() throws {
        let dark = [ScrollSeries.measure(frame(background: 5, glyphs(40, seed: 3, ink: 230))),
                    ScrollSeries.measure(fill(background: 5, color: 235, seed: 4, ink: 230))]
        let darkBackground = try #require(ScrollSeries.background(dark))
        #expect(darkBackground < 0.1)
        // A light page has a light background: a dark box is what stands out there.
        let light = [ScrollSeries.measure(frame(background: 245, glyphs(40, seed: 3, ink: 20))),
                     ScrollSeries.measure(fill(background: 245, color: 15, seed: 4, ink: 20))]
        let lightBackground = try #require(ScrollSeries.background(light))
        #expect(lightBackground > 0.9)
        // A frame with no flat block says nothing.
        let busy = ScrollSeries.Measure(edges: 0.1, topRows: [], bottomRows: [], blockLuminance: [0.5], blockIsFlat: [false])
        #expect(ScrollSeries.background([busy]) == nil)
    }

    // MARK: Fills

    @Test func aFillIsLeftOutOfADarkAndOfALightPage() {
        for (background, ink, color): (UInt8, UInt8, UInt8) in [(5, 230, 235), (245, 20, 15)] {
            let frames = [frame(background: background, glyphs(60, seed: 10, ink: ink)),
                          fill(background: background, color: color, seed: 11, ink: ink),
                          frame(background: background, glyphs(55, seed: 12, ink: ink)),
                          fill(background: background, color: color, seed: 13, ink: ink),
                          frame(background: background, glyphs(58, seed: 14, ink: ink))]
            let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
            #expect(selection.fills == [1, 3])
            #expect(selection.indices == [0, 2, 4])
        }
    }

    @Test func aLightPageIsNotOneFill() {
        // Every frame of a light page is light: the page's own colour is not a fill.
        let frames = (0..<5).map { frame(background: 245, glyphs(50 + $0 * 3, seed: 20 + $0, ink: 20)) }
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.fills.isEmpty)
    }

    @Test func aFrameWithMuchLessStructureThanTheBestIsAFillToo() {
        let frames = [frame(background: 5, glyphs(80, seed: 30, ink: 230)),
                      frame(background: 5, glyphs(8, seed: 31, ink: 230)),
                      frame(background: 5, glyphs(70, seed: 32, ink: 230))]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.fills == [1])
        #expect(selection.indices == [0, 2])
    }

    @Test func whenEveryFrameIsAFillTheLeastFlatOneIsTaken() {
        let frames = [fill(background: 5, color: 235, seed: 40, ink: 230),
                      frame(background: 5, [Box(x: 32, y: 32, width: 256, height: 96, value: 235)]),
                      fill(background: 5, color: 235, seed: 41, ink: 230)]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.fills == [0, 1, 2])
        #expect(selection.indices.count == 1 && selection.indices != [1])
    }

    // MARK: Cut edges

    @Test func aFrameCutAtTheEdgeCountsHalfAndWhatIsFixedToTheViewportCutsNothing() {
        let ring = Box(x: 150, y: 2, width: 10, height: 6, value: 200)
        // The same text in four frames; the third has a line that runs into the top edge.
        func page(_ seed: Int, cut: Bool) -> CaptureFrame {
            frame(background: 5, glyphs(60, seed: seed, ink: 230, keepOff: 14)
                  + [ring] + (cut ? [Box(x: 20, y: 2, width: 200, height: 7, value: 230)] : []))
        }
        let measures = [page(50, cut: false), page(50, cut: false), page(50, cut: true), page(50, cut: false)]
            .map(ScrollSeries.measure)
        let selection = ScrollSeries.choose(measures, same: notSame)
        #expect(selection.cut == [2])
        #expect(selection.frames[2].score == selection.frames[2].edges / 2)
        #expect(selection.frames[0].score == selection.frames[0].edges)
        // The ring is in every frame: it is not why a frame is cut.
        #expect(!selection.frames[0].isCut && !selection.frames[1].isCut && !selection.frames[3].isCut)
    }

    @Test func aCutFrameLosesToAWholeOneOfAboutTheSameStructure() {
        func page(_ seed: Int, cut: Bool) -> CaptureFrame {
            frame(background: 5, glyphs(60, seed: seed, ink: 230) + (cut ? [Box(x: 20, y: 2, width: 200, height: 7, value: 230)] : []))
        }
        // Four frames, a cut one among them, no spread to speak of: but three of them are whole.
        let measures = [page(60, cut: true), page(61, cut: false), page(62, cut: false), page(63, cut: false)]
            .map(ScrollSeries.measure)
        let selection = ScrollSeries.choose(measures, same: notSame)
        #expect(selection.cut == [0])
        #expect(!selection.indices.contains(0))
    }

    // MARK: Choosing

    @Test func theBestThreeGoInInTheOrderOfTime() {
        // Structure falls and rises: the best are the first, the fourth and the last of seven.
        let counts = [90, 30, 40, 85, 35, 45, 80]
        let measures = counts.enumerated().map { ScrollSeries.measure(frame(background: 5, glyphs($1, seed: 70 + $0, ink: 230))) }
        let selection = ScrollSeries.choose(measures, same: notSame)
        #expect(selection.indices == [0, 3, 6])
        #expect(!selection.byNumber)
    }

    @Test func framesThatTheMeasuresCannotTellApartAreTakenByNumber() {
        // Seven frames of the same structure: first, middle and last, as before.
        let measures = (0..<7).map { ScrollSeries.measure(frame(background: 5, glyphs(60, seed: 80 + $0 * 0, ink: 230))) }
        let selection = ScrollSeries.choose(measures, same: notSame)
        #expect(selection.byNumber)
        #expect(selection.indices == [0, 3, 6])
        #expect(selection.close == Array(0..<7))
    }

    @Test func manyFramesAsGoodAsTheBestAreSpreadOverTheStretchAndNotTakenFromOneCorner() {
        // Six frames of about the same structure and one much poorer: the poor one is out,
        // and the six are taken first, middle and last, not the three of the best marks side by side.
        let counts = [70, 72, 74, 76, 78, 80, 22]
        let measures = counts.enumerated().map { ScrollSeries.measure(frame(background: 5, glyphs($1, seed: 120 + $0, ink: 230))) }
        let selection = ScrollSeries.choose(measures, same: notSame)
        #expect(selection.fills == [6])
        #expect(selection.byNumber)
        #expect(selection.indices == [0, 3, 5])
    }

    @Test func framesAreAsGoodAsTheBestFromFourFifthsOfItsScore() {
        #expect(ScrollSeries.closeToBest == 0.8)
    }

    @Test func theFramesThatAreTheSamePageAsTheLastLaidOrAsOneTakenAreLeftOut() {
        let measures = [90, 60, 85, 55, 80].enumerated()
            .map { ScrollSeries.measure(frame(background: 5, glyphs($1, seed: 90 + $0, ink: 230))) }
        // The best frame shows the page that is laid, the next best shows what is taken.
        func same(_ a: Int, _ b: Int) -> Bool { (a == -1 && b == 0) || (a == 2 && b == 4) || (a == 4 && b == 2) }
        let selection = ScrollSeries.choose(measures, same: same)
        #expect(!selection.indices.contains(0))
        #expect(selection.indices.contains(2) != selection.indices.contains(4))
        #expect(selection.indices == selection.indices.sorted())
    }

    @Test func nothingIsLeftWhenEveryFrameShowsThePageLaid() {
        let measures = (0..<3).map { ScrollSeries.measure(frame(background: 5, glyphs(60, seed: 100 + $0, ink: 230))) }
        let selection = ScrollSeries.choose(measures) { a, _ in a == -1 }
        #expect(selection.indices.isEmpty)
        #expect(ScrollSeries.choose([], same: notSame).indices.isEmpty)
    }

    @Test func fewFramesAreTakenWholeExceptTheFills() {
        let frames = [frame(background: 5, glyphs(60, seed: 110, ink: 230)),
                      fill(background: 5, color: 235, seed: 111, ink: 230)]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.indices == [0])
        #expect(selection.fills == [1])
    }
}
