import Testing
@testable import Stampo

/// Columns of a page that its script moves a little faster and a little slower
/// than the rest — the use-case library of claude.com: Role +3.1 %, the card as
/// the page, Task −3.1 % — are each rigid and exact at their own offset. Tiles
/// whose one best fit is near the offset of the rest are neither for it nor
/// against it (`FrameMatcher.nearRange(of:)`).
@Suite struct ParallaxMatchTests {
    static let width = 500, height = 800

    /// A page of noise; the frame the viewport shows `shift` rows down, the
    /// columns each by their own shift. The left column is the first fifth of
    /// the width (a tile column), the right the last fifth, the centre the rest.
    private func frame(left: Int, centre: Int, right: Int) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: Self.width * Self.height * 4)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let shift = x < Self.width / 5 ? left : (x >= Self.width * 4 / 5 ? right : centre)
                let value = SeamScenes.page(y + shift, x)
                let i = (y * Self.width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: Self.width, height: Self.height, pixels: bytes)
    }

    private func match(_ shifts: (left: Int, centre: Int, right: Int)) throws -> FrameMatch {
        try FrameMatcher.match(previous: frame(left: 0, centre: 0, right: 0),
                               current: frame(left: shifts.left, centre: shifts.centre, right: shifts.right),
                               axis: .vertical, maximumOffset: 632)
    }

    private func evidence(_ shifts: (left: Int, centre: Int, right: Int), at offset: Int) -> FrameMatcher.StepEvidence {
        FrameMatcher.evidence(previous: frame(left: 0, centre: 0, right: 0),
                              current: frame(left: shifts.left, centre: shifts.centre, right: shifts.right),
                              axis: .vertical, offset: offset, searchLimit: 632)
    }

    @Test func theRangeIsFourPercentAndTwoPixelsAtTheLeast() {
        #expect(FrameMatcher.nearFraction == 0.04)
        #expect(FrameMatcher.nearRange(of: 640) == 26)
        #expect(FrameMatcher.nearRange(of: 320) == 13)
        #expect(FrameMatcher.nearRange(of: 160) == 6)
        #expect(FrameMatcher.nearRange(of: 40) == 2)
        #expect(FrameMatcher.nearRange(of: 10) == 2)
    }

    /// The columns at +3 % and −3 % of the centre's 320: matched at 320, the
    /// side columns' tiles counted as near.
    @Test func columnsThreePercentEitherWayDoNotStopTheMatchAtTheCentre() throws {
        let found = try match((left: 330, centre: 320, right: 310))
        #expect(found.offset == 320)
        #expect(found.near > 0, "near: \(found.near)")
    }

    /// The evidence of a step the matcher did not place: not contradicted.
    @Test func columnsThreePercentEitherWayDoNotContradictTheCentre() {
        let found = evidence((left: 330, centre: 320, right: 310), at: 320)
        #expect(!found.contradicted)
        #expect(found.against == 0)
        #expect(found.near > 0)
        #expect(found.consistent > 0)
    }

    /// Eight percent is a different line of a list, not parallax: tiles of both
    /// side columns know better, and the step is refused as before.
    @Test func columnsEightPercentEitherWayAreAgainstAsBefore() {
        let shifts = (left: 346, centre: 320, right: 294)
        #expect(throws: FrameMatchError.self) { _ = try match(shifts) }
        let found = evidence(shifts, at: 320)
        #expect(found.contradicted)
        #expect(found.against > 0)
        #expect(found.near == 0)
    }

    /// Tiles near the distance asked are neutral only beside a tile exact at it.
    /// All of them a little off, none exact — a picture growing with the scroll,
    /// 2026-10-11-115436 — and the distance is contradicted as it was.
    @Test func tilesNearAreAgainstWhenNoTileIsExact() {
        // Every column is 330 where 320 is asked: nothing agrees with 320.
        let shifts = (left: 330, centre: 330, right: 330)
        let found = evidence(shifts, at: 320)
        #expect(found.consistent == 0)
        #expect(found.near == 0)
        #expect(found.against > 0)
        #expect(found.contradicted)
        // The distance they all agree on is not contradicted.
        #expect(!evidence(shifts, at: 330).contradicted)
    }

    @Test func aStepWhoseColumnsAllAgreeHasNoNearTiles() throws {
        let found = try match((left: 320, centre: 320, right: 320))
        #expect(found.offset == 320)
        #expect(found.near == 0)
    }
}
