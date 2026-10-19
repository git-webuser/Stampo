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
            Box(x: 16 + next(width - 44), y: top + next(height - top - bottom - 12), width: 3 + next(4), height: 6 + next(5),
                value: ink)
        }
    }

    /// A page that is one fill: a box of this colour over the whole width and half the height.
    private func fill(background: UInt8, color: UInt8, seed: Int, ink: UInt8) -> CaptureFrame {
        frame(background: background, [Box(x: 0, y: 32, width: width, height: 96, value: color)]
              + glyphs(3, seed: seed, ink: ink))
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

    /// A frame with a large flat card and a strip of text under it: flat, and yet a page's structure.
    private func card(seed: Int) -> CaptureFrame {
        frame(background: 5, [Box(x: 32, y: 32, width: 256, height: 96, value: 235)]
              + glyphs(70, seed: seed, ink: 230, keepOff: 136))
    }

    @Test func whenFewerThanThreeAreNoFillsFlatFramesOfStructureMakeUpTheNumber() {
        let frames = [frame(background: 5, glyphs(80, seed: 130, ink: 230)), card(seed: 131), card(seed: 132),
                      frame(background: 5, glyphs(75, seed: 133, ink: 230)), card(seed: 134)]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.indices.count == 3)
        #expect(selection.indices.contains(0) && selection.indices.contains(3))
        #expect(selection.toppedUp.count == 1 && selection.indices.contains(selection.toppedUp[0]))
        #expect(selection.fills.count == 2 && Set(selection.fills + selection.toppedUp) == [1, 2, 4])
        #expect(selection.indices == selection.indices.sorted())
    }

    @Test func framesOfTooLittleStructureAreNeverToppedUp() {
        // The two letters grown past the frame have no structure to speak of: nothing makes up the number.
        let frames = [frame(background: 5, glyphs(80, seed: 140, ink: 230)),
                      fill(background: 5, color: 235, seed: 141, ink: 230),
                      frame(background: 5, glyphs(75, seed: 142, ink: 230)),
                      fill(background: 5, color: 235, seed: 143, ink: 230)]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.indices == [0, 2])
        #expect(selection.toppedUp.isEmpty)
        #expect(selection.fills == [1, 3])
    }

    @Test func whenEveryFrameIsFlatTheBestOfThemAreTaken() {
        let frames = [card(seed: 150), card(seed: 151), card(seed: 152), card(seed: 153)]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.indices.count == 3)
        #expect(selection.toppedUp == selection.indices)
        #expect(selection.fills.count == 1)
    }

    @Test func threeFramesThatAreNoFillsAreNotToppedUp() {
        let frames = [frame(background: 5, glyphs(80, seed: 160, ink: 230)), card(seed: 161),
                      frame(background: 5, glyphs(75, seed: 162, ink: 230)),
                      frame(background: 5, glyphs(78, seed: 163, ink: 230))]
        let selection = ScrollSeries.choose(frames.map(ScrollSeries.measure), same: notSame)
        #expect(selection.indices == [0, 2, 3])
        #expect(selection.toppedUp.isEmpty)
        #expect(selection.fills == [1])
    }

    @Test func theLastBlockOfARowAndOfAColumnIsMeasured() {
        let measure = ScrollSeries.measure(frame(background: 5, []))
        // 320 by 192: ten blocks of 32 across, six down.
        #expect(measure.blockIsFlat.count == 60)
    }

    // MARK: Cut edges

    /// The same text in every frame, `extra` boxes in some, and a panel against the left edge and a ring against
    /// the top one in all of them, which are fixed to the viewport.
    private func cutPage(_ extra: [Box] = []) -> CaptureFrame {
        frame(background: 5, glyphs(60, seed: 50, ink: 230)
              + [Box(x: 0, y: 70, width: 5, height: 40, value: 200), Box(x: 150, y: 0, width: 10, height: 6, value: 200)]
              + extra)
    }

    @Test func inkThatRunsOffAnyOfTheFourEdgesCutsAFrameAndWhatIsFixedToTheViewportCutsNone() {
        let measures = [cutPage(),
                        cutPage([Box(x: 40, y: 0, width: 120, height: 8, value: 230)]),      // top
                        cutPage([Box(x: 40, y: 184, width: 120, height: 8, value: 230)]),    // bottom
                        cutPage([Box(x: 0, y: 20, width: 8, height: 100, value: 230)]),      // left
                        cutPage([Box(x: 312, y: 20, width: 8, height: 100, value: 230)]),    // right
                        cutPage()].map(ScrollSeries.measure)
        let selection = ScrollSeries.choose(measures, same: { _, _ in false })
        #expect(selection.frames.map(\.isCut) == [false, true, true, true, true, false])
        #expect(selection.frames.filter(\.isCut).allSatisfy { $0.cut >= ScrollSeries.cutFrom })
    }

    @Test func aWordThatStopsShortOfTheEdgeIsNotCut() {
        // The word is a few pixels from the left edge, and from the bottom one: whole.
        let measures = [cutPage(),
                        cutPage([Box(x: 8, y: 20, width: 40, height: 100, value: 230), Box(x: 40, y: 178, width: 120, height: 8, value: 230)]),
                        cutPage()].map(ScrollSeries.measure)
        let selection = ScrollSeries.choose(measures, same: { _, _ in false })
        #expect(!selection.frames[1].isCut)
    }

    @Test func wholeFramesGoBeforeCutOnesWhateverTheirStructure() {
        // The richest frame is cut at the left; three whole ones of less structure are there.
        let measures = [cutPage([Box(x: 0, y: 10, width: 8, height: 120, value: 230)] + glyphs(40, seed: 51, ink: 230)),
                        cutPage(), cutPage(glyphs(5, seed: 52, ink: 230)), cutPage(glyphs(8, seed: 53, ink: 230))]
            .map(ScrollSeries.measure)
        let selection = ScrollSeries.choose(measures, same: { _, _ in false })
        #expect(selection.indices == [1, 2, 3])
        #expect(selection.cut == [0])
    }

    @Test func whenFewerThanThreeAreWholeTheFramesCutTheLeastMakeUpTheNumber() {
        let measures = [cutPage(),
                        cutPage(glyphs(10, seed: 54, ink: 230)),
                        cutPage([Box(x: 0, y: 40, width: 4, height: 20, value: 230)]),    // cut a little
                        cutPage([Box(x: 0, y: 10, width: 8, height: 170, value: 230)])]   // cut a great deal
            .map(ScrollSeries.measure)
        let selection = ScrollSeries.choose(measures, same: { _, _ in false })
        #expect(selection.indices == [0, 1, 2])
        #expect(selection.cut == [2, 3])
        #expect(selection.frames[2].cut < selection.frames[3].cut)
    }

    @Test func aFrameCutOnlyBecauseOthersLackWhatItHasIsStillCutAndOnlyIfNotInEveryFrame() {
        // The same line at the top edge in every frame: it is fixed there, and no frame is cut by it.
        let line = Box(x: 30, y: 0, width: 200, height: 6, value: 230)
        let measures = (0..<4).map { _ in ScrollSeries.measure(cutPage([line])) }
        let selection = ScrollSeries.choose(measures, same: { _, _ in false })
        #expect(selection.cut.isEmpty)
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
