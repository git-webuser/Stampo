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
        queue.add(frame, movement: 200, confirmed: false)
        #expect(queue.steps.map(\.lines) == [4, nil])
        #expect(queue.take().map(\.lines) == [4, nil])
        #expect(queue.isEmpty)
    }

    /// Frames of a page scrolled 320 px a step. The tiles bear out 320, and
    /// none of them 552, which is what a calibration of 138 px a line would
    /// have laid them at: the sums that decide.
    @Test func theTilesOfFramesScrolled320BearOut320AndNot552() {
        func frame(_ offset: Int) -> CaptureFrame {
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
        let frames = (0..<4).map { frame($0 * 320) }
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
}
