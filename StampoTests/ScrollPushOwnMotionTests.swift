import Testing
@testable import Stampo

/// A push at the end of a page that changes the frame only where the frame changes by itself — an animated WebP in
/// the preview column of Finder (2026-10-14-234809, 2026-10-15-001011) — has changed nothing, and a section's stage
/// has (`ScrollPush.changedBesidesOwnMotion`, `StationaryFrame`).
@Suite struct ScrollPushOwnMotionTests {
    private let tiles = ScrollStillness.grid * ScrollStillness.grid

    /// The differences of the 64 tiles: `value` in each of `tiles`, nothing in the rest.
    private func differences(_ value: Double, in set: Set<Int>) -> [Double] {
        (0..<tiles).map { set.contains($0) ? value : 0 }
    }

    /// A frame of 640 × 640 pixels, tiles of 80 × 80.
    private func frame(grey: UInt8 = 100) -> CaptureFrame {
        CaptureFrame(width: 640, height: 640, pixels: [UInt8](repeating: grey, count: 640 * 640 * 4))
    }

    /// `source` with the tiles brightened by 5 levels per channel (≈ 0.0196 of 255).
    private func playing(_ source: CaptureFrame, tiles set: Set<Int>) -> CaptureFrame {
        var pixels = source.pixels
        for tile in set {
            let row = tile / ScrollStillness.grid, column = tile % ScrollStillness.grid
            for y in (row * 80)..<((row + 1) * 80) {
                for x in (column * 80)..<((column + 1) * 80) {
                    let i = (y * 640 + x) * 4
                    for channel in 0..<3 { pixels[i + channel] = UInt8(min(255, Int(pixels[i + channel]) + 5)) }
                }
            }
        }
        return CaptureFrame(width: 640, height: 640, pixels: pixels)
    }

    // MARK: changedBesidesOwnMotion

    /// The WebP of 234809: the tiles 15 and 23 play by themselves; the push changes them and nothing else.
    @Test func aPushThatChangesOnlyTheTilesThatPlayByThemselvesChangedNothing() {
        let motion: Set<Int> = [15, 23]
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0.04, in: motion), ownMotion: motion) == false)
        // The same with the tiles of 001011, and a push that changed a part of them only.
        let four: Set<Int> = [14, 15, 22, 23]
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0.05, in: [15, 22]), ownMotion: four) == false)
    }

    /// A section's stage changes more: the heading, the mark of the hour, the colour of a card.
    @Test func aPushThatChangesTheFrameBesidesTheOwnMotionChangedIt() {
        let motion: Set<Int> = [15, 23]
        let stage = differences(0.1, in: motion.union(Set(24..<42)))
        #expect(ScrollPush.changedBesidesOwnMotion(push: stage, ownMotion: motion) == true)
        // One tile is enough, at the threshold of stillness.
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(ScrollStillness.stillBelow, in: [3]),
                                                   ownMotion: motion) == true)
    }

    @Test func aTileJustUnderTheThresholdAloneIsNotAChange() {
        let motion: Set<Int> = [15, 23]
        let under = ScrollStillness.stillBelow - 0.0001
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(under, in: [3]), ownMotion: motion) == false)
    }

    /// Half of the frame moves by itself, or more: a video, an animation across the frame. The tiles cannot tell
    /// a change from the motion, and the frame as a whole is judged as before (nil: `changed` stays as it is).
    @Test func halfTheFrameInMotionLeavesTheJudgementToTheFrameAsAWhole() {
        let half = Set(0..<(tiles / 2))
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0.1, in: Set(0..<tiles)), ownMotion: half) == true)
        let over = Set(0..<(tiles / 2 + 1))
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0.1, in: Set(0..<tiles)), ownMotion: over) == nil)
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0, in: []), ownMotion: over) == nil)
    }

    @Test func noDifferencesBetweenTilesLeaveTheJudgementToTheFrameAsAWhole() {
        #expect(ScrollPush.changedBesidesOwnMotion(push: nil, ownMotion: []) == nil)
        #expect(ScrollPush.changedBesidesOwnMotion(push: nil, ownMotion: [15, 23]) == nil)
    }

    /// No motion of its own, and a change spread so thin that no tile reaches the threshold but the frame as a
    /// whole does (0.002 each, the mean over `changedFrom`): a change, as before.
    @Test func aChangeSpreadThinOutsideTheOwnMotionIsAChange() {
        let spread = [Double](repeating: 0.002, count: tiles)
        #expect(ScrollPush.changedBesidesOwnMotion(push: spread, ownMotion: []) == true)
        // The same with a tile playing: the mean of the others is the same.
        #expect(ScrollPush.changedBesidesOwnMotion(push: spread, ownMotion: [15]) == true)
        // Under `changedFrom` on the mean, and under the threshold in each tile: nothing.
        #expect(ScrollPush.changedBesidesOwnMotion(push: [Double](repeating: 0.0005, count: tiles),
                                                   ownMotion: []) == false)
    }

    @Test func aPushThatChangesNothingChangedNothingWhateverTheOwnMotion() {
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0, in: []), ownMotion: []) == false)
        #expect(ScrollPush.changedBesidesOwnMotion(push: differences(0, in: []), ownMotion: [15, 23]) == false)
    }

    // MARK: the tiles

    @Test func theChangedTilesAreTheOnesFromTheThresholdOn() {
        var values = differences(0, in: [])
        values[3] = ScrollStillness.stillBelow
        values[9] = ScrollStillness.stillBelow - 0.0001
        values[63] = 0.5
        #expect(ScrollPush.changedTiles(values) == [3, 63])
        #expect(ScrollPush.changedTiles(nil).isEmpty)
    }

    @Test func theTilesOutsideTheOwnMotionAreCounted() {
        let values = differences(0.02, in: [1, 2, 15, 23, 40])
        #expect(ScrollPush.tilesChanged(outside: [15, 23], in: values) == 3)
        #expect(ScrollPush.tilesChanged(outside: [], in: values) == 5)
        #expect(ScrollPush.tilesChanged(outside: [1, 2, 15, 23, 40], in: values) == 0)
    }

    // MARK: the frame that stood

    /// Two steps decided as stationary, the tiles 15 and 23 playing: the motion is what changed between all the
    /// frames the steps looked at, the kept frame and the one that stood.
    @Test func theMotionAddsUpOverTheStepsThatStood() {
        let kept = frame()
        let first = playing(kept, tiles: [15])
        let second = playing(kept, tiles: [23])
        let afterFirst = StationaryFrame.after(step: first, kept: kept, previous: nil)
        #expect(afterFirst.frame == first)
        #expect(afterFirst.ownMotion == [15])
        // The second step: 23 differs from the kept frame, and 15 and 23 from the frame that stood.
        let afterSecond = StationaryFrame.after(step: second, kept: kept, previous: afterFirst)
        #expect(afterSecond.frame == second)
        #expect(afterSecond.ownMotion == [15, 23])
    }

    @Test func aStepThatChangedNothingAddsNothing() {
        let kept = frame()
        let playingNow = playing(kept, tiles: [15])
        let first = StationaryFrame.after(step: playingNow, kept: kept, previous: nil)
        let second = StationaryFrame.after(step: playingNow, kept: playingNow, previous: first)
        #expect(second.ownMotion == [15])
    }

    /// What stood is forgotten with its motion: a frame that stands from the next step on begins with the tiles
    /// that changed in that step alone (`stationary = nil` at every place a frame is kept or a queue grows).
    @Test func aFrameThatStandsAfterTheOldOneWasForgottenBeginsWithNoMotion() {
        let kept = frame()
        let first = StationaryFrame.after(step: playing(kept, tiles: [15, 23]), kept: kept, previous: nil)
        #expect(first.ownMotion == [15, 23])
        let fresh = StationaryFrame.after(step: kept, kept: kept, previous: nil)
        #expect(fresh.ownMotion.isEmpty)
        #expect(StationaryFrame(frame: kept).ownMotion.isEmpty)
    }

    /// Frames of other sizes cannot be told apart tile by tile: nothing is added, and the step does not fail.
    @Test func framesOfAnotherSizeAddNothing() {
        let kept = frame()
        let small = CaptureFrame(width: 320, height: 320, pixels: [UInt8](repeating: 100, count: 320 * 320 * 4))
        let step = StationaryFrame.after(step: small, kept: kept, previous: StationaryFrame(frame: kept, ownMotion: [15]))
        #expect(step.ownMotion == [15])
        #expect(step.frame == small)
    }

    // MARK: the frames of a capture

    /// The end of Finder's columns: two steps stood while two tiles played, the push changes the same two and
    /// nothing else. Frames in, verdict out, as the session takes them.
    @Test func thePushOfTheEndOfAListWithASmallAnimationChangedNothing() throws {
        let kept = frame()
        var standing = StationaryFrame.after(step: playing(kept, tiles: [15]), kept: kept, previous: nil)
        standing = StationaryFrame.after(step: playing(kept, tiles: [23]), kept: kept, previous: standing)
        let push = playing(kept, tiles: [15, 23])
        let tiles = ScrollStillness.tileDifferences(standing.frame, push)
        #expect(ScrollPush.changedBesidesOwnMotion(push: tiles, ownMotion: standing.ownMotion) == false)
        #expect(ScrollPush.tilesChanged(outside: standing.ownMotion, in: try #require(tiles)) == 0)
    }

    /// The push of a section changes a tile outside the motion as well: a change, whatever plays.
    @Test func aPushThatAlsoChangesATileOutsideTheMotionChangedTheFrame() throws {
        let kept = frame()
        var standing = StationaryFrame.after(step: playing(kept, tiles: [15]), kept: kept, previous: nil)
        standing = StationaryFrame.after(step: playing(kept, tiles: [23]), kept: kept, previous: standing)
        let push = playing(kept, tiles: [15, 23, 4])
        let tiles = ScrollStillness.tileDifferences(standing.frame, push)
        #expect(ScrollPush.changedBesidesOwnMotion(push: tiles, ownMotion: standing.ownMotion) == true)
        #expect(ScrollPush.tilesChanged(outside: standing.ownMotion, in: try #require(tiles)) == 1)
    }
}
