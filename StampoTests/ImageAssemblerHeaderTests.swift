import CoreGraphics
import Testing
@testable import Stampo

/// The header: what a site's window showed above the rows that scroll, laid once
/// above the image (`ImageAssembler.setHeader`). Frames are the 60 by 200 ones of
/// `SeamScenes`, 60 rows further on each time; the header is 40 rows of its own
/// pixels (0 to 70, which no page pixel is) across the same width.
@Suite struct ImageAssemblerHeaderTests {
    let scene = SeamScenes.Scene(states: [.absent, .absent, .absent])
    let headerRows = 40

    /// The header: plain `value` all over, or the panel's pixels.
    private func header(_ value: UInt8? = nil, axis: ScrollAxis = .vertical, rows: Int = 40) -> CaptureFrame {
        let across = SeamScenes.across
        let width = axis == .vertical ? across : rows, height = axis == .vertical ? rows : across
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let along = axis == .vertical ? y : x, cross = axis == .vertical ? x : y
                let pixel = value ?? SeamScenes.panelPixel(along, cross)
                let i = (y * width + x) * 4
                bytes[i] = pixel; bytes[i + 1] = pixel; bytes[i + 2] = pixel
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func assembler(axis: ScrollAxis = .vertical, maxLength: Int = 10_000) -> ImageAssembler {
        var assembler = ImageAssembler(axis: axis, maxLength: maxLength)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        return assembler
    }

    /// The image is the header and then the frames, with no seam in the header.
    @Test func theImageIsTheHeaderAndThenTheStrips() throws {
        var assembler = assembler()
        let taken = assembler.setHeader(header())
        #expect(taken)
        #expect(assembler.headerLength == headerRows)
        #expect(assembler.totalLength == SeamScenes.length + headerRows)
        try assembler.append(SeamScenes.frame(1, of: scene), movement: SeamScenes.movement)
        let length = headerRows + SeamScenes.length + SeamScenes.movement
        #expect(assembler.totalLength == length)
        #expect(assembler.lengthAfterAdding(SeamScenes.movement) == length + SeamScenes.movement)

        let image = try #require(CaptureFrame(image: assembler.makeImage()))
        #expect(image.height == length)
        // The header's own pixels, row for row.
        for row in 0..<headerRows {
            for column in 0..<SeamScenes.across where image[column, row, 0] != SeamScenes.panelPixel(row, column) {
                Issue.record("header row \(row) column \(column)")
                return
            }
        }
        // The page begins under it, at its own row 0.
        #expect(image[7, headerRows, 0] == SeamScenes.page(0, 7))
        #expect(image[7, length - 1, 0] == SeamScenes.page(SeamScenes.movement + SeamScenes.length - 1, 7))
    }

    /// The frames are laid as they are without it: the header changes where they
    /// begin, and nothing else.
    @Test func theStripsAreTheSameWithOrWithoutTheHeader() throws {
        var without = assembler()
        var with = assembler()
        with.setHeader(header())
        for index in 1..<3 {
            try without.append(SeamScenes.frame(index, of: scene), movement: SeamScenes.movement)
            try with.append(SeamScenes.frame(index, of: scene), movement: SeamScenes.movement)
        }
        #expect(without.strips.map(\.start) == with.strips.map(\.start))
        let plain = try #require(CaptureFrame(image: without.makeImage()))
        let capped = try #require(CaptureFrame(image: with.makeImage()))
        #expect(capped.height == plain.height + headerRows)
        for row in 0..<plain.height where capped[9, row + headerRows, 0] != plain[9, row, 0] {
            Issue.record("row \(row)")
            return
        }
    }

    /// Halved, the header is halved with the rest: half as long, half as wide,
    /// and what it held.
    @Test func inTheHalvedImageTheHeaderIsHalvedToo() throws {
        var assembler = assembler()
        assembler.setHeader(header(5))
        try assembler.append(SeamScenes.frame(1, of: scene), movement: SeamScenes.movement)
        assembler.shrinkToHalf()
        #expect(assembler.headerLength == headerRows / 2)
        #expect(assembler.header?.width == SeamScenes.across / 2)
        let strips = (SeamScenes.length + SeamScenes.movement) / 2
        #expect(assembler.totalLength == strips + headerRows / 2)
        #expect(assembler.lengthAfterAdding(SeamScenes.movement) == strips + SeamScenes.movement / 2 + headerRows / 2)

        // The next frame is halved as it comes, and the header stays as it was.
        try assembler.append(SeamScenes.frame(2, of: scene), movement: SeamScenes.movement)
        let total = (SeamScenes.length + 2 * SeamScenes.movement) / 2 + headerRows / 2
        #expect(assembler.totalLength == total)
        let image = try #require(CaptureFrame(image: assembler.makeImage()))
        #expect(image.height == total)
        #expect(image.width == SeamScenes.across / 2)
        for row in 0..<(headerRows / 2) where image[4, row, 0] != 5 {
            Issue.record("header row \(row): \(image[4, row, 0])")
            return
        }
        // The page under it is noise averaged, never the header's 5.
        #expect(image[4, headerRows / 2, 0] > 60, "\(image[4, headerRows / 2, 0])")
    }

    /// A header put on a halved image is halved to match.
    @Test func aHeaderPutOnAHalvedImageIsHalved() throws {
        var assembler = assembler()
        assembler.shrinkToHalf()
        let taken = assembler.setHeader(header(5))
        #expect(taken)
        #expect(assembler.headerLength == headerRows / 2)
        #expect(assembler.totalLength == SeamScenes.length / 2 + headerRows / 2)
    }

    /// Replacing the first frame (a section pinned to the viewport changed its
    /// stage) lays the frame over the first; the header is no part of that.
    @Test func replacingTheFirstFrameLeavesTheHeader() throws {
        var assembler = assembler()
        assembler.setHeader(header())
        let other = SeamScenes.frame(1, of: scene)
        try assembler.replaceLast(with: other)
        #expect(assembler.headerLength == headerRows)
        #expect(assembler.totalLength == SeamScenes.length + headerRows)
        let image = try #require(CaptureFrame(image: assembler.makeImage()))
        #expect(image.height == SeamScenes.length + headerRows)
        #expect(image[3, 0, 0] == SeamScenes.panelPixel(0, 3))
        #expect(image[3, headerRows, 0] == other[3, 0, 0])
    }

    /// The limit counts the header: an image of exactly the limit is made, one
    /// row more is not, and the next step is asked about with the header in.
    @Test func theLimitCountsTheHeader() throws {
        let length = headerRows + SeamScenes.length
        var exact = assembler(maxLength: length)
        exact.setHeader(header())
        #expect(exact.lengthAfterAdding(0) == length)
        _ = try exact.makeImage()
        #expect(exact.lengthAfterAdding(1) == length + 1)

        var tight = assembler(maxLength: length - 1)
        tight.setHeader(header())
        #expect(throws: FrameMatchError.self) { try tight.makeImage() }
        // Without the header the same limit is no trouble.
        _ = try assembler(maxLength: length - 1).makeImage()
    }

    @Test func aHeaderIsTakenOnceAfterTheFirstFrameAndOnlyIfItFits() {
        var empty = ImageAssembler(axis: .vertical)
        let taken = empty.setHeader(header())
        #expect(!taken)

        var assembler = assembler()
        // Not the frames' width.
        let narrow = CaptureFrame(width: 30, height: 40, pixels: [UInt8](repeating: 9, count: 30 * 40 * 4))
        let taken2 = assembler.setHeader(narrow)
        #expect(!taken2)
        #expect(assembler.header == nil)
        let taken3 = assembler.setHeader(CaptureFrame(width: SeamScenes.across, height: 0, pixels: []))
        #expect(!taken3)
        let taken4 = assembler.setHeader(header())
        #expect(taken4)
        let taken5 = assembler.setHeader(header(rows: 10))
        #expect(!taken5)
        #expect(assembler.headerLength == headerRows)
    }

    @Test func aResetAssemblerHasNoHeader() throws {
        var assembler = assembler()
        assembler.setHeader(header())
        assembler.reset()
        #expect(assembler.header == nil)
        #expect(assembler.headerLength == 0)
        assembler.begin(with: SeamScenes.frame(0, of: scene))
        #expect(assembler.totalLength == SeamScenes.length)
    }

    /// Along a horizontal scroll the header is the columns at the left.
    @Test func alongAHorizontalScrollTheHeaderIsAtTheLeft() throws {
        var horizontal = scene
        horizontal.axis = .horizontal
        var assembler = ImageAssembler(axis: .horizontal, maxLength: 10_000)
        assembler.begin(with: SeamScenes.frame(0, of: horizontal))
        let taken = assembler.setHeader(header(axis: .horizontal))
        #expect(taken)
        try assembler.append(SeamScenes.frame(1, of: horizontal), movement: SeamScenes.movement)
        let length = headerRows + SeamScenes.length + SeamScenes.movement
        let image = try #require(CaptureFrame(image: assembler.makeImage()))
        #expect(image.width == length)
        #expect(image.height == SeamScenes.across)
        #expect(image[3, 8, 0] == SeamScenes.panelPixel(3, 8))
        #expect(image[headerRows + 3, 8, 0] == SeamScenes.page(3, 8))
    }
}
