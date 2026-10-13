import CoreGraphics
import Testing
@testable import Stampo

/// A queue laid by a calibration that the first matched step then contradicts
/// (`ScrollQueueRelay`): the probe landed on a floating card and gave 138 px to
/// a line where the page gives 80.
@Suite struct ScrollQueueRelayTests {
    @Test func theQueueIsLaidAgainOnlyWhenStrictlyMoreTilesBearOutTheNewDistances() {
        // 2026-10-11-120023: 6 tiles for 552 px, 11 for 320.
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: 6, tilesNew: 11, newLine: 80, currentLine: 138))
        // The end of a page: the last step is short because the page ended, and
        // the steps before it went all the way (2026-10-10-000138, 2026-10-08-223755).
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 4, tilesNew: 3, newLine: 80, currentLine: 138))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 10, tilesNew: 5, newLine: 80, currentLine: 138))
        // A tie changes nothing.
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 5, tilesNew: 5, newLine: 80, currentLine: 138))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 0, tilesNew: 0, newLine: 80, currentLine: 138))
    }

    /// 2026-10-13-205943: seven steps waited, none matched, and the capture ended; the second attempt matched at a
    /// short step. Four waiting is where the short step comes, once for the queue, and only on a calibration the
    /// matched steps have borne out.
    @Test func aQueueOfFourGetsOneShortStepWhenTheCalibrationIsConfirmed() {
        #expect(ScrollQueueLaying.shortStepAfter == 4)
        #expect(!ScrollQueueLaying.shortStepDue(waiting: 3, calibrationConfirmed: true, tried: false))
        #expect(ScrollQueueLaying.shortStepDue(waiting: 4, calibrationConfirmed: true, tried: false))
        #expect(ScrollQueueLaying.shortStepDue(waiting: 7, calibrationConfirmed: true, tried: false))
        // Not on a calibration that is one probe, possibly of a line.
        #expect(!ScrollQueueLaying.shortStepDue(waiting: 4, calibrationConfirmed: false, tried: false))
        // Once for the queue.
        #expect(!ScrollQueueLaying.shortStepDue(waiting: 5, calibrationConfirmed: true, tried: true))
        // No queue, no short step.
        #expect(!ScrollQueueLaying.shortStepDue(waiting: 0, calibrationConfirmed: true, tried: false))
    }

    // MARK: A full queue

    private typealias Cost = ScrollQueueLaying.PairCost

    /// 2026-10-13-205943, steps 17 to 25, over the pairs from the last frame laid: the fit at the 560 px of the
    /// calibration and with none, over the tiles that are not pinned. Step 18 is the one the tiles did not confirm.
    private let costs205943: [Cost?] = [
        Cost(shifted: 39.0, still: 66.1), Cost(shifted: 79.3, still: 61.8), Cost(shifted: 9.1, still: 46.0),
        Cost(shifted: 3.7, still: 30.2), Cost(shifted: 0.0, still: 9.7), Cost(shifted: 0.5, still: 9.8),
        Cost(shifted: 1.0, still: 5.8), Cost(shifted: 2.6, still: 3.9), Cost(shifted: 2.9, still: 5.3)]
    private let confirmed205943 = [true, false, true, true, true, true, true, true]

    private func evidence(calibration: Bool = true, queue: [Bool], current: Bool = true, contradicted: Bool = false,
                          pairs: [Cost?], laid: Bool = false) -> ScrollQueueLaying.QueueEvidence {
        .init(calibrationConfirmed: calibration, queueConfirmed: queue, currentConfirmed: current,
              contradicted: contradicted, pairs: pairs, laidSinceMatch: laid)
    }

    /// The queue of 205943 is laid: 7 of 8 and the current one confirmed, no contradiction, the page moved in every
    /// pair that can be looked at (the pairs with step 18, which changed as a whole, are not looked at one by one).
    @Test func theQueueOf205943IsLaidByTheCalibration() {
        #expect(ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, pairs: costs205943)))
    }

    /// 2026-10-10-003948: confirmed eight of eight on a calibration that matched steps had borne out, but the page
    /// stood while a pattern repeated: the frame is the same with no shift, and does not fit at 200.
    @Test func aPageThatStoodWhileAPatternRepeatedIsNotLaid() {
        let stood = [Cost?](repeating: Cost(shifted: 87.0, still: 0.0), count: 9)
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: [Bool](repeating: true, count: 8), pairs: stood)))
    }

    /// 2026-10-11-185058 and 185700: the end of a page, the same frame again and again.
    @Test func framesThatAreTheSameAreNotLaid() {
        let same = [Cost?](repeating: Cost(shifted: 2.45, still: 0.0), count: 9)
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: [Bool](repeating: false, count: 8), pairs: same)))
        // One identical pair among pairs that moved is enough.
        var one = costs205943
        one[5] = Cost(shifted: 0.5, still: 0.2)
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, pairs: one)))
    }

    /// 2026-10-11-185309: a calibration of 16 px a line that no matched step had borne out, one step of eight confirmed.
    @Test func aCalibrationNoMatchedStepHasBorneOutIsNotLaid() {
        let queue = [true, false, false, false, false, false, false, false]
        let costs: [Cost?] = [Cost(shifted: 72.9, still: 76.5), Cost(shifted: 25.2, still: 16.3), Cost(shifted: 26.5, still: 14.9),
                              Cost(shifted: 81.4, still: 69.7), Cost(shifted: 38.5, still: 28.4), Cost(shifted: 26.3, still: 28.6),
                              Cost(shifted: 10.9, still: 14.2), Cost(shifted: 8.3, still: 9.3), Cost(shifted: 3.9, still: 5.2)]
        #expect(!ScrollQueueLaying.shouldLay(evidence(calibration: false, queue: queue, pairs: costs)))
        // Nor with the calibration borne out, for the confirmed are too few.
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: queue, pairs: costs205943)))
    }

    /// The other conditions: six of eight, the current step confirmed, nothing contradicted, once between two
    /// steps the matcher placed, the pairs all there.
    @Test func theOtherConditionsOfLayingAFullQueue() {
        let five = [true, true, true, true, true, false, false, false]
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: five, pairs: costs205943)))
        // Six of eight, the two that are not confirmed being step 18 and the last waiting one.
        let six = [true, false, true, true, true, true, true, false]
        #expect(ScrollQueueLaying.shouldLay(evidence(queue: six, pairs: costs205943)))
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, current: false, pairs: costs205943)))
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, contradicted: true, pairs: costs205943)))
        // The second full queue in a row, with no step placed between them.
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, pairs: costs205943, laid: true)))
        // A pair that could not be looked at, or a count of pairs that does not fit.
        var missing = costs205943
        missing[3] = nil
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, pairs: missing)))
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: confirmed205943, pairs: Array(costs205943.dropLast()))))
    }

    /// Over all the pairs the fit at the shifts has to be well under that with none, though each confirmed pair is better.
    @Test func theFitAtTheShiftsHasToBeWellUnderTheFitWithNone() {
        // Each pair a little better than none, the sum 0.95 of it: a page that may have moved, may not.
        let weak = [Cost?](repeating: Cost(shifted: 9.5, still: 10.0), count: 9)
        #expect(!ScrollQueueLaying.shouldLay(evidence(queue: [Bool](repeating: true, count: 8), pairs: weak)))
        let clear = [Cost?](repeating: Cost(shifted: 4.0, still: 10.0), count: 9)
        #expect(ScrollQueueLaying.shouldLay(evidence(queue: [Bool](repeating: true, count: 8), pairs: clear)))
    }

    /// The pairs themselves: a page of noise moved 560 rows fits at 560 and not with none; a frame the same as the
    /// one before fits with none; and what is pinned does not decide it either way.
    @Test func thePairCostSaysWhetherThePageMovedByTheShift() throws {
        func page(_ offset: Int, card: Bool = false) -> CaptureFrame {
            let width = 480, height = 800
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    var value = SeamScenes.page(offset + y, x)
                    // A card that stands where it is, in the tiles 13, 14, 18 and 19 (the lower right).
                    if card, x >= 300, y >= 400 { value = SeamScenes.panelPixel(y, x) }
                    let i = (y * width + x) * 4
                    bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
                }
            }
            return CaptureFrame(width: width, height: height, pixels: bytes)
        }
        let moved = ScrollQueueLaying.pairCost(previous: page(0), current: page(300), offset: 300, pinnedTiles: [])
        let a = try #require(moved)
        #expect(a.better && !a.identical && a.shifted < 1 && a.still > 20)
        let stood = ScrollQueueLaying.pairCost(previous: page(0), current: page(0), offset: 300, pinnedTiles: [])
        let b = try #require(stood)
        #expect(b.identical && !b.better)
        // The card stands, the page moves: with the card's tiles left out it still fits at the shift; with none left
        // out the card, which stands, is compared with the page where the shift puts it.
        let pinned: Set<Int> = [13, 14, 18, 19]
        let withCard = ScrollQueueLaying.pairCost(previous: page(0, card: true), current: page(300, card: true),
                                                  offset: 300, pinnedTiles: pinned)
        let c = try #require(withCard)
        #expect(c.better && c.shifted < 1)
        // Too little left to compare: nil.
        let all = Set(0..<20)
        #expect(ScrollQueueLaying.pairCost(previous: page(0), current: page(300), offset: 300, pinnedTiles: all) == nil)
        // No shift to look at.
        #expect(ScrollQueueLaying.pairCost(previous: page(0), current: page(300), offset: 0, pinnedTiles: []) == nil)
    }

    /// Three tiles are too few to refute a calibration: 2026-10-13-190147 step 8 had three
    /// against two for 51 px a line where the page gives 80, and it moved a queue frame
    /// from 640 px to 404. The probe's 138 against 80 had six against five at the least.
    @Test func aNewLineThatIsNotTheOldOneNeedsFiveTiles() {
        // The one that was wrong: not laid again, the queue stays as it was.
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 2, tilesNew: 3, newLine: 51, currentLine: 80))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 0, tilesNew: 4, newLine: 51, currentLine: 80))
        // The correction of the probe, on the thinnest evidence that was right (2026-10-11-124606).
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: 5, tilesNew: 6, newLine: 80, currentLine: 138))
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: 0, tilesNew: 5, newLine: 80, currentLine: 138))
        // The old line a little off (within 15 %) is not a new calibration: more tiles are enough.
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: 1, tilesNew: 3, newLine: 85, currentLine: 80))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 1, tilesNew: 3, newLine: 95, currentLine: 80))
        // No calibration to overturn.
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: 1, tilesNew: 3, newLine: 51, currentLine: nil))
    }

    /// 2026-10-10-001759 step 21: 0.73 with five regions, after a pause, on a
    /// page of video; its neighbours say 80 px a line. The steps the rule is
    /// for were placed at 1.00.
    @Test func onlyAFirmMatchCanOverturnTheCalibration() {
        #expect(ScrollQueueRelay.firmConfidence == 0.9)
        #expect(ScrollQueueRelay.isFirm(confidence: 1.0))
        #expect(ScrollQueueRelay.isFirm(confidence: 0.9))
        #expect(!ScrollQueueRelay.isFirm(confidence: 0.89))
        #expect(!ScrollQueueRelay.isFirm(confidence: 0.73))
        #expect(!ScrollQueueRelay.isFirm(confidence: 0.72))
    }

    @Test func aStepOfTheQueueIsItsLinesTimesTheNewLineRounded() {
        // Four lines at 79.6 px, three at 79.6: 318.4 and 238.8.
        #expect(ScrollQueueRelay.movements(lines: [4, 3], current: [552, 414], pixelsPerLine: 79.6,
                                           axisLength: 1500) == [318, 239])
        // 4 × 80.125 = 320.5 rounds away from zero, to 321.
        #expect(ScrollQueueRelay.movements(lines: [4], current: [552], pixelsPerLine: 80.125,
                                           axisLength: 1500) == [321])
    }

    @Test func aStepWithoutLinesKeepsItsDistance() {
        // One taken to have arrived while the capture was paused.
        #expect(ScrollQueueRelay.movements(lines: [4, nil, 4], current: [552, 200, 552], pixelsPerLine: 80,
                                           axisLength: 1500) == [320, 200, 320])
    }

    @Test func aQueueThatCannotBeLaidAtTheNewDistancesStaysAsItWas() {
        // Nothing to divide by, or a distance of nothing.
        #expect(ScrollQueueRelay.movements(lines: [4], current: [552], pixelsPerLine: 0, axisLength: 1500) == nil)
        #expect(ScrollQueueRelay.movements(lines: [0], current: [552], pixelsPerLine: 80, axisLength: 1500) == nil)
        // Further than a step is ever planned: three quarters of the frame.
        #expect(ScrollQueueRelay.movements(lines: [10], current: [552], pixelsPerLine: 80, axisLength: 1000) == nil)
        #expect(ScrollQueueRelay.movements(lines: [9], current: [552], pixelsPerLine: 80, axisLength: 1000) == [720])
        // Lines and distances that do not pair up.
        #expect(ScrollQueueRelay.movements(lines: [4, 4], current: [552], pixelsPerLine: 80, axisLength: 1500) == nil)
    }

    @Test func theQueueKeepsTheLinesOfItsSteps() {
        let frame = CaptureFrame(width: 8, height: 8, pixels: [UInt8](repeating: 0, count: 8 * 8 * 4))
        var queue = TemporarySteps()
        queue.add(frame, movement: 552, confirmed: true, lines: 4)
        queue.add(frame, movement: 552, confirmed: false, lines: 4, stationaryLines: 4)
        queue.add(frame, movement: 200, confirmed: false)
        #expect(queue.steps.map(\.lines) == [4, 4, nil])
        #expect(queue.steps.map(\.stationaryLines) == [0, 4, 0])
        #expect(queue.take().map(\.stationaryLines) == [0, 4, 0])
        #expect(queue.isEmpty)
    }

    /// 2026-10-11-124606: step 03 was decided "stationary" by a wrong
    /// calibration, its frame thrown away, and step 04 was 640 px from the one
    /// kept — two steps of four lines at 80 px.
    @Test func aStepAfterStationaryStepsCanBeTheDistanceOfThemAll() {
        #expect(ScrollQueueRelay.movementWithStationary(lines: 4, stationaryLines: 4, pixelsPerLine: 80,
                                                        axisLength: 932) == 640)
        // Rounded, as the other.
        #expect(ScrollQueueRelay.movementWithStationary(lines: 4, stationaryLines: 3, pixelsPerLine: 79.6,
                                                        axisLength: 932) == 557)
        // Nothing stationary, no lines, nothing to divide by: no second distance.
        #expect(ScrollQueueRelay.movementWithStationary(lines: 4, stationaryLines: 0, pixelsPerLine: 80,
                                                        axisLength: 932) == nil)
        #expect(ScrollQueueRelay.movementWithStationary(lines: nil, stationaryLines: 4, pixelsPerLine: 80,
                                                        axisLength: 932) == nil)
        #expect(ScrollQueueRelay.movementWithStationary(lines: 4, stationaryLines: 4, pixelsPerLine: 0,
                                                        axisLength: 932) == nil)
        // As far as three quarters of the frame, 699 here, and no further.
        #expect(ScrollQueueRelay.movementWithStationary(lines: 4, stationaryLines: 4, pixelsPerLine: 87.4,
                                                        axisLength: 932) == 699)
        #expect(ScrollQueueRelay.movementWithStationary(lines: 4, stationaryLines: 4, pixelsPerLine: 87.5,
                                                        axisLength: 932) == nil)
    }

    @Test func theLongerDistanceNeedsStrictlyMoreTilesAndATieKeepsTheStep() {
        // 02 → 04 of 124606: 1 tile at 320, 3 at 640.
        #expect(ScrollQueueRelay.prefersStationaryLines(tilesOne: 1, tilesWithStationary: 3))
        // The decision that the page stood is not refuted by a tie.
        #expect(!ScrollQueueRelay.prefersStationaryLines(tilesOne: 2, tilesWithStationary: 2))
        #expect(!ScrollQueueRelay.prefersStationaryLines(tilesOne: 0, tilesWithStationary: 0))
        #expect(!ScrollQueueRelay.prefersStationaryLines(tilesOne: 5, tilesWithStationary: 2))
    }

    /// The tiles of a pair of frames choose between the two distances: 200 apart,
    /// they bear out 200; 400 apart, 400 — the page moved in the step between.
    @Test func theTilesOfThePairChooseBetweenTheOneStepAndTheTwo() {
        let frames = [0, 200, 400].map(noisePage)
        func tiles(_ from: Int, _ to: Int, at offset: Int) -> Int {
            FrameMatcher.evidence(previous: frames[from], current: frames[to], axis: .vertical,
                                  offset: offset, searchLimit: 532).consistent
        }
        // 0 → 1 is one step: the page stood in none.
        #expect(!ScrollQueueRelay.prefersStationaryLines(tilesOne: tiles(0, 1, at: 200),
                                                         tilesWithStationary: tiles(0, 1, at: 400)))
        // 0 → 2 is two: the page moved in the step that was thrown away.
        #expect(ScrollQueueRelay.prefersStationaryLines(tilesOne: tiles(0, 2, at: 200),
                                                        tilesWithStationary: tiles(0, 2, at: 400)))
    }

    /// A page of noise, `offset` rows down.
    private func noisePage(_ offset: Int) -> CaptureFrame {
        let width = 240, height = 800
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = SeamScenes.page(offset + y, x)
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// Frames of a page scrolled 320 px a step. The tiles bear out 320, and
    /// none of them 552, which is what a calibration of 138 px a line would
    /// have laid them at: the sums that decide.
    @Test func theTilesOfFramesScrolled320BearOut320AndNot552() {
        let frames = (0..<4).map { noisePage($0 * 320) }
        var at320 = 0, at552 = 0
        for index in 1..<frames.count {
            at320 += FrameMatcher.evidence(previous: frames[index - 1], current: frames[index], axis: .vertical,
                                           offset: 320, searchLimit: 672).consistent
            at552 += FrameMatcher.evidence(previous: frames[index - 1], current: frames[index], axis: .vertical,
                                           offset: 552, searchLimit: 672).consistent
        }
        #expect(at320 > at552, "320: \(at320), 552: \(at552)")
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: at552, tilesNew: at320, newLine: 80, currentLine: 138))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: at320, tilesNew: at552, newLine: 138, currentLine: 80))
    }

    @Test func aSeamIsSaidInAFewWordsAndTheMiddleInOne() {
        #expect(ScrollSeam.Choice(skip: 70, reason: .middleAgrees).summary == "middle")
        #expect(ScrollSeam.Choice(skip: 59, reason: .moved(11)).summary == "−11 px")
        #expect(ScrollSeam.Choice(skip: 70, reason: .floor).summary == "middle (floor)")
        #expect(ScrollSeam.Choice(skip: 70, reason: .noRun).summary == "middle (no run)")
        #expect(ScrollSeam.Choice(skip: 70, reason: .details).summary == "middle (details)")
    }
}
