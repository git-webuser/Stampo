import Foundation

/// Where the page is, after a pause, compared with the last frame collected.
nonisolated enum ScrollPlaceFinding: Equatable {
    /// Where it was.
    case same
    /// Further on than the last frame by this many pixels — what a pause in the
    /// middle of a step leaves, and what a user who scrolled down leaves.
    case ahead(Int)
    /// Back from the last frame by this many pixels.
    case behind(Int)
    /// The frames say nothing: the page has gone further than they overlap, or
    /// what they show has changed too much.
    case unknown

    /// The page `now` against the page `last`: matched as a step forward, as a
    /// step back, and failing both, whether what stands still in both says it
    /// is the same place.
    static func find(last: CaptureFrame, now: CaptureFrame, axis: ScrollAxis) -> ScrollPlaceFinding {
        let axisLength = axis == .vertical ? last.height : last.width
        let limit = axisLength * 3 / 4
        if let forward = try? FrameMatcher.match(previous: last, current: now, axis: axis, maximumOffset: limit) {
            return .ahead(forward.offset)
        }
        if let back = try? FrameMatcher.match(previous: now, current: last, axis: axis, maximumOffset: limit) {
            return .behind(back.offset)
        }
        let standing = FrameMatcher.evidence(previous: last, current: now, axis: axis, offset: nil, searchLimit: 2)
            .standing
        return standing.count >= 3 ? .same : .unknown
    }
}

/// How a capture finds its place again after a pause.
nonisolated enum ScrollResume {
    enum Action: Equatable {
        /// Where it was: go on.
        case goOn
        /// Further on: the frame now is the next one, this far along.
        case lay(movement: Int)
        /// Back: scroll on by this many pixels to where it was.
        case scrollForward(pixels: Int)
        /// The frames cannot tell: undo what the user did, by this many pixels
        /// (positive: they scrolled toward the end, so it goes back).
        case undoUser(pixels: Int)
        /// Not to be found: save what is collected.
        case giveUp
    }

    /// Whether the page may have moved while the capture was not looking: the
    /// user scrolled, pressed a key or clicked, or the pause cut a step short
    /// after its wheel event was sent. If not, it is where it was and there is
    /// nothing to look for.
    static func needsLooking(ledger: UserScrollLedger, stepWasInFlight: Bool) -> Bool {
        ledger.mayHaveMovedPage || stepWasInFlight
    }

    /// The next move, from what the frames say and what the user did. The
    /// user's scrolls are undone once, and only if the frames could not say.
    static func action(finding: ScrollPlaceFinding, userMovement: Int, undone: Bool) -> Action {
        switch finding {
        case .same:             return .goOn
        case .ahead(let by):    return .lay(movement: by)
        case .behind(let by):   return .scrollForward(pixels: by)
        case .unknown:
            guard !undone, userMovement != 0 else { return .giveUp }
            return .undoUser(pixels: userMovement)
        }
    }

    /// Wheel lines for a distance: as many as measured for a line, or, with no
    /// measure, a line of 80 points.
    static func lines(forPixels pixels: Int, pixelsPerLine: Double?, scale: CGFloat) -> Int {
        let line = pixelsPerLine ?? 80 * Double(scale)
        guard line > 0 else { return 0 }
        return Int((Double(abs(pixels)) / line).rounded())
    }

    /// A long scroll goes in wheel events of at most this many lines each.
    static let linesPerEvent: Int32 = 10
}
