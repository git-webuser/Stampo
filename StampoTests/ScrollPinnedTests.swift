import CoreGraphics
import Testing
@testable import Stampo

/// Frames of a page of noise that moves `movement` rows a step, with a card over its corner that stays where it
/// is — the "Latest news" of claude.com — and, if asked, a panel along the whole left side. 480 by 800: 60 by 100 blocks.
nonisolated enum PinnedScenes {
    static let width = 480, height = 800
    static let movement = 400
    /// The card: 160 by 200, at the bottom right of the frame.
    static let card = CGRect(x: 296, y: 584, width: 160, height: 200)
    /// A panel along the whole side.
    static let panelWidth = 96

    struct Scene {
        var card = true
        var panel = false
        /// The frames the card is in; all of them when nil.
        var cardFrames: Range<Int>?
        /// The page's own pixel, by row of the page and column; replaced to give a frame its own look.
        var page: (Int, Int) -> UInt8 = { SeamScenes.page($0, $1) }
    }

    static func frame(_ index: Int, of scene: Scene, extra: ((Int, Int) -> UInt8?)? = nil) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = scene.page(index * movement + y, x)
                if let extra, let own = extra(y, x) { value = own }
                if scene.card, scene.cardFrames?.contains(index) ?? true, card.contains(CGPoint(x: x, y: y)) {
                    value = SeamScenes.panelPixel(y, x)
                }
                if scene.panel, x < panelWidth { value = SeamScenes.panelPixel(y &+ 3_000, x) }
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// The blocks of the pair of frames `index − 1` and `index`.
    static func pair(_ index: Int, of scene: Scene) -> PinnedGrid {
        ScrollPinned.pinnedBlocks(previous: frame(index - 1, of: scene), current: frame(index, of: scene),
                                  shift: movement)!
    }
}

/// What the pinned blocks of a capture are, and how a slice is mended.
@Suite struct ScrollPinnedTests {
    typealias Scene = PinnedScenes.Scene
    private let block = ScrollPinned.block

    private func blocks(_ rect: CGRect) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for row in Int(rect.minY) / block ..< Int(rect.maxY) / block {
            for column in Int(rect.minX) / block ..< Int(rect.maxX) / block { out.append((column, row)) }
        }
        return out
    }

    @Test func theBlocksOfACardThatStandsWhileThePageMovesArePinned() {
        let grid = PinnedScenes.pair(1, of: Scene())
        let inside = blocks(PinnedScenes.card)
        #expect(inside.allSatisfy { grid[$0.0, $0.1] })
        // Nothing of the page, which moved: noise is never the same at the same place.
        #expect(grid.count == inside.count, "\(grid.count) pinned, the card has \(inside.count)")
    }

    @Test func aPanelAlongTheWholeSideIsPinnedToo() {
        let grid = PinnedScenes.pair(1, of: Scene(card: false, panel: true))
        let panel = blocks(CGRect(x: 0, y: 0, width: PinnedScenes.panelWidth, height: PinnedScenes.height))
        #expect(panel.allSatisfy { grid[$0.0, $0.1] })
        #expect(grid.count == panel.count)
    }

    @Test func aPageWithNothingPinnedHasNoPinnedBlocks() {
        #expect(PinnedScenes.pair(1, of: Scene(card: false)).isEmpty)
    }

    /// A blank background is the same in every frame and has nothing in it to be pinned.
    @Test func anEmptyBackgroundIsNotPinned() {
        let blank = CaptureFrame(width: 480, height: 800, pixels: [UInt8](repeating: 240, count: 480 * 800 * 4))
        #expect(ScrollPinned.pinnedBlocks(previous: blank, current: blank, shift: 400)?.isEmpty == true)
        #expect(ScrollPinned.pinnedBlocks(previous: blank, current: blank, shift: nil)?.isEmpty == true)
    }

    /// A page whose pattern repeats at the distance it moved is the same at the same place by chance. With the shift
    /// known, the moved page is seen to fit and the blocks are left out; without it they are taken as pinned.
    @Test func whatTheMovedPageFitsIsNotPinnedWhenTheShiftIsKnown() {
        let page: (Int, Int) -> UInt8 = { SeamScenes.page($0 % 400, $1) }
        let scene = Scene(card: false, page: page)
        let a = PinnedScenes.frame(0, of: scene), b = PinnedScenes.frame(1, of: scene)
        // Where the earlier frame has the place the shift gives (the upper half: 400 rows down is the frame's
        // 49th row of blocks) the moved page is seen to fit; below it nothing can be said, and it is taken as pinned.
        let known = ScrollPinned.pinnedBlocks(previous: a, current: b, shift: 400)!
        let unknown = ScrollPinned.pinnedBlocks(previous: a, current: b, shift: nil)!
        let upper = (0..<(49 * known.columns)).filter { known.cells[$0] }.count
        #expect(upper == 0)
        #expect((0..<(49 * unknown.columns)).filter { unknown.cells[$0] }.count > 0)
    }

    @Test func framesOfDifferentSizesHaveNoPinnedBlocks() {
        let a = PinnedScenes.frame(0, of: Scene())
        let small = CaptureFrame(width: 400, height: 800, pixels: [UInt8](repeating: 0, count: 400 * 800 * 4))
        #expect(ScrollPinned.pinnedBlocks(previous: a, current: small, shift: 400) == nil)
    }

    // MARK: The regions

    private func accumulate(_ pairs: Int, scene: Scene = Scene()) -> ScrollPinned.Accumulator {
        var accumulator = ScrollPinned.Accumulator()
        for index in 1...pairs { accumulator.add(PinnedScenes.pair(index, of: scene)) }
        return accumulator
    }

    /// One pair is a coincidence: it takes two to be a pinned element.
    @Test func aRegionNeedsTwoPairs() {
        var one = accumulate(1)
        let fromOne = one.region(for: PinnedScenes.pair(1, of: Scene()))
        #expect(fromOne.isEmpty)
        var two = accumulate(2)
        let fromTwo = two.region(for: PinnedScenes.pair(2, of: Scene()))
        #expect(!fromTwo.isEmpty)
    }

    /// The region is the card's box and five blocks round it (the frame is 60 by 100 blocks, the card 20 by 25 at
    /// its bottom right: the margin is cut by the edges there).
    @Test func theRegionIsTheBoxOfTheCardWithAMarginOfFiveBlocks() {
        var accumulator = accumulate(3)
        let region = accumulator.region(for: PinnedScenes.pair(3, of: Scene()))
        let card = PinnedScenes.card
        let first = Int(card.minX) / block, last = Int(card.maxX) / block - 1
        let top = Int(card.minY) / block, bottom = Int(card.maxY) / block - 1
        #expect(region[first, top] && region[last, bottom])
        // The margin: five blocks left of the card and five above it are covered, six are not.
        #expect(region[first - 5, top] && region[first, top - 5])
        #expect(!region[first - 6, top] && !region[first, top - 6])
        // And nothing far off.
        #expect(!region[5, 5] && !region[30, 20])
        #expect(region.count == (59 - (first - 5) + 1) * (99 - (top - 5) + 1))
    }

    /// Pinned elements are in most pairs. A card that is in two pairs out of five is one — the active item of a
    /// menu is in as many — and a frame that does not have it is not covered by it.
    @Test func aPieceNeedsTwoFifthsOfThePairsAndTheFrameNeedsToHaveIt() {
        let withCard = PinnedScenes.pair(1, of: Scene())
        let without = PinnedScenes.pair(1, of: Scene(card: false))
        var accumulator = ScrollPinned.Accumulator()
        for pair in [withCard, without, without, without, without] { accumulator.add(pair) }
        // One of five: not stable.
        let oneOfFive = accumulator.region(for: withCard)
        #expect(oneOfFive.isEmpty)
        accumulator.add(withCard)
        // Two of six: not yet (the least is two, but two fifths of six is 2.4, three).
        let twoOfSix = accumulator.region(for: withCard)
        #expect(twoOfSix.isEmpty)
        var enough = ScrollPinned.Accumulator()
        for pair in [withCard, without, withCard, without, without] { enough.add(pair) }
        let twoOfFive = enough.region(for: withCard)
        #expect(!twoOfFive.isEmpty)
        // A frame whose own pairs have none of it is not covered.
        let without2 = enough.region(for: without)
        #expect(without2.isEmpty)
    }

    /// A pinned bar across the whole width, joined to panels at the sides, makes a piece whose box is the whole
    /// frame. It is covered as it is, with the margin, not as the box: the page between the panels is not covered.
    @Test func aPieceThatIsMostOfTheFrameIsNotMadeABox() {
        var pair = PinnedGrid(columns: 60, rows: 100)
        for row in 5..<12 { for column in 0..<60 { pair[column, row] = true } }
        for row in 5..<95 { for column in 0..<10 { pair[column, row] = true } }
        var accumulator = ScrollPinned.Accumulator()
        accumulator.add(pair); accumulator.add(pair)
        let region = accumulator.region(for: pair)
        #expect(region[30, 8] && region[3, 60])
        #expect(!region[30, 60])
    }

    // MARK: Mending a slice

    private func uniform(_ value: UInt8) -> CaptureFrame {
        CaptureFrame(width: 480, height: 800, pixels: [UInt8](repeating: value, count: 480 * 800 * 4))
    }

    private func region(_ rect: CGRect) -> PinnedGrid {
        var grid = PinnedGrid(columns: 60, rows: 100)
        for (column, row) in blocks(rect) { grid[column, row] = true }
        return grid
    }

    /// The covered blocks come from the neighbour that shows that place of the page uncovered, the one that follows
    /// first; the rest of the slice is the frame's as it was.
    @Test func coveredBlocksComeFromTheNeighbourThatShowsThePage() {
        let scene = Scene()
        let frame = PinnedScenes.frame(1, of: scene)
        let next = PinnedScenes.frame(2, of: scene), previous = PinnedScenes.frame(0, of: scene)
        let covered = region(CGRect(x: 280, y: 568, width: 200, height: 232))
        let free = PinnedGrid(columns: 60, rows: 100)
        let result = ScrollPinned.repairedSlice(
            frame: frame, rows: 200..<700, region: covered,
            neighbours: [.init(frame: next, region: free, offset: 400), .init(frame: previous, region: free, offset: -400)])
        #expect(result.slice.height == 500 && result.slice.width == 480)
        #expect(result.repair.fromNeighbour == result.repair.blocks && result.repair.filled == 0)
        // The page of frame 1 at row 600 is the page of the next frame at row 200.
        #expect(result.slice[300, 600 - 200, 0] == next[300, 600 - 400, 0])
        // And the rest is the frame's.
        #expect(result.slice[100, 100, 0] == frame[100, 300, 0])
    }

    /// A neighbour that has its own element over that place is passed over for the next, and with no neighbour that
    /// shows it the block takes the median colour of the ring round the element.
    @Test func whereNoNeighbourShowsThePageTheBlockTakesTheColourOfTheRing() {
        let frame = uniform(120)
        // A pinned element of noise in the middle of a field of 120.
        var scene = Scene(card: false)
        scene.page = { _, _ in 120 }
        let drawn = PinnedScenes.frame(1, of: scene) { y, x in (200..<280).contains(y) && (200..<280).contains(x) ? SeamScenes.page(y, x) : nil }
        _ = frame
        let covered = region(CGRect(x: 200, y: 200, width: 80, height: 80))
        let free = PinnedGrid(columns: 60, rows: 100)
        // Neither neighbour is open there: the first covers the place (what lies 100 rows off in it is covered), the
        // second is out of the frame (700 rows off).
        let covers = region(CGRect(x: 200, y: 96, width: 80, height: 96))
        let result = ScrollPinned.repairedSlice(
            frame: drawn, rows: 100..<400, region: covered,
            neighbours: [.init(frame: uniform(0), region: covers, offset: 100), .init(frame: uniform(0), region: free, offset: 700)])
        #expect(result.repair.blocks == 100 && result.repair.filled == 100 && result.repair.fromNeighbour == 0)
        #expect(result.slice[240, 140, 0] == 120 && result.slice[210, 110, 1] == 120)
        // Out of the frame is not a neighbour: the first one is passed over for the second where it is open.
        let second = ScrollPinned.repairedSlice(
            frame: drawn, rows: 100..<400, region: covered,
            neighbours: [.init(frame: uniform(0), region: covers, offset: 100), .init(frame: uniform(77), region: free, offset: 40)])
        #expect(second.repair.fromNeighbour == 100 && second.slice[240, 140, 0] == 77)
    }

    @Test func aSliceWithNoRegionIsTheSliceOfTheFrame() {
        let frame = PinnedScenes.frame(1, of: Scene())
        let result = ScrollPinned.repairedSlice(frame: frame, rows: 100..<500, region: PinnedGrid(columns: 60, rows: 100),
                                                neighbours: [])
        #expect(result.repair == ScrollPinned.Repair())
        #expect(result.slice.pixels == Array(frame.pixels[(100 * 480 * 4)..<(500 * 480 * 4)]))
    }
}
