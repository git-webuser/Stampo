import Foundation

/// What to do with a step the matcher could not place: the page may have
/// stopped, may have moved where the calibration says it should have without
/// the frames being able to bear that out, or the step may simply have gone
/// wrong.
///
/// The frames say less than one would like. A video on a plain background, a
/// text that fades in, an empty gap between two sections: in each the pixels do
/// not tell a page that moved from one that did not. So a step placed by the
/// calibration alone is only a guess and is kept apart (`TemporarySteps`)
/// until a step the matcher does place carries it into the image.
nonisolated enum ScrollStepDecision: Equatable {
    /// The page did not move, and the frames prove it: counts towards the end.
    case stationary
    /// Place it where the calibration says, provisionally. `confirmed` when
    /// enough tiles of the frames bear the distance out; otherwise nothing
    /// speaks against it, which is all there is.
    case temporary(confirmed: Bool)
    /// Go back the lines just sent and try again with half the step.
    case retry
    /// Too many steps are waiting for a confirmation: the capture ends here.
    case finish

    struct Evidence: Equatable {
        /// The matcher gave up on the step with one of the refusals that say it
        /// could not tell (`isUndecided`) — and not with some other failure.
        var undecided: Bool
        /// A calibration, and a step clean of earlier failed attempts, so that
        /// there is a distance to expect.
        var canExpect: Bool
        /// Tiles that fit the expected distance, and those that know better.
        var consistent: Int
        var against: Int
        /// The frames contradict the expected distance outright.
        var contradicted: Bool
        /// Tiles needed to call the distance confirmed.
        var required: Int
        /// Tiles that prove the page stopped: standing still with something in
        /// them, not known to be fixed to the viewport, and in the middle of the
        /// frame (`provingStop`).
        var unpinnedStanding: Int
        /// Steps already waiting.
        var queued: Int
    }

    /// Whether the matcher's refusal is "cannot tell". All three are: the frames
    /// have nothing to place them by (`noReliableMotion`), place them two ways
    /// (`ambiguousMotion`), or find across the scroll the little that is left to
    /// find (`crossAxisMotion`) — which is what an empty frame with only a
    /// site's bar in it does: noise across the axis, nothing along it. Each is
    /// then asked of the tiles.
    static func isUndecided(_ error: Error) -> Bool {
        switch error as? FrameMatchError {
        case .noReliableMotion, .ambiguousMotion, .crossAxisMotion: return true
        case .outputLimitExceeded, nil: return false
        }
    }

    /// The standing tiles that can prove the page stopped: not pinned, and in
    /// the middle rows — 1 and 2 of 0 to 3, along the scroll. The first and
    /// last rows are where the site's bars and banners live, and a tile that
    /// stands there says nothing: an empty gap between two sections leaves
    /// only the bar in the frame, and the bar stands at every step whether
    /// pinned yet or not.
    static func provingStop(standing: Set<Int>, pinned: Set<Int>) -> Int {
        standing.subtracting(pinned).filter { tile in
            let row = tile / FrameMatcher.tileColumns
            return row >= 1 && row < FrameMatcher.tileRows - 1
        }.count
    }

    /// The stop is proved by a tile of the middle rows with content that stands
    /// still and is not one of those fixed to the viewport, while none of the
    /// tiles bears out that the page moved (`provingStop`). A blank frame, a
    /// frame that is one video, a frame whose only standing tiles are the bar
    /// are no proof.
    static func decide(_ evidence: Evidence) -> ScrollStepDecision {
        guard evidence.undecided else { return .retry }
        if evidence.unpinnedStanding >= 1, evidence.consistent == 0 { return .stationary }
        guard evidence.canExpect, !evidence.contradicted else { return .retry }
        if evidence.queued >= TemporarySteps.limit { return .finish }
        if evidence.consistent >= evidence.required { return .temporary(confirmed: true) }
        return evidence.against == 0 ? .temporary(confirmed: false) : .retry
    }
}

/// Steps placed by the calibration alone, waiting for one the matcher places.
/// The frames wait with the distance each moved the page; the last of them is
/// where the next step is matched from. The first step the matcher places adds
/// them to the image in order and then itself; if the capture ends first they
/// are dropped, and what they stood for is not in the image.
nonisolated struct TemporarySteps {
    /// More than this many waiting and the capture ends: that many steps without
    /// a confirmation is a page the frames cannot read, not a gap in one.
    static let limit = 8

    struct Step {
        let frame: CaptureFrame
        let movement: Int
        let confirmed: Bool
        /// The wheel lines that were sent for it, when it was a step of the
        /// capture's own: its distance is then lines times a calibration, and
        /// can be worked out again if the calibration turns out wrong. Nil for
        /// a step taken to have arrived while the capture was paused.
        let lines: Int32?
        /// The lines of steps decided as stationary between the last frame kept
        /// and this one: the page may have moved in those too, and then this
        /// frame is further from the one before it than its own lines say.
        let stationaryLines: Int32
    }

    private(set) var steps: [Step] = []

    var count: Int { steps.count }
    var isEmpty: Bool { steps.isEmpty }

    mutating func add(_ frame: CaptureFrame, movement: Int, confirmed: Bool, lines: Int32? = nil,
                      stationaryLines: Int32 = 0) {
        steps.append(Step(frame: frame, movement: movement, confirmed: confirmed, lines: lines,
                          stationaryLines: stationaryLines))
    }

    /// The waiting steps, in order, and none left waiting: they are about to
    /// be laid into the image.
    mutating func take() -> [Step] {
        defer { steps.removeAll() }
        return steps
    }

    /// The capture ended with these still waiting. Returns how many.
    @discardableResult
    mutating func discard() -> Int {
        let dropped = steps.count
        steps.removeAll()
        return dropped
    }
}

/// A queue laid by a calibration that a step the matcher placed then
/// contradicted: the probe landed on a floating card that moves faster than the
/// page, and gave 138 px to a line where every matched step gives 80. The queue
/// was laid at 138; the tiles of its own frames can say which of the two
/// distances they bear out.
nonisolated enum ScrollQueueRelay {
    /// How sure the matcher must be of the step that overturns a calibration.
    /// It accepts a match from 0.72, and a barely accepted one on a page with
    /// video — 0.73 after a pause, with five regions — can be wrong while the
    /// steps around it say the line is what it was; the tiles of a page like
    /// that are noise too. The steps this was made for were placed at 1.00 by
    /// eight or nine regions.
    static let firmConfidence = 0.9

    /// Whether a step placed with this confidence is firm enough to say what a
    /// line is.
    static func isFirm(confidence: Double) -> Bool {
        confidence >= firmConfidence
    }

    /// Lay the queue again at the new distances when more tiles agree with
    /// them than with the old: strictly more, so that a tie leaves things as
    /// they are. Near the end of a page the last step is short because the page
    /// ended, not because a line is shorter, and the tiles then keep the old.
    static func shouldRelay(tilesOld: Int, tilesNew: Int) -> Bool {
        tilesNew > tilesOld
    }

    /// The distance of a step that came after steps decided as stationary, if
    /// the page moved in those as well: its lines and theirs, times a line.
    /// Nil when there were none, or if it comes out as nothing or as more than
    /// three quarters of the frame.
    static func movementWithStationary(lines: Int32?, stationaryLines: Int32, pixelsPerLine: Double,
                                       axisLength: Int) -> Int? {
        guard let lines, stationaryLines > 0, pixelsPerLine > 0 else { return nil }
        let moved = Int((Double(lines + stationaryLines) * pixelsPerLine).rounded())
        return moved > 0 && moved <= axisLength * 3 / 4 ? moved : nil
    }

    /// Which of the two distances of a step after "stationary" steps its own
    /// pair of frames bears out: the longer, if strictly more tiles agree with
    /// it. The decision that the page stood was not refuted by a tie.
    static func prefersStationaryLines(tilesOne: Int, tilesWithStationary: Int) -> Bool {
        tilesWithStationary > tilesOne
    }

    /// The distance of each step of a queue for a line of `pixelsPerLine`:
    /// lines times that, rounded. A step without lines keeps its distance. Nil
    /// if any comes out as nothing or more than three quarters of the frame,
    /// which is as far as a step is ever planned.
    static func movements(lines: [Int32?], current: [Int], pixelsPerLine: Double,
                          axisLength: Int) -> [Int]? {
        guard lines.count == current.count, pixelsPerLine > 0 else { return nil }
        var result: [Int] = []
        for (lines, movement) in zip(lines, current) {
            guard let lines else { result.append(movement); continue }
            let moved = Int((Double(lines) * pixelsPerLine).rounded())
            guard moved > 0, moved <= axisLength * 3 / 4 else { return nil }
            result.append(moved)
        }
        return result
    }
}

/// A page that holds still while something on it moves: a section pinned to
/// the viewport whose stages change with the scroll, and which snaps back to
/// the middle of a stage when the wheel stops. A step of a few lines is less
/// than half a stage, so the page comes back to where it was and the frames are
/// the same: three of those in a row would end the capture in the middle of the
/// page. A push — one wheel event of twice the lines — is more than half a
/// stage; the section changes and, once it is passed, the page is further on.
///
/// What the capture does about it, as a state: `Mode` says what the next step is,
/// `next` what a step's outcome makes of it.
nonisolated enum ScrollPush {
    /// A frame whose difference from the last is under this is the same frame.
    static let changedFrom = 0.001
    /// Pushes that move nothing and change the frame each time, at most: a video
    /// or an animation at the end of the page changes the frames and does not go
    /// anywhere.
    static let limit = 6

    enum Mode: Equatable {
        /// Ordinary steps.
        case none
        /// Two steps in a row proved the page stood: the next step is a push.
        case push
        /// The frames of a pinned section are being replaced, `pushes` so far;
        /// the next step is a push too.
        case section(pushes: Int)
        /// A push left the frame as it was: the next step is an ordinary one.
        case settle
    }

    /// What a step came to, as far as this goes.
    enum Outcome: Equatable {
        /// The matcher placed it.
        case placed
        /// Decided as stationary, the frame changed or not.
        case stationary(changed: Bool)
        /// Anything else: retried, queued, finished.
        case other
    }

    enum Action: Equatable {
        /// As before: nothing special.
        case proceed
        /// Counts as a step that the page stood in.
        case count
        /// Lay the frame over the last one laid.
        case replace
        /// A push left everything as it was in a section: nothing counts.
        case hold
        /// There is nothing more to find: save.
        case end
    }

    struct Step: Equatable {
        let action: Action
        let mode: Mode
    }

    static func sendsPush(_ mode: Mode) -> Bool {
        switch mode {
        case .push, .section: return true
        case .none, .settle: return false
        }
    }

    /// The step after the second in a row that proved the page stood is a
    /// push — with steps waiting, as ever, a third of those ends the capture.
    static func startsPush(zeroMotionCount: Int, queueIsEmpty: Bool) -> Bool {
        zeroMotionCount == 2 && queueIsEmpty
    }

    static func next(mode: Mode, outcome: Outcome) -> Step {
        guard case .stationary(let changed) = outcome else { return Step(action: .proceed, mode: .none) }
        switch mode {
        case .none:
            return Step(action: .count, mode: .none)
        case .push:
            return changed ? Step(action: .replace, mode: .section(pushes: 1))
                           : Step(action: .end, mode: .none)
        case .section(let pushes):
            return changed ? Step(action: .replace, mode: .section(pushes: pushes + 1))
                           : Step(action: .hold, mode: .settle)
        case .settle:
            return changed ? Step(action: .count, mode: .none)
                           : Step(action: .end, mode: .none)
        }
    }

    /// How many unpinned tiles of the middle rows must stand for a step decided as
    /// stationary to be sure. In every decision of the recordings two to ten
    /// stood — two fifteen times, three twenty-four times, more after that; the
    /// one false "stationary" there is (the page moved, the matcher did not see
    /// it: 2026-10-11-124606 step 03) had one. Three leaves two tiles of margin
    /// over it; the steps with two stay on the old rule.
    static let reliableStandingTiles = 3

    /// Whether a step decided as stationary is one to rely on: the frame is the
    /// same as the one kept (a blank step, after wheel events: a short step does
    /// not move the page here), or `reliableStandingTiles` of it stand.
    static func isReliableStep(difference: Double, unpinnedStanding: Int) -> Bool {
        !isChanged(difference) || unpinnedStanding >= reliableStandingTiles
    }

    /// What a step came to when the page stood for two steps before it. When both
    /// steps that started a push were reliable, a push the matcher could not
    /// place whose frame changed is a section changing its stage, whether or not
    /// a tile of the frame stands: the section fills the viewport and may leave
    /// nothing standing but the bars. A false "stationary" is neither blank nor
    /// stands on three tiles, so it never makes such a pair.
    static func outcome(decidedStationary: Bool, undecided: Bool, changed: Bool,
                        afterReliableSteps: Bool, mode: Mode) -> Outcome {
        if decidedStationary { return .stationary(changed: changed) }
        if sendsPush(mode), afterReliableSteps, undecided, changed { return .stationary(changed: true) }
        return .other
    }

    /// Whether `outcome` took a step that the decision had refused as stationary.
    static func acceptsWithoutStandingTiles(decidedStationary: Bool, undecided: Bool, changed: Bool,
                                            afterReliableSteps: Bool, mode: Mode) -> Bool {
        !decidedStationary && outcome(decidedStationary: false, undecided: undecided, changed: changed,
                                      afterReliableSteps: afterReliableSteps, mode: mode) != .other
    }

    /// Whether a frame whose difference from the one it is compared with is
    /// `difference` has changed.
    static func isChanged(_ difference: Double) -> Bool {
        difference >= changedFrom
    }

    /// What a push is compared with to see whether it changed anything: the
    /// last frame decided as stationary, when there is one — the question is
    /// whether the push did something, and the page can differ from the frame
    /// kept by a little all the same, steadily, at the end of a page. In a
    /// section, and after a quiet push, the frame before the step is the one kept.
    static func comparesWithStationaryFrame(mode: Mode, haveStationaryFrame: Bool) -> Bool {
        mode == .push && haveStationaryFrame
    }

    /// How many pushes a section has had so far.
    static func pushes(in mode: Mode) -> Int {
        if case .section(let pushes) = mode { return pushes }
        return 0
    }

    /// The pushes have reached the limit with nothing placed.
    static func isExhausted(_ mode: Mode) -> Bool {
        if case .section(let pushes) = mode { return pushes >= limit }
        return false
    }
}

/// When a capture that makes no headway is saved. There is no limit on how long
/// a capture may take — a long page is a long capture, and the length the
/// settings allow is the only cap — but a capture that adds nothing for this
/// long is going round in circles, or the page has nothing more to give.
///
/// Headway is a step laid into the image, steps laid from the waiting queue,
/// or a step put in the queue by the calibration: a long video section, eight
/// steps of two or three seconds, is the capture working, not stuck. Time spent
/// paused, or waiting for the pointer, is not time without progress.
nonisolated enum ScrollProgressTimeout {
    static let seconds: TimeInterval = 20

    /// Whether it is time to save: the seconds since the last headway, less
    /// those spent paused or waiting for the pointer in between (`idle`).
    static func isOver(lastProgress: Date, now: Date, idle: TimeInterval) -> Bool {
        now.timeIntervalSince(lastProgress) - max(0, idle) >= seconds
    }
}
