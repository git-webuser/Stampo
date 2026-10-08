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
        /// The matcher gave up with "no reliable motion" or "ambiguous" — as
        /// opposed to finding the page moving across, say.
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
        /// Tiles standing still with something in them that are not known to
        /// be fixed to the viewport.
        var unpinnedStanding: Int
        /// Steps already waiting.
        var queued: Int
    }

    /// The stop is proved by a tile with content that stands still and is not
    /// one of those fixed to the viewport, while none of the tiles bears out
    /// that the page moved. A blank frame, a frame that is one video, a frame
    /// whose only standing tiles are the site's bar are no proof: the bar stands
    /// at every step.
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
    }

    private(set) var steps: [Step] = []

    var count: Int { steps.count }
    var isEmpty: Bool { steps.isEmpty }

    mutating func add(_ frame: CaptureFrame, movement: Int, confirmed: Bool) {
        steps.append(Step(frame: frame, movement: movement, confirmed: confirmed))
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
