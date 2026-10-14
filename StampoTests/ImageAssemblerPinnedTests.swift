import CoreGraphics
import Testing
@testable import Stampo

/// A pinned element is in the image once: where the capture began, and where it ended. Between, the page under
/// it. The scenes are those of `PinnedScenes`: 480 by 800 frames, 400 rows a step, a card at the bottom right.
@Suite struct ImageAssemblerPinnedTests {
    typealias Scene = PinnedScenes.Scene
    private let movement = PinnedScenes.movement, height = PinnedScenes.height, width = PinnedScenes.width

    private struct Built {
        var image: CaptureFrame
        var assembler: ImageAssembler
        var repairs: [ScrollPinned.Repair?]
        /// What settling the capture's end mended.
        var settled: ScrollPinned.Repair?
    }

    /// The image of `frames` frames of a scene, with the pinned blocks of each pair given or not. `shrinkBefore`: drop
    /// the image to half before laying the frame of that index; `header`: rows of a header above it; `replace`: after
    /// frame `index` is laid, replace it by a frame of the scene with these `extra` pixels.
    private func build(_ scene: Scene, frames: Int, pinned: Bool, shrinkBefore: Int? = nil, header: Int? = nil,
                       replace: (index: Int, extra: (Int, Int) -> UInt8?)? = nil) throws -> Built {
        let movement = scene.step
        var assembler = ImageAssembler(axis: .vertical, maxLength: 100_000, scale: 1)
        var previous = PinnedScenes.frame(0, of: scene)
        assembler.begin(with: previous)
        if let header {
            let rows = CaptureFrame(width: width, height: header,
                                    pixels: [UInt8](repeating: 17, count: width * header * 4))
            let taken = assembler.setHeader(rows)
            #expect(taken)
        }
        var repairs: [ScrollPinned.Repair?] = []
        for index in 1..<frames {
            if shrinkBefore == index { assembler.shrinkToHalf() }
            let frame = PinnedScenes.frame(index, of: scene)
            let blocks = pinned ? ScrollPinned.pinnedBlocks(previous: previous, current: frame, shift: movement) : nil
            try assembler.append(frame, movement: movement, pinned: blocks)
            repairs.append(assembler.lastRepair)
            previous = frame
            if let replace, replace.index == index {
                let stage = PinnedScenes.frame(index, of: scene, extra: replace.extra)
                try assembler.replaceLast(with: stage)
                previous = stage
            }
        }
        // The end of the capture, as the session finishes it.
        assembler.settlePending()
        let settled = assembler.lastRepair
        let image = try #require(CaptureFrame(image: assembler.makeImage()))
        return Built(image: image, assembler: assembler, repairs: repairs, settled: settled)
    }

    /// The pixels of `frame`, whose top is at row `top` of the image, over `rows` and `columns` of the image.
    private func paint(_ image: inout CaptureFrame, rows: Range<Int>, columns: Range<Int>, from frame: CaptureFrame,
                       top: Int) {
        var pixels = image.pixels
        for y in rows {
            for x in columns {
                let from = ((y - top) * width + x) * 4, to = (y * width + x) * 4
                for c in 0..<4 { pixels[to + c] = frame.pixels[from + c] }
            }
        }
        image = CaptureFrame(width: image.width, height: image.height, pixels: pixels, colorSpace: image.colorSpace)
    }

    /// The first place in `rows` where the images differ by more than `tolerance` levels.
    private func firstMismatch(_ a: CaptureFrame, _ b: CaptureFrame, rows: Range<Int>, tolerance: Int = 0) -> String? {
        guard a.width == b.width else { return "widths \(a.width), \(b.width)" }
        for y in rows {
            let from = y * a.width * 4, to = (y + 1) * a.width * 4
            if a.pixels[from..<to] != b.pixels[from..<to] {
                for x in 0..<a.width {
                    for c in 0..<3 {
                        let i = (y * a.width + x) * 4 + c
                        if abs(Int(a.pixels[i]) - Int(b.pixels[i])) > tolerance {
                            return "row \(y) column \(x): \(a.pixels[i]), \(b.pixels[i])"
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: A card at the corner

    /// The card is on the first screen whole, under it in the slices between, and at the end where the window
    /// ended. What is under the card in the slices comes from the frame that follows, where it lies above the
    /// card: the image is the image of a page that had no card there.
    @Test func aCardIsInTheImageOnceAtTheStartAndOnceAtTheEnd() throws {
        let frames = 6
        let mended = try build(Scene(), frames: frames, pinned: true)
        let clean = try build(Scene(card: false), frames: frames, pinned: false)
        #expect(mended.image.height == clean.image.height)
        // What the image should be: the page, with the card of the first frame where the first screen has it,
        // and the card of the last frame where the last screen has it.
        var expected = clean.image
        let card = Int(PinnedScenes.card.minX)..<Int(PinnedScenes.card.maxX)
        let cardRows = Int(PinnedScenes.card.minY)..<Int(PinnedScenes.card.maxY)
        paint(&expected, rows: cardRows, columns: card, from: PinnedScenes.frame(0, of: Scene()), top: 0)
        let lastTop = (frames - 1) * movement
        let lastRows = (lastTop + cardRows.lowerBound)..<(lastTop + cardRows.upperBound)
        paint(&expected, rows: lastRows, columns: card, from: PinnedScenes.frame(frames - 1, of: Scene()), top: lastTop)
        let mismatch = firstMismatch(mended.image, expected, rows: 0..<expected.height)
        #expect(mismatch == nil, "\(mismatch ?? "")")
        // The pieces of the card at the seams were there before.
        let unmended = try build(Scene(), frames: frames, pinned: false)
        #expect(firstMismatch(unmended.image, expected, rows: 0..<expected.height) != nil)
    }

    /// While the capture is young the slices wait: an element that sticks only after the first scroll has shown itself
    /// in few pairs. Once `waitingPairs` pairs are in they are mended together, and then the slice of the frame before
    /// the last as each frame comes; at the end the slice of the frame before the last is mended with what there is
    /// and the last is left as it came.
    @Test func theSlicesWaitWhileTheCaptureIsYoungAndAreMendedTogether() throws {
        let frames = ScrollPinned.waitingPairs + 3
        let built = try build(Scene(), frames: frames, pinned: true)
        // append(k) lays frame k: the pairs seen are k.
        for k in 1..<ScrollPinned.waitingPairs { #expect(built.repairs[k - 1] == nil, "append \(k)") }
        let together = try #require(built.repairs[ScrollPinned.waitingPairs - 1])
        let one = try #require(built.repairs[ScrollPinned.waitingPairs])
        // Frames 1 to 4 wait; the first screen is not a slice. Together they are more than the one that follows.
        #expect(together.blocks > one.blocks && one.blocks > 0)
        #expect(one.fromNeighbour == one.blocks && one.filled == 0)
        #expect(built.repairs[ScrollPinned.waitingPairs + 1] != nil)
        let settled = try #require(built.settled)
        #expect(settled.blocks > 0)
    }

    /// A short capture mends its slices at the end.
    @Test func aShortCaptureIsMendedWhenItEnds() throws {
        let built = try build(Scene(), frames: 5, pinned: true)
        #expect(built.repairs.allSatisfy { $0 == nil })
        let settled = try #require(built.settled)
        #expect(settled.blocks > 0)
        let clean = try build(Scene(card: false), frames: 5, pinned: false)
        for k in 1...3 {
            let from = k == 1 ? 800 : k * movement + 200, to = k * movement + 600
            let mismatch = firstMismatch(built.image, clean.image, rows: from..<to)
            #expect(mismatch == nil, "slice \(k): \(mismatch ?? "")")
        }
    }

    /// A card taller than what the page leaves above it (its top at 300 of 800 rows, the step 400) covers a strip
    /// of the page that no frame shows: the card's own blocks are flat there, and the margin round it — page — is
    /// the frame's own.
    @Test func aTallCardLeavesTheMarginOfItsGapAsThePage() throws {
        let frames = 7
        let tall = Scene(cardRect: CGRect(x: 296, y: 300, width: 160, height: 500))
        let mended = try build(tall, frames: frames, pinned: true)
        let clean = try build(Scene(card: false), frames: frames, pinned: false)
        // The gap is frame rows 260 (the card's top less its margin) to 400, in the slice of frame 3.
        let y = 3 * movement + 330
        // The margin to the left of the card (columns 256 to 280, beyond the card's own reach): the page, the same
        // as the clean image.
        for x in stride(from: 258, to: 278, by: 3) {
            #expect(mended.image[x, y, 0] == clean.image[x, y, 0], "column \(x)")
        }
        // The card's own blocks and the reach round them: one colour, not the page.
        let flat = mended.image[330, y, 0]
        var different = 0
        for x in stride(from: 304, to: 448, by: 4) {
            #expect(mended.image[x, y, 0] == flat, "column \(x)")
            if clean.image[x, y, 0] != flat { different += 1 }
        }
        #expect(different > 20)
        let built = try #require(mended.settled)
        #expect(built.kept > 0 && built.filled > 0)
    }

    /// A card taller than the step is under the card still in the next frame for the lower part of the slice: the
    /// frame after that shows it. The card begins at 280 of 800 rows, the step is 200: the slice is rows 300 to 500
    /// and what is under the card in the next frame is from row 440. Without the frame after next it is flat.
    @Test func thePageUnderATallCardComesFromTheFrameAfterNext() throws {
        let frames = 7
        let tall = Scene(cardRect: CGRect(x: 296, y: 280, width: 160, height: 520), step: 200)
        let mended = try build(tall, frames: frames, pinned: true)
        let clean = try build(Scene(card: false, step: 200), frames: frames, pinned: false)
        // Frame 3 is at 600 in the image: its rows 440 to 500 are the lower part of its slice.
        var checked = 0
        for y in stride(from: 600 + 444, to: 600 + 496, by: 7) {
            for x in stride(from: 304, to: 448, by: 8) {
                #expect(mended.image[x, y, 0] == clean.image[x, y, 0], "row \(y) column \(x)")
                checked += 1
            }
        }
        #expect(checked > 100)
    }

    @Test func aPageWithNothingPinnedIsLaidAsItAlwaysWasByteForByte() throws {
        let scene = Scene(card: false)
        let with = try build(scene, frames: 6, pinned: true)
        let without = try build(scene, frames: 6, pinned: false)
        #expect(with.image == without.image)
        #expect(with.repairs.allSatisfy { $0 == nil })
    }

    /// Without the blocks of the pairs the assembler does what it did: a card in the frames is in the image at every seam.
    @Test func withoutPinnedBlocksNothingIsMended() throws {
        let scene = Scene()
        let a = try build(scene, frames: 6, pinned: false)
        var plain = ImageAssembler(axis: .vertical, maxLength: 100_000, scale: 1)
        plain.begin(with: PinnedScenes.frame(0, of: scene))
        for index in 1..<6 { try plain.append(PinnedScenes.frame(index, of: scene), movement: movement) }
        #expect(try #require(CaptureFrame(image: plain.makeImage())) == a.image)
    }

    /// An element that is in one pair is nothing: a card that came in at the fourth frame and went at the fifth.
    @Test func aCardThatStandsInOnePairOnlyIsNotARegion() throws {
        let scene = Scene(cardFrames: 3..<5)
        let with = try build(scene, frames: 7, pinned: true)
        let without = try build(scene, frames: 7, pinned: false)
        #expect(with.image == without.image)
    }

    // MARK: A panel along the whole side

    /// The panel is on the first screen and at the end; between there is a column of the colour round it — the page
    /// behind a panel that is there in every frame is not in any.
    @Test func aPanelAlongTheWholeSideIsAColumnOfBackgroundBetweenTheFirstScreenAndTheLast() throws {
        let scene = Scene(card: false, panel: true)
        let frames = 6
        let built = try build(scene, frames: frames, pinned: true)
        let panel = 8..<(PinnedScenes.panelWidth - 8)
        // A slice in the middle: one colour, and not the panel's.
        let top = 2 * movement
        let first = built.image[panel.lowerBound, top + 250, 0]
        for y in (top + 220)..<(top + 580) {
            for x in panel where built.image[x, y, 0] != first {
                Issue.record("row \(y) column \(x): \(built.image[x, y, 0]), not \(first)")
                return
            }
        }
        #expect(first != SeamScenes.panelPixel(top + 250 + 3_000, panel.lowerBound))
        // The first screen as the window showed it, below the first seam as above it.
        let frame0 = PinnedScenes.frame(0, of: scene)
        for y in stride(from: 0, to: height, by: 13) {
            for x in stride(from: 0, to: PinnedScenes.panelWidth, by: 7) where built.image[x, y, 0] != frame0[x, y, 0] {
                Issue.record("first screen, row \(y) column \(x)")
                return
            }
        }
        // And the last frame is left as it was.
        let lastTop = (frames - 1) * movement
        let last = PinnedScenes.frame(frames - 1, of: scene)
        for y in stride(from: lastTop + 250, to: lastTop + height, by: 13) {
            for x in stride(from: 0, to: PinnedScenes.panelWidth, by: 7) where built.image[x, y, 0] != last[x, y - lastTop, 0] {
                Issue.record("last screen, row \(y) column \(x)")
                return
            }
        }
    }

    // MARK: Half size, a stage replaced, a header

    /// Halved the image is mended the same: the frames are worked from whole, and halved as they are laid.
    /// The image is halved before frame 3 or 4 is laid: slices that waited for evidence were cut when it was whole.
    @Test(arguments: [3, 4]) func inTheHalvedImageTheSlicesAreMendedAsWell(shrinkBefore: Int) throws {
        let frames = 6
        let mended = try build(Scene(), frames: frames, pinned: true, shrinkBefore: shrinkBefore)
        let clean = try build(Scene(card: false), frames: frames, pinned: false, shrinkBefore: shrinkBefore)
        #expect(mended.assembler.isShrunk && mended.image.height == clean.image.height)
        // The middle slices are the clean image's — below the first screen, and to within a few levels: a slice halved
        // alone is resampled a little differently from the whole rest of its frame, which is rounded to the rows that
        // fit, and on noise a shift of a fraction of a row shows. The card's pixels are further off than that.
        for k in 1...(frames - 2) {
            let slice = (k * movement + 200) / 2 ..< (k * movement + 600) / 2
            let from = k == 1 ? (800 / 2 + 8) : slice.lowerBound + 8
            let mismatch = firstMismatch(mended.image, clean.image, rows: from..<(slice.upperBound - 8), tolerance: 24)
            #expect(mismatch == nil, "slice \(k): \(mismatch ?? "")")
        }
        // The first screen is whole there too: the card, where the page is in the image without it.
        let card = PinnedScenes.card
        let y = (Int(card.minY) + Int(card.maxY)) / 2 / 2
        let x = (Int(card.minX) + 40) / 2
        #expect(mended.image[x, y, 0] != clean.image[x, y, 0])
    }

    /// A frame that replaces the last one (a stage of a section) is the one that is mended, from its neighbours.
    @Test func aFrameThatReplacesTheLastIsMendedLikeAnyOther() throws {
        let frames = 6
        let stripe: (Int, Int) -> UInt8? = { y, _ in (120..<150).contains(y) ? 7 : nil }
        let mended = try build(Scene(), frames: frames, pinned: true, replace: (3, stripe))
        let clean = try build(Scene(card: false), frames: frames, pinned: false, replace: (3, stripe))
        // Slices 1 to 4 are the clean image's, but for the first screen, the card whole down to row 784.
        for k in 1...(frames - 2) {
            let from = k == 1 ? 800 : k * movement + 200, to = k * movement + 600
            let mismatch = firstMismatch(mended.image, clean.image, rows: from..<to)
            #expect(mismatch == nil, "slice \(k): \(mismatch ?? "")")
        }
        // The stage is in the image.
        #expect(mended.image[100, 3 * movement + 130, 0] == 7)
    }

    /// The header sits above the image and the first screen is laid in the image's own rows below it.
    @Test func aHeaderMovesNothingOfTheMending() throws {
        let frames = 6, header = 40
        let mended = try build(Scene(), frames: frames, pinned: true, header: header)
        let clean = try build(Scene(card: false), frames: frames, pinned: false, header: header)
        for k in 1...(frames - 2) {
            let from = header + (k == 1 ? 800 : k * movement + 200), to = header + k * movement + 600
            let mismatch = firstMismatch(mended.image, clean.image, rows: from..<to)
            #expect(mismatch == nil, "slice \(k): \(mismatch ?? "")")
        }
        // The first screen: the card at its place, below the header.
        let card = PinnedScenes.card
        let y = header + Int(card.minY) + 150
        #expect(mended.image[Int(card.minX) + 40, y, 0] == PinnedScenes.frame(0, of: Scene())[Int(card.minX) + 40, Int(card.minY) + 150, 0])
        #expect(mended.image[10, 5, 0] == 17)
    }
}
