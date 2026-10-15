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
        /// The frame is the same as the one kept (`ScrollPush.changedFrom`).
        var frameUnchanged = false
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
        // A frame the same as the last, after the wheel turned: the page did not
        // move. No tile need stand to prove it — the bars of a footer may be all
        // that stands, and are pinned — and a step that was queued in its place
        // would be laid down in the image at a distance the page did not go.
        if evidence.frameUnchanged { return .stationary }
        if evidence.unpinnedStanding >= 1, evidence.consistent == 0 { return .stationary }
        guard evidence.canExpect, !evidence.contradicted else { return .retry }
        if evidence.queued >= TemporarySteps.limit { return .finish }
        if evidence.consistent >= evidence.required { return .temporary(confirmed: true) }
        return evidence.against == 0 ? .temporary(confirmed: false) : .retry
    }
}

/// A queue that grows while the matcher places no step: what is tried before it fills up and the capture ends.
nonisolated enum ScrollQueueLaying {
    /// With this many steps waiting, the next step is a short one.
    static let shortStepAfter = 4

    /// Whether the next step is half as long as the others. Frames that the matcher cannot read at one distance
    /// sometimes read at a shorter one (2026-10-13-210141 matched at 4 lines what 7 had not), and a short step costs
    /// a few frames more, not the page. Once for a queue, and only when the calibration is confirmed: a short step
    /// from a calibration that is not might be one the queue is laid by.
    static func shortStepDue(waiting: Int, calibrationConfirmed: Bool, tried: Bool) -> Bool {
        waiting >= shortStepAfter && calibrationConfirmed && !tried
    }

    // MARK: A full queue

    /// How many of a full queue's steps must be confirmed by the tiles.
    static let minimumConfirmed = 6
    /// Two frames are the same when they differ, per channel, by less than this with no shift.
    static let identicalBelow = 0.5
    /// Over all the pairs of the queue, the difference at the shifts the calibration gives must be under this share of
    /// the difference with none.
    static let shiftedShare = 0.8
    /// Fewer samples than this say nothing.
    static let minimumSamples = 300

    /// How well the frame `current` fits the frame `previous` shifted by `offset` along a vertical scroll, and how
    /// well with no shift: the mean difference per channel over a sample of the pixels, leaving out the tiles that
    /// are pinned in either frame (the card that stands still would otherwise be compared with the page where the
    /// shift puts it). Nil when too little is left to compare.
    struct PairCost: Equatable, Sendable {
        let shifted: Double
        let still: Double

        var identical: Bool { still < ScrollQueueLaying.identicalBelow }
        var better: Bool { shifted < still }
    }

    static func pairCost(previous: CaptureFrame, current: CaptureFrame, offset: Int,
                         pinnedTiles: Set<Int>) -> PairCost? {
        let h = previous.height, w = previous.width
        guard current.width == w, current.height == h, offset > 0 else { return nil }
        // The last rows may show what the browser draws over the page.
        let limit = min(h - offset - 4, h - 56)
        guard limit > 4, w > 8 else { return nil }
        let tileRows = FrameMatcher.tileRows, tileColumns = FrameMatcher.tileColumns
        var still = 0, shifted = 0, samples = 0
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                for y in stride(from: 4, to: limit, by: 4) {
                    let row = y * tileRows / h, sourceRow = (y + offset) * tileRows / h
                    for x in stride(from: 4, to: w - 4, by: 6) {
                        let column = x * tileColumns / w
                        if pinnedTiles.contains(row * tileColumns + column)
                            || pinnedTiles.contains(sourceRow * tileColumns + column) { continue }
                        let i = (y * w + x) * 4, j = ((y + offset) * w + x) * 4
                        for channel in 0..<3 {
                            let value = Int(now[i + channel])
                            still += abs(value - Int(before[i + channel]))
                            shifted += abs(value - Int(before[j + channel]))
                        }
                        samples += 3
                    }
                }
            }
        }
        guard samples >= minimumSamples else { return nil }
        return PairCost(shifted: Double(shifted) / Double(samples), still: Double(still) / Double(samples))
    }

    /// What is known when the queue is full and the next step cannot be placed either.
    struct QueueEvidence: Sendable {
        /// Matched steps have borne out that lines move the page in proportion (`linearityConfirmed`).
        var calibrationConfirmed: Bool
        /// Which of the waiting steps the tiles confirmed.
        var queueConfirmed: [Bool]
        /// Whether the step that finds the queue full is confirmed, and whether the frames contradict its distance.
        var currentConfirmed: Bool
        var contradicted: Bool
        /// One per pair of neighbouring frames, from the last frame laid through the waiting ones to the current:
        /// `queueConfirmed.count + 1` of them.
        var pairs: [PairCost?]
        /// A queue was already laid by the calibration since the last step the matcher placed.
        var laidSinceMatch: Bool
    }

    /// Whether to lay a full queue by the calibration and go on, rather than save what there is. It is: the
    /// calibration is borne out by matched steps; at least `minimumConfirmed` of the waiting steps and the current
    /// one are confirmed by the tiles and none is contradicted; the page moved in the queue; and no queue was laid
    /// this way since the last step the matcher placed.
    /// The page moved where that can be looked at: in no pair are the frames the same, in every pair of confirmed
    /// frames the frames fit at the shift better than with none, and over all the pairs the fit at the shifts is
    /// well under that with none. A frame that changed as a whole (the stage of a section) says nothing for or
    /// against, and a pair with it is not looked at one by one. A page that stood while a pattern repeated
    /// (2026-10-10-003948: the same frame, eight times) fails all of this.
    static func shouldLay(_ evidence: QueueEvidence) -> Bool {
        guard evidence.calibrationConfirmed, !evidence.laidSinceMatch, evidence.currentConfirmed,
              !evidence.contradicted,
              evidence.pairs.count == evidence.queueConfirmed.count + 1,
              evidence.queueConfirmed.filter({ $0 }).count >= minimumConfirmed
        else { return false }
        // The last frame laid was placed by the matcher: confirmed.
        let confirmed = [true] + evidence.queueConfirmed + [evidence.currentConfirmed]
        var shifted = 0.0, still = 0.0
        for (index, pair) in evidence.pairs.enumerated() {
            guard let pair, !pair.identical else { return false }
            if confirmed[index] && confirmed[index + 1] && !pair.better { return false }
            shifted += pair.shifted
            still += pair.still
        }
        return shifted < shiftedShare * still
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
        /// The pinned blocks of the pair of this frame and the one before it
        /// (`ScrollPinned`), worked out when it was kept; nil when they could not be.
        let pinned: PinnedGrid?
    }

    private(set) var steps: [Step] = []

    var count: Int { steps.count }
    var isEmpty: Bool { steps.isEmpty }

    mutating func add(_ frame: CaptureFrame, movement: Int, confirmed: Bool, lines: Int32? = nil,
                      stationaryLines: Int32 = 0, pinned: PinnedGrid? = nil) {
        steps.append(Step(frame: frame, movement: movement, confirmed: confirmed, lines: lines,
                          stationaryLines: stationaryLines, pinned: pinned))
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

    /// A line that differs from the calibration by more than this is a new
    /// calibration, not the old one a little off.
    static let smallChange = 0.15

    /// The tiles it takes to overturn a calibration: three are too few to say
    /// that a line is not what the steps before it showed. Under this the queue
    /// stays as it was laid, as it did before it could be laid again.
    /// 2026-10-13-190147: three tiles against two moved a queue frame from 640 px
    /// to 404 and the lines after it went by a line of 51 px where the page gives
    /// 80; of the fourteen queues laid again in all the recordings, the others
    /// had six tiles or more.
    static let tilesToOverturn = 5

    /// Lay the queue again at the new distances when more tiles agree with
    /// them than with the old: strictly more, so that a tie leaves things as
    /// they are — and, when the new line is not the calibration a little off,
    /// when at least `tilesToOverturn` of them do. Near the end of a page the
    /// last step is short because the page ended, not because a line is
    /// shorter, and the tiles then keep the old.
    static func shouldRelay(tilesOld: Int, tilesNew: Int, newLine: Double, currentLine: Double?) -> Bool {
        guard tilesNew > tilesOld else { return false }
        guard let currentLine, currentLine > 0, abs(newLine / currentLine - 1) > smallChange else { return true }
        return tilesNew >= tilesToOverturn
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

/// A calibration that the steps themselves contradict, with no queue to say so.
/// The probe of one line can land on something that moves faster than the page
/// — a floating card — and give a line twice as long as the page's. Steps the
/// matcher places firmly and that the calibration does not predict are then the
/// evidence, and one is not enough, a parallax card can place a step too; two in
/// a row that agree with each other are. (When steps wait in the queue,
/// `ScrollQueueRelay` has it from their frames.)
nonisolated enum ScrollRecalibration {
    enum Action: Equatable {
        /// This step's line, kept to see whether the next step agrees with it.
        case remember(Double)
        /// Two steps in a row agree: the calibration is this line.
        case recalibrate(Double)
        /// Nothing to go on: forget what was kept.
        case forget
    }

    /// How far a new line may be from the current calibration and still be
    /// believed: between 0.4 and 2.5 times it. A probe on a floating card gave
    /// 138 px to a line where the page gives 80 (0.58 times); a step placed wrongly
    /// gave 16 (0.11 times) and broke the capture.
    static let plausibleRatio: ClosedRange<Double> = 0.4...2.5

    static func isPlausible(newLine: Double, current: Double) -> Bool {
        current > 0 && plausibleRatio.contains(newLine / current)
    }

    /// For the line of a step: what was refused and by how much.
    static func refusal(newLine: Double, current: Double) -> String {
        "recalibration refused (\(Int(newLine.rounded())) px/line, ×\(String(format: "%.2f", current > 0 ? newLine / current : 0)))"
    }

    /// What a step placed by the matcher makes of what is kept. `qualifies`: it
    /// is a clean step of the capture's own — not a push, none of the steps
    /// before it decided as stationary — placed firmly (`ScrollQueueRelay.isFirm`),
    /// and there is a calibration to contradict. `confirmsCalibration`: the
    /// calibration predicts its distance, which settles it the other way. The
    /// two steps agree as a step and a calibration do for `confirmsLinearity`:
    /// within two pixels or two percent.
    static func next(remembered: Double?, offset: Int, lines: Int,
                     qualifies: Bool, confirmsCalibration: Bool) -> Action {
        guard qualifies, !confirmsCalibration,
              let line = ScrollStepPlanner.pixelsPerLine(offset: offset, lines: lines)
        else { return .forget }
        if let remembered,
           ScrollStepPlanner.confirmsLinearity(offset: offset, lines: lines, pixelsPerLine: remembered) {
            return .recalibrate(line)
        }
        return .remember(line)
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
/// A push that changes the frame and is not placed may be that, or the page
/// going past a whole frame at once — the wheel went to a box with a scroll of
/// its own until it ended, then to the page. An ordinary step from the push's
/// frame tells them apart (`afterCheck`): a section does not move the page for
/// it either; a page moves.
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
        /// A push changed the frame and was not placed, `pushes` so far, this
        /// one included. The next step is an ordinary one, from the push's
        /// frame, and it says what the change was (`afterCheck`): a pinned
        /// section passing to its next stage leaves the page where it is, and
        /// that step does not move it either; a page that the push took past
        /// more than a frame — the wheel went to a box with a scroll of its own
        /// until it ended, then to the page — goes on as usual under it.
        case check(pushes: Int)
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
        /// The push changed the frame and nothing placed it: an ordinary step
        /// from its frame comes before the frame goes into the image.
        case check
        /// The page moves under the push: it went past content. Nothing is
        /// replaced, the page goes back, and no push is sent until a frame is laid.
        case undo
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
        case .none, .settle, .check: return false
        }
    }

    /// The step after the second in a row that proved the page stood is a
    /// push — with steps waiting, as ever, a third of those ends the capture.
    /// Not once a check has found the page going on under a push, until a frame
    /// is laid: `allowed`.
    static func startsPush(zeroMotionCount: Int, queueIsEmpty: Bool, allowed: Bool = true) -> Bool {
        zeroMotionCount == 2 && queueIsEmpty && allowed
    }

    static func next(mode: Mode, outcome: Outcome) -> Step {
        guard case .stationary(let changed) = outcome else { return Step(action: .proceed, mode: .none) }
        switch mode {
        case .none:
            return Step(action: .count, mode: .none)
        case .push:
            return changed ? Step(action: .check, mode: .check(pushes: 1))
                           : Step(action: .end, mode: .none)
        case .section(let pushes):
            return changed ? Step(action: .check, mode: .check(pushes: pushes + 1))
                           : Step(action: .hold, mode: .settle)
        case .check:
            // The step after a push is decided by `afterCheck`.
            return Step(action: .proceed, mode: .none)
        case .settle:
            return changed ? Step(action: .count, mode: .none)
                           : Step(action: .end, mode: .none)
        }
    }

    /// What the step after a push that changed the frame comes to, `mode` being
    /// `.check`. When the page moves under it, the push went past content that
    /// no frame has: nothing is replaced, and the page goes back. Otherwise the
    /// page stood and the section changed its stage: the frame replaces the last
    /// one laid, and the pushes go on as in a section.
    static func afterCheck(mode: Mode, movesPage: Bool) -> Step {
        guard case .check(let pushes) = mode else { return Step(action: .proceed, mode: .none) }
        return movesPage ? Step(action: .undo, mode: .none)
                         : Step(action: .replace, mode: .section(pushes: pushes))
    }

    /// Whether the step after a push shows the page going on: the matcher placed
    /// it, or the tiles of its frames bear out the distance it was sent for.
    /// Anything else — tiles standing, nothing agreeing, nothing against, no
    /// way to tell — is a page that stood.
    static func movesPage(placed: Bool, decision: ScrollStepDecision) -> Bool {
        placed || decision == .temporary(confirmed: true)
    }

    /// Which frame the section's stage is: the check's own if it changed after
    /// the push — the section went on to a later stage — else the push's.
    static func stageFrameIsChecks(differenceFromPush: Double) -> Bool {
        isChanged(differenceFromPush)
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

    /// What a step came to when the page stood for two steps before it. A push the
    /// matcher could not place whose frame changed is checked, whether or not a
    /// tile of the frame stands: a section fills the viewport and may leave
    /// nothing standing but the bars. Whether the two steps before it were ones
    /// to rely on (`isReliableStep`) does not matter: the check step tells a
    /// section from a page that moved all the same, and a false "stationary"
    /// is caught by it, not by the tiles of the push.
    static func outcome(decidedStationary: Bool, undecided: Bool, changed: Bool, mode: Mode) -> Outcome {
        if decidedStationary { return .stationary(changed: changed) }
        if sendsPush(mode), undecided, changed { return .stationary(changed: true) }
        return .other
    }

    /// Whether `outcome` took a step that the decision had refused as stationary.
    static func acceptsWithoutStandingTiles(decidedStationary: Bool, undecided: Bool, changed: Bool,
                                            mode: Mode) -> Bool {
        !decidedStationary && outcome(decidedStationary: false, undecided: undecided, changed: changed,
                                      mode: mode) != .other
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

    /// The tiles of the grid (`ScrollStillness`) that changed: the ones whose difference between two frames is
    /// `ScrollStillness.stillBelow` or more. Nothing when the frames could not be told apart tile by tile.
    static func changedTiles(_ tileDifferences: [Double]?) -> Set<Int> {
        guard let tileDifferences else { return [] }
        return Set(tileDifferences.indices.filter { tileDifferences[$0] >= ScrollStillness.stillBelow })
    }

    /// How many tiles outside `ownMotion` have changed.
    static func tilesChanged(outside ownMotion: Set<Int>, in tileDifferences: [Double]) -> Int {
        tileDifferences.indices.filter { !ownMotion.contains($0) && tileDifferences[$0] >= ScrollStillness.stillBelow }.count
    }

    /// Whether a push changed the frame anywhere but in the tiles that change by themselves, `ownMotion` — a
    /// small animation at the end of a list (an animated WebP in the preview column of Finder) differs from the
    /// frame that stood by a little each time, with no push. A section's stage changes more than that: the
    /// heading, the mark of the hour, the colour of a card. Nil when the tiles cannot say: there are no
    /// differences, or half of the frame and more moves by itself (a video, an animation across the frame), and
    /// the frame as a whole is judged as before. Otherwise, yes when a tile outside `ownMotion` has changed, or
    /// the frame outside it differs by `changedFrom` on the mean (a change that is spread thin).
    static func changedBesidesOwnMotion(push tileDifferences: [Double]?, ownMotion: Set<Int>) -> Bool? {
        guard let tileDifferences, ownMotion.count <= ScrollStillness.grid * ScrollStillness.grid / 2 else { return nil }
        var total = 0.0, outside = 0
        for (tile, difference) in tileDifferences.enumerated() where !ownMotion.contains(tile) {
            if difference >= ScrollStillness.stillBelow { return true }
            total += difference
            outside += 1
        }
        guard outside > 0 else { return false }
        return isChanged(total / Double(outside))
    }

    /// How many pushes a section has had so far.
    static func pushes(in mode: Mode) -> Int {
        switch mode {
        case .section(let pushes), .check(let pushes): return pushes
        case .none, .push, .settle: return 0
        }
    }

    /// The pushes have reached the limit with nothing placed.
    static func isExhausted(_ mode: Mode) -> Bool {
        if case .section(let pushes) = mode { return pushes >= limit }
        return false
    }
}

/// The last frame decided as stationary since a frame was kept, with the tiles of the frame that changed while
/// the page stood (its own motion): what a push is compared with (`ScrollPush.changedBesidesOwnMotion`). One value,
/// so that the motion goes where the frame does, and the places that forget the frame forget it too.
nonisolated struct StationaryFrame: Sendable {
    let frame: CaptureFrame
    /// The tiles of the grid that changed between the frames of the steps decided as stationary.
    let ownMotion: Set<Int>

    init(frame: CaptureFrame, ownMotion: Set<Int> = []) {
        self.frame = frame
        self.ownMotion = ownMotion
    }

    /// What stands after a step decided as stationary: `next`, and the tiles that changed in it from the frame
    /// kept and from the frame that stood, added to the motion of the steps before.
    static func after(step next: CaptureFrame, kept: CaptureFrame, previous: StationaryFrame?) -> StationaryFrame {
        var motion = previous?.ownMotion ?? []
        motion.formUnion(ScrollPush.changedTiles(ScrollStillness.tileDifferences(kept, next)))
        if let previous {
            motion.formUnion(ScrollPush.changedTiles(ScrollStillness.tileDifferences(previous.frame, next)))
        }
        return StationaryFrame(frame: next, ownMotion: motion)
    }
}

/// Where the page is after it was sent back to a frame that is kept — a retry's
/// half step, a push undone. The wheel back does not always bring it all the
/// way: a section that pinned the page and let it go, a box with a scroll of its
/// own, a page that glides on. A page that has come back is the frame kept, or
/// near enough that the next step finds it; one that is further on is not within
/// reach of a step sent from the frame kept — the step is looked for at its own
/// distance from that frame, and the distance the page went too far is outside
/// the window of the search — and what it shows, in 2026-10-11-235202 a dock
/// and the start of a quotation, is lost.
nonisolated enum ScrollReturn {
    enum Landing: Equatable {
        /// The frame is the one returned to, as far as a thousandth of a frame.
        case same
        /// The matcher places it this many pixels further along than the frame
        /// returned to: real content, to be laid as a step of its own.
        case further(Int)
        /// Anything else: it differs and is not placed, or is placed behind. As
        /// before — the next step places itself from the frame kept. A page
        /// behind the frame kept is within its reach, and of the 16 frames in
        /// the recordings that differed and were not placed, 7 were followed by a
        /// step the matcher placed all the same; a frame that differs by an
        /// animation or a panel that moved is not a page that stayed away.
        case elsewhere
    }

    /// `forward`: the distance the matcher places the frame after the return
    /// further along than the frame returned to, nil when it does not place it
    /// (or places it behind).
    static func landing(difference: Double, forward: Int?) -> Landing {
        guard ScrollPush.isChanged(difference) else { return .same }
        guard let forward, forward > 0 else { return .elsewhere }
        return .further(forward)
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
