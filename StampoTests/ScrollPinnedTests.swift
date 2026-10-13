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
        /// Where the card is, when it is not the one of the scenes above.
        var cardRect = PinnedScenes.card
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
                if scene.card, scene.cardFrames?.contains(index) ?? true, scene.cardRect.contains(CGPoint(x: x, y: y)) {
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
    static func pair(_ index: Int, of scene: Scene, extra: ((Int, Int) -> UInt8?)? = nil) -> PinnedGrid {
        ScrollPinned.pinnedBlocks(previous: frame(index - 1, of: scene, extra: extra),
                                  current: frame(index, of: scene, extra: extra), shift: movement)!
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

    /// A box's border is a vertical line: the same in the two frames of a pair whatever the page did, and no part of
    /// a pinned element. It is not taken, so that the box round a line is not made an element.
    @Test func aVerticalLineIsNotPinned() {
        let line: (Int, Int) -> UInt8? = { _, x in x == 204 ? 0 : (x == 203 || x == 205 ? 128 : nil) }
        #expect(PinnedScenes.pair(1, of: Scene(card: false), extra: line).isEmpty)
        // The card, which changes down the frame, is still found with the line there.
        let withCard = PinnedScenes.pair(1, of: Scene(), extra: line)
        #expect(blocks(PinnedScenes.card).allSatisfy { withCard[$0.0, $0.1] })
    }

    // MARK: The regions

    /// The frame `index` of a scene, and the frames next to it.
    private func around(_ index: Int, of scene: Scene, extra: ((Int, Int) -> UInt8?)? = nil) -> (frame: CaptureFrame, near: [CaptureFrame]) {
        (PinnedScenes.frame(index, of: scene, extra: extra),
         [PinnedScenes.frame(index - 1, of: scene, extra: extra), PinnedScenes.frame(index + 1, of: scene, extra: extra)])
    }

    /// A frame with nothing in it: white, as the margin behind a panel is.
    private func blank() -> CaptureFrame {
        CaptureFrame(width: 480, height: 800, pixels: [UInt8](repeating: 255, count: 480 * 800 * 4))
    }

    private func accumulate(_ pairs: Int, scene: Scene = Scene(),
                            extra: ((Int, Int) -> UInt8?)? = nil) -> ScrollPinned.Accumulator {
        var accumulator = ScrollPinned.Accumulator()
        for index in 1...pairs { accumulator.add(PinnedScenes.pair(index, of: scene, extra: extra)) }
        return accumulator
    }

    /// One pair is a coincidence: it takes two to be a pinned element.
    @Test func aRegionNeedsTwoPairs() {
        let scene = Scene()
        var one = accumulate(1)
        let (frame1, near1) = around(1, of: scene)
        #expect(one.region(of: frame1, near: near1).isEmpty)
        var two = accumulate(2)
        let (frame2, near2) = around(2, of: scene)
        #expect(!two.region(of: frame2, near: near2).isEmpty)
    }

    /// The region is the card's box and five blocks round it (the frame is 60 by 100 blocks, the card 20 by 25 at
    /// its bottom right: the margin is cut by the edges there).
    @Test func theRegionIsTheBoxOfTheCardWithAMarginOfFiveBlocks() {
        var accumulator = accumulate(3)
        let (frame, near) = around(2, of: Scene())
        let region = accumulator.region(of: frame, near: near)
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

    /// The core of the region is the card itself: its box, not the margin round it.
    @Test func theCoreOfTheRegionIsTheCardWithoutItsMargin() {
        var accumulator = accumulate(3)
        let (frame, near) = around(2, of: Scene())
        let (region, core) = accumulator.regionAndCore(of: frame, near: near)
        let card = PinnedScenes.card
        let first = Int(card.minX) / block, last = Int(card.maxX) / block - 1
        let top = Int(card.minY) / block, bottom = Int(card.maxY) / block - 1
        #expect(core[first, top] && core[last, bottom])
        // It reaches `coreReach` blocks beyond the box of the card (a guide line, an indicator at its edge).
        let reach = ScrollPinned.coreReach
        #expect(core[first - reach, top] && core[first, top - reach])
        #expect(!core[first - reach - 1, top] && !core[first, top - reach - 1])
        // The card is 3 blocks from the right edge and 2 from the bottom one: closing the gaps of up to eight blocks
        // takes the shape to the edges, as it did for the region.
        #expect(core.count == (59 - (first - reach) + 1) * (99 - (top - reach) + 1))
        // The margin beyond is in the region and not in the core.
        #expect(region[first - 5, top] && !core[first - 5, top])
        #expect(region == accumulator.region(of: frame, near: near))
        // Before the evidence there is neither.
        var young = accumulate(1)
        let fromYoung = young.regionAndCore(of: frame, near: near)
        #expect(fromYoung.region.isEmpty && fromYoung.core.isEmpty)
    }

    /// Pinned elements are in most pairs. A card that is in two pairs out of five is one — the active item of a
    /// menu is in as many — and a frame that does not show it is not covered by it.
    @Test func aPieceNeedsTwoFifthsOfThePairsAndTheFrameNeedsToShowIt() {
        let withCard = PinnedScenes.pair(1, of: Scene())
        let without = PinnedScenes.pair(1, of: Scene(card: false))
        let (frame, near) = around(1, of: Scene())
        var accumulator = ScrollPinned.Accumulator()
        for pair in [withCard, without, without, without, without] { accumulator.add(pair) }
        // One of five: not stable.
        #expect(accumulator.region(of: frame, near: near).isEmpty)
        accumulator.add(withCard)
        // Two of six: not yet (the least is two, but two fifths of six is 2.4, three).
        #expect(accumulator.region(of: frame, near: near).isEmpty)
        var enough = ScrollPinned.Accumulator()
        for pair in [withCard, without, withCard, without, without] { enough.add(pair) }
        #expect(!enough.region(of: frame, near: near).isEmpty)
        // A frame that is white where the card would be shows none of it.
        #expect(enough.region(of: blank(), near: [blank()]).isEmpty)
    }

    /// A frame the page drew a pixel or two off its neighbours' still shows the element: what counts is that the
    /// blocks are alike, not that they are the same to the pixel.
    @Test func aFrameDrawnOffItsNeighboursStillShowsTheCard() {
        var accumulator = accumulate(4)
        let scene = Scene()
        let moved: (Int, Int) -> UInt8? = { y, x in
            PinnedScenes.card.contains(CGPoint(x: x, y: y)) ? SeamScenes.panelPixel(y + 1, x + 2) : nil
        }
        let frame = PinnedScenes.frame(2, of: scene, extra: moved)
        let near = [PinnedScenes.frame(1, of: scene), PinnedScenes.frame(3, of: scene)]
        #expect(!accumulator.region(of: frame, near: near).isEmpty)
    }

    /// A pinned bar across the whole width, joined to panels at the sides, makes a piece whose box is the whole
    /// frame. It is covered as it is, with the margin, not as the box: the page between the panels is not covered.
    @Test func aPieceThatIsMostOfTheFrameIsNotMadeABox() {
        let drawn: (Int, Int) -> UInt8? = { y, x in
            if (40..<96).contains(y) { return SeamScenes.panelPixel(y, x) }
            if x < 80 { return SeamScenes.panelPixel(y + 3_000, x) }
            return nil
        }
        let scene = Scene(card: false)
        var accumulator = accumulate(3, scene: scene, extra: drawn)
        let (frame, near) = around(2, of: scene, extra: drawn)
        let region = accumulator.region(of: frame, near: near)
        #expect(region[30, 8] && region[3, 60])
        #expect(!region[30, 60])
        // Such a piece has no margin to tell from itself: all it covers is the element's.
        let both = accumulator.regionAndCore(of: frame, near: near)
        #expect(both.core == both.region)
    }

    /// The lines of a menu that changed in the middle leave two pieces in the same columns, one over the other. They
    /// are one element, and the box covers what lies between them — when they are close enough.
    @Test func piecesInTheSameColumnsAreOneElementWhenTheyAreClose() {
        func region(gapRows: Int) -> PinnedGrid {
            let upper = 0..<120, lower = (120 + gapRows * 8)..<800
            let drawn: (Int, Int) -> UInt8? = { y, x in
                x < 96 && (upper.contains(y) || lower.contains(y)) ? SeamScenes.panelPixel(y, x) : nil
            }
            let scene = Scene(card: false)
            var accumulator = accumulate(3, scene: scene, extra: drawn)
            let (frame, near) = around(2, of: scene, extra: drawn)
            return accumulator.region(of: frame, near: near)
        }
        // Between them, 40 blocks down: covered. Far apart (more than `joinGap`): not.
        #expect(region(gapRows: 40)[5, 120 / 8 + 20])
        #expect(!region(gapRows: ScrollPinned.joinGap + 12)[5, 120 / 8 + 30])
    }

    // MARK: The element at the bottom of the frame

    /// The top of a card at the bottom of the frame, with its margin: the card's own top is 584 and the margin
    /// five blocks.
    @Test func theTopOfAnElementAtTheBottomIsWhereItsRegionBegins() {
        var accumulator = accumulate(3)
        let top = (Int(PinnedScenes.card.minY) / block - ScrollPinned.margin) * block
        #expect(accumulator.bottomAnchoredTop(rows: 100) == top)
        // Two of them: the higher one.
        let panel: (Int, Int) -> UInt8? = { y, x in x < 96 && y >= 400 ? SeamScenes.panelPixel(y + 3_000, x) : nil }
        var both = accumulate(3, extra: panel)
        #expect(both.bottomAnchoredTop(rows: 100) == (400 / block - ScrollPinned.margin) * block)
    }

    /// Not an element at the bottom: nothing yet, a panel along the whole side, a bar at the top, a card
    /// in the middle.
    @Test func whatIsNotAtTheBottomSetsNoTop() {
        var young = accumulate(1)
        #expect(young.bottomAnchoredTop(rows: 100) == nil)
        var side = accumulate(3, scene: Scene(card: false, panel: true))
        #expect(side.bottomAnchoredTop(rows: 100) == nil)
        let bar: (Int, Int) -> UInt8? = { y, x in y < 96 ? SeamScenes.panelPixel(y, x) : nil }
        var top = accumulate(3, scene: Scene(card: false), extra: bar)
        #expect(top.bottomAnchoredTop(rows: 100) == nil)
        var middle = accumulate(3, scene: Scene(cardRect: CGRect(x: 296, y: 300, width: 160, height: 100)))
        #expect(middle.bottomAnchoredTop(rows: 100) == nil)
        // Not a frame of the grid it has learnt.
        var other = accumulate(3)
        #expect(other.bottomAnchoredTop(rows: 50) == nil)
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

    /// The margin round an element is page. A block of it that no neighbour shows is left as the frame has it;
    /// only a block of the element itself is filled. A neighbour that shows the page serves both.
    @Test func aBlockOfTheMarginNoNeighbourShowsStaysAsTheFrameHasIt() {
        var scene = Scene(card: false)
        scene.page = { _, _ in 120 }
        // Noise over the whole region, the margin as well, in a field of 120.
        let drawn = PinnedScenes.frame(1, of: scene) { y, x in (200..<280).contains(y) && (200..<280).contains(x) ? SeamScenes.page(y, x) : nil }
        let covered = region(CGRect(x: 200, y: 200, width: 80, height: 80))
        let core = region(CGRect(x: 224, y: 224, width: 32, height: 32))
        let result = ScrollPinned.repairedSlice(frame: drawn, rows: 100..<400, region: covered, core: core, neighbours: [])
        #expect(result.repair.blocks == 100 && result.repair.filled == 16 && result.repair.kept == 84)
        #expect(result.repair.fromNeighbour == 0)
        // The core is the colour of the ring, a block of the margin is the frame's own noise.
        #expect(result.slice[240, 240 - 100, 0] == 120 && result.slice[228, 228 - 100, 1] == 120)
        #expect(result.slice[204, 204 - 100, 0] == drawn[204, 204, 0] && result.slice[270, 270 - 100, 0] == drawn[270, 270, 0])
        // With no core every block is the element's, as it was.
        let all = ScrollPinned.repairedSlice(frame: drawn, rows: 100..<400, region: covered, neighbours: [])
        #expect(all.repair.filled == 100 && all.repair.kept == 0)
        // A neighbour that shows the page serves the margin and the core alike.
        let free = PinnedGrid(columns: 60, rows: 100)
        let served = ScrollPinned.repairedSlice(frame: drawn, rows: 100..<400, region: covered, core: core,
                                                neighbours: [.init(frame: uniform(77), region: free, offset: 40)])
        #expect(served.repair.fromNeighbour == 100 && served.repair.kept == 0 && served.slice[204, 204 - 100, 0] == 77)
    }

    /// The last rows of a frame may show what the browser draws over the page, the address of a link: a neighbour
    /// gives nothing from them.
    @Test func aNeighbourGivesNothingFromItsLastRows() {
        var scene = Scene(card: false)
        scene.page = { _, _ in 120 }
        let drawn = PinnedScenes.frame(1, of: scene) { y, x in (200..<280).contains(y) && (200..<280).contains(x) ? SeamScenes.page(y, x) : nil }
        let covered = region(CGRect(x: 200, y: 200, width: 80, height: 80))
        let free = PinnedGrid(columns: 60, rows: 100)
        // The neighbour is 540 rows up: the block at row 200 is its row 740, and the one at 272 its 812: out of the frame.
        func repair(offset: Int) -> ScrollPinned.Repair {
            ScrollPinned.repairedSlice(frame: drawn, rows: 100..<400, region: covered,
                                       neighbours: [.init(frame: uniform(77), region: free, offset: offset)]).repair
        }
        // Up to 48 rows from the bottom a neighbour gives; closer to it, not.
        #expect(repair(offset: -540).fromNeighbour > 0)
        #expect(repair(offset: -570).fromNeighbour < repair(offset: -540).fromNeighbour)
        #expect(repair(offset: -700).fromNeighbour == 0)
    }

    @Test func aSliceWithNoRegionIsTheSliceOfTheFrame() {
        let frame = PinnedScenes.frame(1, of: Scene())
        let result = ScrollPinned.repairedSlice(frame: frame, rows: 100..<500, region: PinnedGrid(columns: 60, rows: 100),
                                                neighbours: [])
        #expect(result.repair == ScrollPinned.Repair())
        #expect(result.slice.pixels == Array(frame.pixels[(100 * 480 * 4)..<(500 * 480 * 4)]))
    }
}
