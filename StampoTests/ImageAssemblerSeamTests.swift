import CoreGraphics
import Testing
@testable import Stampo

/// Where the seam between two frames falls (`ScrollSeam`), on the scenes in
/// `SeamScenes`: 60 rows by 200, 60 rows further on each time, so that the
/// middle of the overlap of any two is row 70 of the later frame.
@Suite struct ImageAssemblerSeamTests {
    typealias Scene = SeamScenes.Scene
    private let middle = ScrollSeam.Choice(skip: 70, reason: .middleAgrees)

    @Test func anHonestScrollKeepsTheSeamInTheMiddle() throws {
        let scene = Scene(states: [.absent, .absent])
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [middle])
        #expect(outcome.seams.first?.note == nil)
        #expect(SeamScenes.firstMismatch(of: outcome.image, in: scene, as: .absent) == nil)
    }

    /// The element is pale and five rows low in the earlier frame and finished
    /// in the later; it lies across the middle. The frames agree again just
    /// above it, so the seam goes there and the element comes whole from the
    /// later frame.
    @Test func anElementStillArrivingAcrossTheMiddleIsTakenWholeFromTheLaterFrame() throws {
        let scene = Scene(states: [.pale, .finished])
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [ScrollSeam.Choice(skip: 59, reason: .moved(11))])
        #expect(outcome.seams.first?.note == "seam −11 px")
        #expect(SeamScenes.firstMismatch(of: outcome.image, in: scene, as: .finished) == nil)
    }

    /// A panel floating over the page stays where it is while the page moves
    /// under it. Above the band that is arriving it is the frame's own; a seam
    /// that rose above it would lay it into the image in the middle of the page.
    /// Here the rows between the panel and the band are too few to be a run, so
    /// the seam stays in the middle, and the panel is in the image only where
    /// the first frame has it.
    @Test func aPanelFixedJustAboveTheBandKeepsTheSeamInTheMiddle() throws {
        let scene = Scene(element: 180..<210, panel: 30..<56, states: [.pale, .pale, .finished])
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [middle, ScrollSeam.Choice(skip: 70, reason: .floor)])
        #expect(outcome.seams.last?.note == "seam middle (floor)")
        // The later frames' panels would be at page rows 90–115 and 150–175.
        #expect(SeamScenes.isPlainPage(outcome.image, in: scene, rows: 90..<116))
        #expect(SeamScenes.isPlainPage(outcome.image, in: scene, rows: 150..<176))
    }

    /// The same panel with a stretch of page between it and the band: the seam
    /// goes up into the stretch and stops under the panel, which is not in the
    /// image except as the first frame has it.
    @Test func aPanelFixedFurtherAboveLetsTheSeamRiseToTheBand() throws {
        let scene = Scene(element: 180..<210, panel: 20..<40, states: [.pale, .pale, .finished])
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [middle, ScrollSeam.Choice(skip: 59, reason: .moved(11))])
        // Everything but the first frame's own panel is the finished page.
        #expect(SeamScenes.firstMismatch(of: outcome.image, in: scene, as: .finished, ignoring: 20..<40) == nil)
    }

    /// Eight points of rows that agree, whatever the pixels to a point: 11 rows
    /// between the panel and the band are enough at 1x and not at 2x.
    @Test func aRunIsEightPointsWhateverTheScale() throws {
        let base = Scene(element: 180..<210, panel: 20..<49, states: [.pale, .pale, .finished])
        var onePixel = base
        onePixel.scale = 1
        var twoPixels = base
        twoPixels.scale = 2
        #expect(try SeamScenes.run(onePixel).seams.last == ScrollSeam.Choice(skip: 59, reason: .moved(11)))
        #expect(try SeamScenes.run(twoPixels).seams.last == ScrollSeam.Choice(skip: 70, reason: .floor))
    }

    /// The earlier frame has text where the later one is still blank: laying
    /// the later frame's rows over it would lose the text, so the middle stays.
    @Test func textThatTheLaterFrameHasNotYetDrawnKeepsTheSeamInTheMiddle() throws {
        let scene = Scene(element: 120..<150, columns: 0..<60, states: [.absent, .blank])
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [ScrollSeam.Choice(skip: 70, reason: .details)])
        #expect(outcome.seams.first?.note == "seam middle (details)")
    }

    /// The seam does not rise above where the one before it fell: only rows
    /// the earlier frame gave are replaced. Here the band begins at row 10 of
    /// the later frame and the seam before was at 70 of a frame 60 rows back.
    @Test func theSeamDoesNotRiseAboveTheOneBeforeIt() throws {
        let high = Scene(element: 130..<210, states: [.pale, .pale, .finished])
        #expect(try SeamScenes.run(high).seams == [middle, ScrollSeam.Choice(skip: 70, reason: .floor)])
        // Ten rows lower there are 20 rows above the band that agree, and 8 of
        // them fit over the floor.
        let low = Scene(element: 140..<210, states: [.pale, .pale, .finished])
        #expect(try SeamScenes.run(low).seams == [middle, ScrollSeam.Choice(skip: 19, reason: .moved(51))])
    }

    @Test func aHorizontalScrollMovesTheSeamTheSameWay() throws {
        let scene = Scene(axis: .horizontal, states: [.pale, .finished])
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [ScrollSeam.Choice(skip: 59, reason: .moved(11))])
        #expect(SeamScenes.firstMismatch(of: outcome.image, in: scene, as: .finished) == nil)
    }

    /// Halved, the image is as long as it would have been with the seam in the
    /// middle, and the band is the later frame's all the same.
    @Test func afterTheImageIsHalvedTheBandStillComesFromTheLaterFrame() throws {
        var scene = Scene(states: [.pale, .finished])
        scene.shrinkBefore = 1
        let outcome = try SeamScenes.run(scene)
        #expect(outcome.seams == [ScrollSeam.Choice(skip: 59, reason: .moved(11))])
        #expect(outcome.assembler.isShrunk)
        #expect(outcome.assembler.totalLength == outcome.assembler.fullLength / 2)
        #expect(outcome.assembler.fullLength == SeamScenes.length + SeamScenes.movement)
        let image = try #require(CaptureFrame(image: outcome.image))
        #expect(image.height == (SeamScenes.length + SeamScenes.movement) / 2)
        // Page rows 126 and 127, inside the element: dark from the later frame.
        // The earlier frame has the pale element there, at 40.
        #expect(image[15, 63, 0] < 25, "\(image[15, 63, 0])")
    }

    /// The frames of a capture that is stopped and started again begin a new
    /// assembler, whose first frame has no seam before it.
    @Test func aResetAssemblerForgetsTheFramesBefore() throws {
        let scene = Scene(states: [.pale, .finished])
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        try assembler.append(SeamScenes.frame(1, of: scene), movement: SeamScenes.movement)
        #expect(assembler.lastSeam != nil)
        assembler.reset()
        #expect(assembler.lastSeam == nil)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        #expect(assembler.lastSeam == nil)
    }
}
