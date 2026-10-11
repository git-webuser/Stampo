import CoreGraphics
import Testing
@testable import Stampo

/// A queue laid by a calibration that the first matched step then contradicts
/// (`ScrollQueueRelay`): the probe landed on a floating card and gave 138 px to
/// a line where the page gives 80.
@Suite struct ScrollQueueRelayTests {
    @Test func theQueueIsLaidAgainOnlyWhenStrictlyMoreTilesBearOutTheNewDistances() {
        // 2026-10-11-120023: 6 tiles for 552 px, 11 for 320.
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: 6, tilesNew: 11))
        // The end of a page: the last step is short because the page ended, and
        // the steps before it went all the way (2026-10-10-000138, 2026-10-08-223755).
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 4, tilesNew: 3))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 10, tilesNew: 5))
        // A tie changes nothing.
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 5, tilesNew: 5))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: 0, tilesNew: 0))
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
        #expect(ScrollQueueRelay.shouldRelay(tilesOld: at552, tilesNew: at320))
        #expect(!ScrollQueueRelay.shouldRelay(tilesOld: at320, tilesNew: at552))
    }

    @Test func aSeamIsSaidInAFewWordsAndTheMiddleInOne() {
        #expect(ScrollSeam.Choice(skip: 70, reason: .middleAgrees).summary == "middle")
        #expect(ScrollSeam.Choice(skip: 59, reason: .moved(11)).summary == "−11 px")
        #expect(ScrollSeam.Choice(skip: 70, reason: .floor).summary == "middle (floor)")
        #expect(ScrollSeam.Choice(skip: 70, reason: .noRun).summary == "middle (no run)")
        #expect(ScrollSeam.Choice(skip: 70, reason: .details).summary == "middle (details)")
    }
}
