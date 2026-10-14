import CoreGraphics
import Testing
@testable import Stampo

/// `ImageAssembler.replaceLast(with:)`: the page did not move, a section pinned
/// to the viewport changed its stage, and the image is to have the last frame
/// laid as it is now. Scenes as in `SeamScenes`: frames of 60 by 200, each 60 rows
/// further on than the last, the seam of a frame in the middle of the overlap;
/// so that the third frame's floor is 70 − 60 = 10 of its rows.
@Suite struct ImageAssemblerReplaceTests {
    typealias Scene = SeamScenes.Scene

    /// The assembler with the three frames of `scene` laid, as before a push.
    private func laid(_ scene: Scene) throws -> ImageAssembler {
        var assembler = ImageAssembler(axis: scene.axis, maxLength: 10_000, scale: scene.scale)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        for index in 1..<scene.states.count {
            try assembler.append(SeamScenes.frame(index, of: scene), movement: SeamScenes.movement)
        }
        return assembler
    }

    /// The last frame, as the pinned section shows it a stage later: the same
    /// page, the element finished.
    private func later(_ scene: Scene) -> CaptureFrame {
        var finished = scene
        finished.states[scene.states.count - 1] = .finished
        return SeamScenes.frame(scene.states.count - 1, of: finished)
    }

    @Test func theNewFrameTakesTheLastOnesPlaceAndTheImageIsAsLongAsItWas() throws {
        let scene = Scene(element: 160..<190, states: [.absent, .absent, .absent])
        var assembler = try laid(scene)
        let length = assembler.totalLength
        // Before: no element in the image.
        #expect(SeamScenes.firstMismatch(of: try assembler.makeImage(), in: scene, as: .finished) != nil)
        try assembler.replaceLast(with: later(scene))
        #expect(assembler.totalLength == length && assembler.fullLength == length)
        // After: the image is the page with the element finished.
        #expect(SeamScenes.firstMismatch(of: try assembler.makeImage(), in: scene, as: .finished) == nil)
    }

    /// The seam before the last frame was at row 70 of the frame before, which
    /// is row 10 of the last: what that frame had given stays.
    @Test func whatTheFrameBeforeHadGivenAboveTheFloorStays() throws {
        // The element at page rows 122–127: rows 2–7 of the last frame, above its floor of 10.
        let scene = Scene(element: 122..<128, states: [.absent, .absent, .absent])
        var assembler = try laid(scene)
        try assembler.replaceLast(with: later(scene))
        let image = try assembler.makeImage()
        // The earlier frames' rows: no element, the plain page.
        #expect(SeamScenes.isPlainPage(image, in: scene, rows: 118..<130))
        // From the floor on, the new frame's: page rows 130 and on are the page too, there is no element there.
        #expect(SeamScenes.firstMismatch(of: image, in: scene, as: .absent) == nil)
    }

    @Test func aHorizontalImageIsReplacedTheSameWay() throws {
        let scene = Scene(axis: .horizontal, element: 160..<190, states: [.absent, .absent, .absent])
        var assembler = try laid(scene)
        let length = assembler.totalLength
        try assembler.replaceLast(with: later(scene))
        #expect(assembler.totalLength == length)
        #expect(SeamScenes.firstMismatch(of: try assembler.makeImage(), in: scene, as: .finished) == nil)
    }

    @Test func aHalvedImageIsReplacedInItsOwnPixelsAndStaysAsLong() throws {
        let scene = Scene(element: 160..<190, states: [.absent, .absent, .absent])
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        try assembler.append(SeamScenes.frame(1, of: scene), movement: SeamScenes.movement)
        assembler.shrinkToHalf()
        try assembler.append(SeamScenes.frame(2, of: scene), movement: SeamScenes.movement)
        let length = assembler.totalLength
        try assembler.replaceLast(with: later(scene))
        #expect(assembler.isShrunk)
        #expect(assembler.totalLength == length && length == assembler.fullLength / 2)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image.height == length)
        // Page rows 174 and 175, in the element: finished now.
        #expect(image[20, 87, 0] < 25, "\(image[20, 87, 0])")
        // Strips still tile the image.
        var start = 0
        for strip in assembler.strips {
            #expect(strip.start == start)
            start += strip.frame.height
        }
        #expect(start == length)
    }

    /// The next frame is laid against the new one: the element is finished in
    /// both, so that the frames agree in the middle of their overlap — which
    /// they would not against the frame that was replaced.
    @Test func theNextFrameIsLaidAgainstTheNewOne() throws {
        let element = 240..<270
        var assembler = try laid(Scene(element: element, states: [.absent, .absent, .absent]))
        // The last frame, as the section shows it later: the element finished.
        try assembler.replaceLast(with: SeamScenes.frame(2, of: Scene(element: element,
                                                                      states: [.absent, .absent, .finished])))
        let next = Scene(element: element, states: [.absent, .absent, .finished, .finished])
        try assembler.append(SeamScenes.frame(3, of: next), movement: SeamScenes.movement)
        #expect(assembler.lastSeam == ScrollSeam.Choice(skip: 70, reason: .middleAgrees))
    }

    @Test func thereMustBeAFrameOfTheSameSizeToReplace() {
        var empty = ImageAssembler(axis: .vertical)
        var threwWithoutFrames = false
        do { try empty.replaceLast(with: SeamScenes.frame(0, of: Scene())) } catch { threwWithoutFrames = true }
        #expect(threwWithoutFrames)

        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: SeamScenes.frame(0, of: Scene()))
        let other = CaptureFrame(width: 10, height: 10, pixels: [UInt8](repeating: 0, count: 400))
        var threwWithAnother = false
        do { try assembler.replaceLast(with: other) } catch { threwWithAnother = true }
        #expect(threwWithAnother)
    }

    /// The first frame has no frame before it: it is replaced whole.
    @Test func theFirstFrameIsReplacedWhole() throws {
        let scene = Scene(element: 20..<60, states: [.absent])
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        var finished = scene
        finished.states[0] = .finished
        try assembler.replaceLast(with: SeamScenes.frame(0, of: finished))
        #expect(assembler.totalLength == SeamScenes.length)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image[20, 30, 0] == 10)
    }
}
