import Testing
@testable import Stampo

/// A calibration that two firm steps in a row contradict, with no queue
/// (`ScrollRecalibration`): the probe landed on a floating card and gave 138 px
/// to a line where every step the matcher placed gives 80.
@Suite struct ScrollRecalibrationTests {
    typealias Action = ScrollRecalibration.Action

    private func next(_ remembered: Double?, offset: Int, lines: Int = 4, qualifies: Bool = true,
                      confirms: Bool = false) -> Action {
        ScrollRecalibration.next(remembered: remembered, offset: offset, lines: lines,
                                 qualifies: qualifies, confirmsCalibration: confirms)
    }

    /// 2026-10-11-140953 steps 02 and 03: 323 and 320 px on four lines, against a
    /// calibration of 138.
    @Test func twoFirmStepsThatAgreeSetTheCalibration() {
        #expect(next(nil, offset: 323) == .remember(80.75))
        #expect(next(80.75, offset: 320) == .recalibrate(80))
    }

    /// 2026-10-11-130811 and 133221: a hero with a parallax card places a step at
    /// 399 on four lines, and the page proper 320. They do not agree.
    @Test func stepsThatDoNotAgreeSetNothing() {
        #expect(next(nil, offset: 399) == .remember(99.75))
        #expect(next(99.75, offset: 320) == .remember(80))
        // Three that follow each other, the last two agree.
        #expect(next(80, offset: 321) == .recalibrate(80.25))
    }

    @Test func oneStepIsOnlyRemembered() {
        #expect(next(nil, offset: 320) == .remember(80))
    }

    /// Agreement is the tolerance of `confirmsLinearity`: two pixels or two percent.
    @Test func agreementIsWithinTwoPixelsOrTwoPercent() {
        // 4 lines at 80: 320, and 2 % of that is 6.4: 322 and 326 are in, 330 and 310 are out.
        #expect(next(80, offset: 322) == .recalibrate(80.5))
        #expect(next(80, offset: 326) == .recalibrate(81.5))
        #expect(next(80, offset: 330) == .remember(82.5))
        #expect(next(80, offset: 310) == .remember(77.5))
    }

    /// A step the calibration predicts says the calibration is right: what was
    /// kept is of no use.
    @Test func aStepThatConfirmsTheCalibrationForgetsWhatWasKept() {
        #expect(next(80.75, offset: 552, confirms: true) == .forget)
        #expect(next(nil, offset: 552, confirms: true) == .forget)
    }

    @Test func aStepThatDoesNotQualifyForgetsWhatWasKept() {
        // A push, a step after stationary steps, a step not placed firmly, one
        // after a failed attempt, or no calibration at all.
        #expect(next(80.75, offset: 320, qualifies: false) == .forget)
        #expect(next(nil, offset: 320, qualifies: false) == .forget)
    }

    @Test func nothingToDivideByIsForgotten() {
        #expect(next(80, offset: 320, lines: 0) == .forget)
        #expect(next(80, offset: 0, lines: 4) == .forget)
    }
}
