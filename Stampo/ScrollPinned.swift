import CoreGraphics
import Foundation

/// A grid of blocks over a frame, `ScrollPinned.block` pixels square, one flag to a block: which of them
/// the pinned elements of a page — a card over its corner, a panel at its side — are drawn on.
nonisolated struct PinnedGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int
    var cells: [Bool]

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        cells = [Bool](repeating: false, count: columns * rows)
    }

    /// Outside the grid nothing is set, and nothing can be set.
    subscript(column: Int, row: Int) -> Bool {
        get { column >= 0 && column < columns && row >= 0 && row < rows && cells[row * columns + column] }
        set { if column >= 0 && column < columns && row >= 0 && row < rows { cells[row * columns + column] = newValue } }
    }

    var count: Int { cells.reduce(0) { $0 + ($1 ? 1 : 0) } }
    var isEmpty: Bool { !cells.contains(true) }

    func union(_ other: PinnedGrid) -> PinnedGrid {
        var grid = self
        for index in 0..<min(cells.count, other.cells.count) where other.cells[index] { grid.cells[index] = true }
        return grid
    }

    /// The flags of the cells in the window `[column − n, column + n] × [row − n, row + n]`, summed, for every
    /// cell, from an integral image: the cost is the size of the grid, not of the window.
    private func windowSums(_ n: Int, of flag: (Bool) -> Bool) -> [Int32] {
        let width = columns + 1
        var integral = [Int32](repeating: 0, count: width * (rows + 1))
        for row in 0..<rows {
            var line: Int32 = 0
            for column in 0..<columns {
                if flag(cells[row * columns + column]) { line += 1 }
                integral[(row + 1) * width + column + 1] = integral[row * width + column + 1] + line
            }
        }
        var sums = [Int32](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let r0 = max(0, row - n), r1 = min(rows, row + n + 1)
            for column in 0..<columns {
                let c0 = max(0, column - n), c1 = min(columns, column + n + 1)
                sums[row * columns + column] = integral[r1 * width + c1] - integral[r0 * width + c1]
                    - integral[r1 * width + c0] + integral[r0 * width + c0]
            }
        }
        return sums
    }

    /// Every cell within `n` of a set one.
    func dilated(by n: Int) -> PinnedGrid {
        guard n > 0, !cells.isEmpty else { return self }
        var grid = PinnedGrid(columns: columns, rows: rows)
        let sums = windowSums(n) { $0 }
        for index in 0..<cells.count where sums[index] > 0 { grid.cells[index] = true }
        return grid
    }

    /// The cells whose whole window of `n` is set; what lies outside the grid counts as set.
    func eroded(by n: Int) -> PinnedGrid {
        guard n > 0, !cells.isEmpty else { return self }
        var grid = PinnedGrid(columns: columns, rows: rows)
        let sums = windowSums(n) { !$0 }
        for index in 0..<cells.count where sums[index] == 0 { grid.cells[index] = true }
        return grid
    }

    /// Gaps of up to twice `n` cells between the cells of one element are filled.
    func closed(by n: Int) -> PinnedGrid { dilated(by: n).eroded(by: n) }

    /// The connected pieces (eight neighbours) of the set cells, as the indices of their cells.
    func pieces() -> [[Int]] {
        var seen = [Bool](repeating: false, count: cells.count)
        var out: [[Int]] = []
        for start in 0..<cells.count where cells[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var piece: [Int] = []
            while let index = stack.popLast() {
                piece.append(index)
                let column = index % columns, row = index / columns
                for dr in -1...1 {
                    for dc in -1...1 {
                        let c = column + dc, r = row + dr
                        guard c >= 0, c < columns, r >= 0, r < rows else { continue }
                        let next = r * columns + c
                        if cells[next], !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            out.append(piece)
        }
        return out
    }
}

/// Something handed to the workers of a parallel loop that each of them uses on its own part: the cells of
/// an output, the rows of a slice. Nothing in it is shared in a way that needs a lock.
nonisolated private struct Shared<Value>: @unchecked Sendable {
    let value: Value
}

/// What a page pins to the viewport — a card over a corner, a panel at the side — is in every frame of a scrolling
/// capture, where the page's own content passes by. Laid down as the frames come, it is in the image once for every
/// seam: a strip of the card at each, a column of the panel the whole way. This finds those blocks and puts the page
/// back under them, from the frame before or the one after, where one shows it.
///
/// The thresholds say what a pinned element is, not which site it is on: it is drawn the same in the frames of a pair
/// although the page moved between them, it has something in it to compare, and it is there in most pairs.
nonisolated enum ScrollPinned {
    /// Pixels to a block along each side.
    static let block = 8

    /// Two blocks are "the same place" when they differ, per channel out of 255, by no more than this: text and
    /// edges are drawn the same each time, a soft shadow less so.
    static let sameTolerance = 3.0
    /// A block has something in it when the brightness of its pixels spreads by at least this much (standard
    /// deviation, out of 255). An empty background is the same in every frame and says nothing.
    static let contentSpread = 6.0
    /// When the shift between the frames is known, a block that the moved page also fits (the page's own, equal
    /// by chance, such as a repeating pattern) differs from the earlier frame by no more than this at the place the
    /// shift gives it, and is not pinned.
    static let movedTolerance = 6.0
    /// What a page draws as a vertical line — the border of a box — is the same in the frames of a pair whatever the
    /// page did, and is no part of a pinned element. A block that is the same as itself `verticalProbe` rows lower in
    /// its own frame, to within `verticalChange` per channel, is not taken: the text and icons of a pinned element are
    /// not the same a few rows down.
    static let verticalProbe = 4
    static let verticalChange = 4.0

    /// Pinned elements stand in most pairs of the capture, page content in few: a block is taken as pinned when it
    /// is found in this share of the pairs seen so far, and in at least `minimumPairs` of them. Under the full share
    /// the active item of a menu, which changes as the page goes by, would fall out of its panel.
    static let presenceShare = 0.4
    static let minimumPairs = 2
    /// Whether a frame shows an element is read off the frame itself, not off its pairs, so that a frame that the
    /// page drew a pixel or two off its neighbours', or that a fade has not finished, still shows it: a block of the
    /// element stands in the frame when it has something in it and its mean colour is within this much (per channel,
    /// out of 255) of the same block in a frame next to it. At most `presenceSample` blocks of an element are looked at.
    static let presenceTolerance = 16.0
    static let presenceSample = 64
    /// Gaps of up to twice this many blocks between the blocks of one element are bridged — the lines of a menu
    /// are one panel — and a piece of fewer than `minimumBlocks` pinned blocks is too little to be an element.
    static let closing = 4
    static let minimumBlocks = 20
    /// An element is the box round its piece, so that a flat inside — a card's white — is covered, with `margin`
    /// blocks to spare for shadows and highlights that run to its edge. A box that is more than this share of the
    /// frame would join a header to the panels at the sides (MDN's pinned bar and its menus): such a piece is taken
    /// as it is, with the margin.
    static let margin = 5
    /// The element itself reaches this many blocks beyond the box of its stable blocks: a guide line or an indicator
    /// at its edge is not a stable block (a vertical line is not pinned content) and is the element's.
    static let coreReach = 2
    static let compactShare = 0.35
    /// The last rows of a frame may show what the browser draws over the page — the address of the link under the
    /// pointer — and are not the page's: a neighbour gives nothing from them.
    static let edgeRows = 48
    /// Pieces stood one over the other in the same columns, with up to `joinGap` blocks between them, are one element
    /// — a menu whose lines changed in the middle — when the box round both is still compact. They are the same
    /// columns when the narrower is `joinOverlap` inside the wider.
    static let joinGap = 48
    static let joinOverlap = 0.6
    /// A slice that no element covers waits for the frames to come, while the accumulator has seen fewer pairs than
    /// this: an element that sticks to the viewport only after the first scroll has shown itself in too few pairs.
    static let waitingPairs = 6

    // MARK: Finding the blocks

    /// The blocks of `current` that are the same as those of `previous` at the same place, have something in
    /// them, and — when `shift`, how far the page moved, is known — are not what the moved page puts there.
    /// Nil when the frames differ in size.
    static func pinnedBlocks(previous: CaptureFrame, current: CaptureFrame, shift: Int?) -> PinnedGrid? {
        guard previous.width == current.width, previous.height == current.height else { return nil }
        let columns = current.width / block, rows = current.height / block
        guard columns > 0, rows > 0 else { return nil }
        var flags = [UInt8](repeating: 0, count: columns * rows)
        let width = current.width, height = current.height
        let area = block * block
        // The most that a block may differ from the earlier one, summed over its pixels and channels.
        let sameLimit = Int(sameTolerance * Double(area * 3))
        let movedLimit = Int(movedTolerance * Double(area * 3))
        let spreadNeeded = contentSpread
        let probe = verticalProbe
        let probeLimit = Int(verticalChange * Double(area * 3))
        flags.withUnsafeMutableBufferPointer { out in
            let outBox = Shared(value: out.baseAddress!)
            previous.pixels.withUnsafeBufferPointer { beforeBuffer in
                current.pixels.withUnsafeBufferPointer { nowBuffer in
                    let beforeBox = Shared(value: beforeBuffer.baseAddress!), nowBox = Shared(value: nowBuffer.baseAddress!)
                    // A row of blocks to a worker: they write to their own cells of the output.
                    DispatchQueue.concurrentPerform(iterations: rows) { row in
                        let output = outBox.value, before = beforeBox.value, now = nowBox.value
                        for column in 0..<columns {
                            // Most blocks are the page's, which moved, and are far from the earlier frame in the
                            // first line of the block: they are left at once.
                            var same = 0
                            var far = false
                            for y in 0..<block {
                                let line = ((row * block + y) * width + column * block) * 4
                                for x in 0..<block {
                                    let i = line + x * 4
                                    var d = Int(now[i]) - Int(before[i]); same += d < 0 ? -d : d
                                    d = Int(now[i + 1]) - Int(before[i + 1]); same += d < 0 ? -d : d
                                    d = Int(now[i + 2]) - Int(before[i + 2]); same += d < 0 ? -d : d
                                }
                                if same > sameLimit { far = true; break }
                            }
                            if far { continue }
                            // It has something in it: the brightness of its pixels spreads.
                            var sum = 0, squares = 0
                            for y in 0..<block {
                                let line = ((row * block + y) * width + column * block) * 4
                                for x in 0..<block {
                                    let i = line + x * 4
                                    let brightness = Int(now[i]) + Int(now[i + 1]) + Int(now[i + 2])
                                    sum += brightness
                                    squares += brightness * brightness
                                }
                            }
                            let mean = Double(sum) / Double(area) / 3
                            let spread = max(0, Double(squares) / Double(area) / 9 - mean * mean).squareRoot()
                            guard spread >= spreadNeeded else { continue }
                            // It changes down the frame: a vertical line does not.
                            let probeStep = row * block + block + probe <= height ? probe : -probe
                            var probed = 0
                            for y in 0..<block {
                                let line = ((row * block + y) * width + column * block) * 4
                                let other = ((row * block + y + probeStep) * width + column * block) * 4
                                for x in 0..<block {
                                    let i = line + x * 4, j = other + x * 4
                                    var d = Int(now[i]) - Int(now[j]); probed += d < 0 ? -d : d
                                    d = Int(now[i + 1]) - Int(now[j + 1]); probed += d < 0 ? -d : d
                                    d = Int(now[i + 2]) - Int(now[j + 2]); probed += d < 0 ? -d : d
                                }
                            }
                            guard probed >= probeLimit else { continue }
                            if let shift {
                                let top = row * block + shift
                                if top + block <= height {
                                    var moved = 0
                                    var different = false
                                    for y in 0..<block {
                                        let lineNow = ((row * block + y) * width + column * block) * 4
                                        let lineBefore = ((top + y) * width + column * block) * 4
                                        for x in 0..<block {
                                            let i = lineNow + x * 4, j = lineBefore + x * 4
                                            var d = Int(now[i]) - Int(before[j]); moved += d < 0 ? -d : d
                                            d = Int(now[i + 1]) - Int(before[j + 1]); moved += d < 0 ? -d : d
                                            d = Int(now[i + 2]) - Int(before[j + 2]); moved += d < 0 ? -d : d
                                        }
                                        if moved > movedLimit { different = true; break }
                                    }
                                    if !different { continue }
                                }
                            }
                            output[row * columns + column] = 1
                        }
                    }
                }
            }
        }
        var grid = PinnedGrid(columns: columns, rows: rows)
        for index in 0..<flags.count where flags[index] != 0 { grid.cells[index] = true }
        return grid
    }

    // MARK: The regions of a capture

    /// The pairs of a capture seen so far, and in how many of them each block was pinned.
    struct Accumulator: Sendable {
        private(set) var pairs = 0
        private var counts: [Int32] = []
        private var columns = 0, rows = 0
        /// The pieces made from the stable blocks, kept while those do not change: they settle after a few pairs.
        private var cachedStable: PinnedGrid?
        private var cachedPieces: [Piece] = []
        /// The number of pairs the cached pieces were last checked for, so that the three regions asked for with the
        /// same pairs share the work.
        private var checkedPairs = -1

        private struct Piece {
            /// The cells the element covers: its box with the margin, or its closed shape with the margin.
            var cover: PinnedGrid
            /// The cells of the element itself, without the margin: its box when it is one card; all it covers when it
            /// is a bar joined to panels.
            var core: PinnedGrid
            /// The stable blocks it was made from.
            var stable: [Int]
        }

        mutating func add(_ pair: PinnedGrid) {
            if counts.isEmpty {
                columns = pair.columns; rows = pair.rows
                counts = [Int32](repeating: 0, count: columns * rows)
            }
            guard pair.columns == columns, pair.rows == rows else { return }
            pairs += 1
            for index in 0..<pair.cells.count where pair.cells[index] { counts[index] += 1 }
        }

        /// The pieces of the stable blocks of the pairs seen so far, made again only when the stable blocks change.
        private mutating func refresh() {
            guard checkedPairs != pairs else { return }
            let need = Int32(max(ScrollPinned.minimumPairs, Int((Double(pairs) * ScrollPinned.presenceShare).rounded(.up))))
            var stable = PinnedGrid(columns: columns, rows: rows)
            for index in 0..<counts.count where counts[index] >= need { stable.cells[index] = true }
            if stable != cachedStable {
                cachedPieces = Self.pieces(of: stable)
                cachedStable = stable
            }
            checkedPairs = pairs
        }

        /// The cells that pinned elements cover in `frame`: the pieces of the stable blocks that the frame shows at
        /// least two fifths of, a block of a piece being shown when the frame has something in it there and it is
        /// the same, to within `presenceTolerance`, in one of `neighbours` (the frames next to it in the capture).
        /// Empty before `minimumPairs` pairs have been seen.
        mutating func region(of frame: CaptureFrame, near neighbours: [CaptureFrame]) -> PinnedGrid {
            regionAndCore(of: frame, near: neighbours).region
        }

        /// The region (what the elements cover, with their margin) and its core: the cells of the elements
        /// themselves. The margin is page that the frame shows beside an element.
        mutating func regionAndCore(of frame: CaptureFrame, near neighbours: [CaptureFrame]) -> (region: PinnedGrid, core: PinnedGrid) {
            let block = ScrollPinned.block
            var region = PinnedGrid(columns: frame.width / block, rows: frame.height / block)
            var core = region
            guard pairs >= ScrollPinned.minimumPairs, region.columns == columns, region.rows == rows else { return (region, core) }
            refresh()
            guard !cachedPieces.isEmpty else { return (region, core) }
            let near = neighbours.filter { $0.width == frame.width && $0.height == frame.height }
            let width = frame.width
            let limit = Int(ScrollPinned.presenceTolerance * Double(block * block * 3))
            let sampleSize = ScrollPinned.presenceSample
            frame.pixels.withUnsafeBufferPointer { own in
                ScrollPinned.withPixels(of: near) { others in
                    for piece in cachedPieces {
                        let step = max(1, piece.stable.count / sampleSize)
                        var seen = 0, have = 0
                        var at = 0
                        while at < piece.stable.count {
                            let cell = piece.stable[at]
                            at += step
                            seen += 1
                            let x0 = (cell % columns) * block, y0 = (cell / columns) * block
                            guard let mine = ScrollPinned.blockSums(own, width: width, x: x0, y: y0),
                                  mine.spread >= ScrollPinned.contentSpread else { continue }
                            for other in others {
                                let theirs = ScrollPinned.blockSums(UnsafeBufferPointer(start: other, count: own.count),
                                                                    width: width, x: x0, y: y0)
                                if let theirs, abs(mine.red - theirs.red) + abs(mine.green - theirs.green)
                                    + abs(mine.blue - theirs.blue) <= limit {
                                    have += 1
                                    break
                                }
                            }
                        }
                        guard Double(have) >= ScrollPinned.presenceShare * Double(seen) else { continue }
                        region = region.union(piece.cover)
                        core = core.union(piece.core)
                    }
                }
            }
            return (region, core)
        }

        private static func pieces(of stable: PinnedGrid) -> [Piece] {
            guard !stable.isEmpty else { return [] }
            let shape = stable.closed(by: ScrollPinned.closing)
            // What each element is made of, and the box round it.
            struct Candidate {
                var cells: [Int]
                var inside: [Int]
                var minColumn: Int, maxColumn: Int, minRow: Int, maxRow: Int
            }
            var candidates: [Candidate] = []
            for cells in shape.pieces() {
                let inside = cells.filter { stable.cells[$0] }
                guard inside.count >= ScrollPinned.minimumBlocks else { continue }
                var candidate = Candidate(cells: cells, inside: inside, minColumn: stable.columns, maxColumn: 0,
                                          minRow: stable.rows, maxRow: 0)
                for index in cells {
                    let column = index % stable.columns, row = index / stable.columns
                    candidate.minColumn = min(candidate.minColumn, column); candidate.maxColumn = max(candidate.maxColumn, column)
                    candidate.minRow = min(candidate.minRow, row); candidate.maxRow = max(candidate.maxRow, row)
                }
                candidates.append(candidate)
            }
            let frameArea = Double(stable.columns * stable.rows)
            func boxArea(_ c: Candidate) -> Double { Double((c.maxColumn - c.minColumn + 1) * (c.maxRow - c.minRow + 1)) }
            // Pieces in the same columns, one over the other and close, are one.
            var merged = true
            while merged {
                merged = false
                search: for i in 0..<candidates.count {
                    for j in (i + 1)..<max(i + 1, candidates.count) {
                        let a = candidates[i], b = candidates[j]
                        let overlap = min(a.maxColumn, b.maxColumn) - max(a.minColumn, b.minColumn) + 1
                        let narrower = min(a.maxColumn - a.minColumn, b.maxColumn - b.minColumn) + 1
                        guard overlap > 0, Double(overlap) >= ScrollPinned.joinOverlap * Double(narrower) else { continue }
                        let gap = max(a.minRow, b.minRow) - min(a.maxRow, b.maxRow) - 1
                        guard gap <= ScrollPinned.joinGap else { continue }
                        var both = a
                        both.cells += b.cells; both.inside += b.inside
                        both.minColumn = min(a.minColumn, b.minColumn); both.maxColumn = max(a.maxColumn, b.maxColumn)
                        both.minRow = min(a.minRow, b.minRow); both.maxRow = max(a.maxRow, b.maxRow)
                        guard boxArea(both) <= ScrollPinned.compactShare * frameArea else { continue }
                        candidates[i] = both
                        candidates.remove(at: j)
                        merged = true
                        break search
                    }
                }
            }
            var out: [Piece] = []
            for candidate in candidates {
                var cover: PinnedGrid
                var core: PinnedGrid
                if boxArea(candidate) <= ScrollPinned.compactShare * frameArea {
                    cover = PinnedGrid(columns: stable.columns, rows: stable.rows)
                    core = PinnedGrid(columns: stable.columns, rows: stable.rows)
                    for row in max(0, candidate.minRow - ScrollPinned.margin)...min(stable.rows - 1, candidate.maxRow + ScrollPinned.margin) {
                        for column in max(0, candidate.minColumn - ScrollPinned.margin)...min(stable.columns - 1, candidate.maxColumn + ScrollPinned.margin) {
                            cover[column, row] = true
                        }
                    }
                    for row in max(0, candidate.minRow - ScrollPinned.coreReach)...min(stable.rows - 1, candidate.maxRow + ScrollPinned.coreReach) {
                        for column in max(0, candidate.minColumn - ScrollPinned.coreReach)...min(stable.columns - 1, candidate.maxColumn + ScrollPinned.coreReach) {
                            core[column, row] = true
                        }
                    }
                } else {
                    // A bar joined to panels is not one card on a page: its shape does not say which of the blocks
                    // round it are the page's (the guide lines of a menu are not stable blocks), so all it covers
                    // is the element's.
                    var shape = PinnedGrid(columns: stable.columns, rows: stable.rows)
                    for index in candidate.cells { shape.cells[index] = true }
                    cover = shape.dilated(by: ScrollPinned.margin)
                    core = cover
                }
                out.append(Piece(cover: cover, core: core, stable: candidate.inside))
            }
            return out
        }
    }

    // MARK: Putting the page back

    /// A frame next to the one being repaired, as far as the place of the page goes: `offset` is how far its top
    /// stands along the scroll from the repaired frame's (positive for the frame that follows) and `region` what
    /// its own pinned elements cover: it gives nothing of the page from there.
    struct Neighbour: Sendable {
        let frame: CaptureFrame
        let region: PinnedGrid
        let offset: Int
    }

    struct Repair: Equatable, Sendable {
        /// Blocks of the slice that a pinned element covered.
        var blocks = 0
        /// Of them, taken from a neighbouring frame, filled with the colour round the element (the blocks of the
        /// element itself that no neighbour shows the page behind), and left as the frame has them (the margin
        /// round the element, which is page).
        var fromNeighbour = 0
        var filled = 0
        var kept = 0
        /// How long the repair took.
        var milliseconds = 0.0

        mutating func add(_ other: Repair) {
            blocks += other.blocks
            fromNeighbour += other.fromNeighbour
            filled += other.filled
            kept += other.kept
            milliseconds += other.milliseconds
        }

        static func == (lhs: Repair, rhs: Repair) -> Bool {
            lhs.blocks == rhs.blocks && lhs.fromNeighbour == rhs.fromNeighbour && lhs.filled == rhs.filled
                && lhs.kept == rhs.kept
        }
    }

    /// Rows `rows` of `frame` — the slice of it that goes into the image — with the blocks that `region` covers
    /// replaced: by the blocks of the first of `neighbours` that shows that place of the page where it is not
    /// itself covered, and else, for a block of the element itself (`core`), by the median colour of a ring one
    /// block wide round the element. A block of the margin that no neighbour shows is left as the frame has it:
    /// it is page. With no `core` every block is the element's. The slice is a frame of its own, the width of
    /// `frame`.
    static func repairedSlice(frame: CaptureFrame, rows: Range<Int>, region: PinnedGrid, core: PinnedGrid? = nil,
                              neighbours: [Neighbour]) -> (slice: CaptureFrame, repair: Repair) {
        let started = ContinuousClock.now
        let width = frame.width, height = frame.height
        var report = Repair()
        let low = max(0, rows.lowerBound), high = min(height, rows.upperBound)
        guard high > low else { return (frame, report) }
        var pixels = Array(frame.pixels[(low * width * 4)..<(high * width * 4)])

        // Per row of blocks: how many there were, how many came from a neighbour, how many were filled, how many
        // were left as they were.
        let rowsOfBlocks = region.rows
        let tally = UnsafeMutablePointer<Int>.allocate(capacity: rowsOfBlocks * 4)
        tally.initialize(repeating: 0, count: rowsOfBlocks * 4)
        defer { tally.deallocate() }
        let tallyBox = Shared(value: tally)
        let columns = region.columns
        // The colour round the element a block is a part of, looked for the first time a block has no neighbour to
        // give it the page: a card that the next frame shows the page under never needs one.
        let colourBox = Shared(value: RingColours(region: region, frame: frame))
        pixels.withUnsafeMutableBufferPointer { targetBuffer in
            let targetBox = Shared(value: targetBuffer.baseAddress!)
            withPixels(of: neighbours.map { $0.frame }) { pointers in
                let sourcesBox = Shared(value: pointers)
                // A row of blocks to a worker: its blocks are in rows of the slice of its own.
                DispatchQueue.concurrentPerform(iterations: rowsOfBlocks) { row in
                    let tally = tallyBox.value, target = targetBox.value, sources = sourcesBox.value
                    let from = max(low, row * block), to = min(high, (row + 1) * block)
                    guard to > from else { return }
                    for column in 0..<columns where region[column, row] {
                        tally[row * 4] += 1
                        let x0 = column * block
                        guard x0 + block <= width else { continue }
                        var source: (Int, Int)?
                        for (index, neighbour) in neighbours.enumerated() {
                            // This place of the page, in the neighbour's frame.
                            let top = row * block - neighbour.offset
                            guard top >= 0, top + block <= height - edgeRows else { continue }
                            if !neighbour.region[column, top / block] && !neighbour.region[column, (top + block - 1) / block] {
                                source = (index, top)
                                break
                            }
                        }
                        if let (index, top) = source {
                            tally[row * 4 + 1] += 1
                            for y in from..<to {
                                let t = ((y - low) * width + x0) * 4
                                let o = ((top + y - row * block) * width + x0) * 4
                                (target + t).update(from: sources[index] + o, count: block * 4)
                            }
                        } else if let core, !core[column, row] {
                            // The margin round the element: the page, as the frame shows it.
                            tally[row * 4 + 3] += 1
                        } else if let colour = colourBox.value.colour(atCell: row * columns + column) {
                            tally[row * 4 + 2] += 1
                            for y in from..<to {
                                var t = ((y - low) * width + x0) * 4
                                for _ in 0..<block {
                                    target[t] = colour.0; target[t + 1] = colour.1; target[t + 2] = colour.2; target[t + 3] = 255
                                    t += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        for row in 0..<rowsOfBlocks {
            report.blocks += tally[row * 4]
            report.fromNeighbour += tally[row * 4 + 1]
            report.filled += tally[row * 4 + 2]
            report.kept += tally[row * 4 + 3]
        }
        let elapsed = started.duration(to: .now)
        report.milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return (CaptureFrame(width: width, height: high - low, pixels: pixels, colorSpace: frame.colorSpace), report)
    }

    /// The colour round each piece of a region, worked out when first asked for, by whichever worker asks.
    private final class RingColours {
        private let region: PinnedGrid
        private let frame: CaptureFrame
        private let lock = NSLock()
        private var pieces: [[Int]]?
        private var pieceOf: [Int] = []
        private var colours: [Int: (UInt8, UInt8, UInt8)?] = [:]

        init(region: PinnedGrid, frame: CaptureFrame) {
            self.region = region
            self.frame = frame
        }

        /// The colour for the block at `cell`, nil if it is part of no piece or there is no ring to look at.
        func colour(atCell cell: Int) -> (UInt8, UInt8, UInt8)? {
            lock.lock()
            defer { lock.unlock() }
            if pieces == nil {
                let found = region.pieces()
                pieceOf = [Int](repeating: -1, count: region.cells.count)
                for (id, cells) in found.enumerated() { for index in cells { pieceOf[index] = id } }
                pieces = found
            }
            let id = pieceOf[cell]
            guard id >= 0, let pieces else { return nil }
            if let known = colours[id] { return known }
            let colour = ScrollPinned.ringColour(of: pieces[id], region: region, frame: frame)
            colours[id] = .some(colour)
            return colour
        }
    }

    /// The median colour, per channel, of the ring one block wide round a piece of the region and outside the
    /// whole of it; nil when there is no ring to look at.
    fileprivate static func ringColour(of cells: [Int], region: PinnedGrid, frame: CaptureFrame) -> (UInt8, UInt8, UInt8)? {
        var element = PinnedGrid(columns: region.columns, rows: region.rows)
        for index in cells { element.cells[index] = true }
        let around = element.dilated(by: 1)
        var bins = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var samples = 0
        let width = frame.width
        for index in 0..<around.cells.count where around.cells[index] && !region.cells[index] {
            let column = index % region.columns, row = index / region.columns
            for y in stride(from: 0, to: block, by: 2) {
                for x in stride(from: 0, to: block, by: 2) {
                    let at = ((row * block + y) * width + column * block + x) * 4
                    guard at + 2 < frame.pixels.count else { continue }
                    bins[0][Int(frame.pixels[at])] += 1
                    bins[1][Int(frame.pixels[at + 1])] += 1
                    bins[2][Int(frame.pixels[at + 2])] += 1
                    samples += 1
                }
            }
        }
        guard samples > 0 else { return nil }
        func median(_ bin: [Int]) -> UInt8 {
            var seen = 0
            for value in 0..<256 { seen += bin[value]; if seen * 2 >= samples { return UInt8(value) } }
            return 255
        }
        return (median(bins[0]), median(bins[1]), median(bins[2]))
    }

    /// The sums of each channel over the block of 8 × 8 pixels at (`x`, `y`) of a frame `width` wide, and the spread of
    /// the brightness of its pixels (standard deviation, out of 255); nil if the block is not in the pixels.
    fileprivate static func blockSums(_ pixels: UnsafeBufferPointer<UInt8>, width: Int, x: Int, y: Int)
        -> (red: Int, green: Int, blue: Int, spread: Double)? {
        guard x >= 0, y >= 0, x + block <= width, ((y + block) * width) * 4 <= pixels.count else { return nil }
        var red = 0, green = 0, blue = 0, squares = 0
        for row in 0..<block {
            var i = ((y + row) * width + x) * 4
            for _ in 0..<block {
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                red += r; green += g; blue += b
                let brightness = r + g + b
                squares += brightness * brightness
                i += 4
            }
        }
        let area = Double(block * block)
        let mean = (Double(red + green + blue)) / area / 3
        let spread = max(0, Double(squares) / area / 9 - mean * mean).squareRoot()
        return (red, green, blue, spread)
    }

    /// The pixels of each of `frames`, as pointers valid inside `body`.
    fileprivate static func withPixels(of frames: [CaptureFrame], _ body: ([UnsafePointer<UInt8>]) -> Void) {
        func go(_ index: Int, _ pointers: [UnsafePointer<UInt8>]) {
            guard index < frames.count else { body(pointers); return }
            frames[index].pixels.withUnsafeBufferPointer { buffer in
                go(index + 1, pointers + [buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!])
            }
        }
        go(0, [])
    }
}
