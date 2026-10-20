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

    /// 2026-10-11-185309: step 07 placed at 47 px on three lines — 15.7 a line
    /// against 138, 0.11 times — and the calibration became 16 px a line.
    @Test func aNewLineIsBelievedOnlyBetweenTwoFifthsAndTwoAndAHalfTimesTheCurrent() {
        #expect(ScrollRecalibration.plausibleRatio == 0.4...2.5)
        // The probe on a floating card: 138 against the page's 80, a step on 80 back.
        #expect(ScrollRecalibration.isPlausible(newLine: 80, current: 138))
        #expect(ScrollRecalibration.isPlausible(newLine: 138, current: 80))
        // The edges are in; just outside are not.
        #expect(ScrollRecalibration.isPlausible(newLine: 40, current: 100))
        #expect(ScrollRecalibration.isPlausible(newLine: 250, current: 100))
        #expect(!ScrollRecalibration.isPlausible(newLine: 39.9, current: 100))
        #expect(!ScrollRecalibration.isPlausible(newLine: 250.1, current: 100))
        // 185309.
        #expect(!ScrollRecalibration.isPlausible(newLine: 47.0 / 3, current: 138))
        // Nothing to compare with.
        #expect(!ScrollRecalibration.isPlausible(newLine: 80, current: 0))
    }

    @Test func aRefusalSaysWhatWasRefusedAndByHowMuch() {
        #expect(ScrollRecalibration.refusal(newLine: 47.0 / 3, current: 138) == "recalibration refused (16 px/line, ×0.11)")
        #expect(ScrollRecalibration.refusal(newLine: 400, current: 100) == "recalibration refused (400 px/line, ×4.00)")
    }

    @Test func nothingToDivideByIsForgotten() {
        #expect(next(80, offset: 320, lines: 0) == .forget)
        #expect(next(80, offset: 0, lines: 4) == .forget)
    }

    @Test func galleryAgreementUsesFivePercentOrFourPixelsWithoutRelaxingLinearity() {
        #expect(ScrollStepPlanner.agreesWithCalibration(offset: 798, lines: 10, pixelsPerLine: 78))
        #expect(!ScrollStepPlanner.confirmsLinearity(offset: 798, lines: 10, pixelsPerLine: 78))
        for offset in [741, 819] {
            #expect(ScrollStepPlanner.agreesWithCalibration(offset: offset, lines: 10, pixelsPerLine: 78))
        }
        for offset in [740, 820] {
            #expect(!ScrollStepPlanner.agreesWithCalibration(offset: offset, lines: 10, pixelsPerLine: 78))
        }
        for offset in [16, 24] {
            #expect(ScrollStepPlanner.agreesWithCalibration(offset: offset, lines: 1, pixelsPerLine: 20))
        }
        for offset in [15, 25] {
            #expect(!ScrollStepPlanner.agreesWithCalibration(offset: offset, lines: 1, pixelsPerLine: 20))
        }
        #expect(!ScrollStepPlanner.agreesWithCalibration(offset: 0, lines: 1, pixelsPerLine: 20))
        #expect(!ScrollStepPlanner.agreesWithCalibration(offset: 20, lines: 0, pixelsPerLine: 20))
        for line in [0.0, -1, .nan, .infinity] {
            #expect(!ScrollStepPlanner.agreesWithCalibration(offset: 20, lines: 1, pixelsPerLine: line))
        }
    }

    @Test func aCloseMatchedStepHoldsGalleryCalibrationUntilItIsReset() {
        var calibration = ScrollGalleryCalibration()
        #expect(!calibration.held)
        calibration.matchedStep(offset: 798, lines: 10, pixelsPerLine: 78,
                                placement: .matched(cleanStep: true), isPush: false)
        #expect(calibration.held)
        // A later stray match does not erase the earlier full-step evidence.
        calibration.matchedStep(offset: 36, lines: 3, pixelsPerLine: 78,
                                placement: .matched(cleanStep: true), isPush: false)
        #expect(calibration.held)
        calibration.reset()
        #expect(!calibration.held)
    }

    @Test func inferredUncleanAndPushStepsCannotHoldGalleryCalibration() {
        for placement: ScrollStepPlacement in [.matched(cleanStep: false), .recovered, .parallax, .gallery] {
            var calibration = ScrollGalleryCalibration()
            calibration.matchedStep(offset: 798, lines: 10, pixelsPerLine: 78, placement: placement, isPush: false)
            #expect(!calibration.held)
        }
        var push = ScrollGalleryCalibration(), uncalibrated = ScrollGalleryCalibration()
        push.matchedStep(offset: 798, lines: 10, pixelsPerLine: 78, placement: .matched(cleanStep: true), isPush: true)
        uncalibrated.matchedStep(offset: 798, lines: 10, pixelsPerLine: nil,
                                 placement: .matched(cleanStep: true), isPush: false)
        #expect(!push.held && !uncalibrated.held)
    }

    @Test func aBadProbeOnTheClaudeHeroDoesNotOpenGalleryEntry() {
        var calibration = ScrollGalleryCalibration()
        for offset in [320, 323, 399, 320] {
            calibration.matchedStep(offset: offset, lines: 4, pixelsPerLine: 138,
                                    placement: .matched(cleanStep: true), isPush: false)
            #expect(!calibration.held)
        }
    }
}
