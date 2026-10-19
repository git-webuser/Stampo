/// A stretch of the page that no step can read: a section that pins the page
/// and plays a motion of its own under the wheel (lenis.dev, "SO WE BUILT WEB
/// SCROLLING AS IT SHOULD BE"). The matcher finds no shift, the tiles bear out
/// no distance, and the capture would end with the queue still unread or with
/// the page seeming to stand. The capture takes what it has instead — up to
/// three of the frames waiting, laid edge to edge — and scrolls on in jerks,
/// which pass a pinned section (`ScrollPush`), until a step can be placed.
/// A jerk is longer than the matcher looks (three quarters of a frame), so one
/// that is not placed is followed by an ordinary step, the check: if the page
/// moves in it, the jerk's frame is laid edge to edge and the way goes on from
/// the check's; if not, the jerk only changed the section's stage.
/// Content between the frames, and the section itself, may be lost or shown
/// twice: a screenshot that goes on is more than one that stops.
nonisolated struct ScrollUnreadableStretch: Sendable {
    /// Frames laid edge to edge for one stretch, at most.
    static let seriesLimit = 3
    /// Stretches one capture meets, at most: past that the page is one this
    /// cannot get through.
    static let stretchLimit = 6
    /// Jerks in a row after a stretch whose check shows the page standing, at
    /// most, before ordinary steps go on from the last check's frame.
    static let jerkLimit = 4
    /// The mean difference from the last frame laid from which a frame is
    /// another screen. A page that ends in its last frames, with a cursor or an
    /// animation at work in them, differs from the frame before by a few
    /// thousandths (claude.com 2026-10-14-214945: 0.006; the sideways
    /// 2026-10-10-003948: 0.019) and has nothing to lay; the stretches of the
    /// recordings differ by 0.07 and more.
    static let differentFrom = 0.04

    static func isAnotherScreen(difference: Double) -> Bool {
        difference >= differentFrom
    }

    /// What the next step is.
    enum Phase: Equatable, Sendable {
        /// Ordinary steps.
        case off
        /// A jerk, from the last frame laid or the last check's.
        case jerk
        /// An ordinary step from the frame of a jerk that was not placed.
        case check
    }

    private(set) var stretches = 0
    /// Jerks of this stretch whose check showed the page standing.
    private(set) var jerks = 0
    private(set) var phase = Phase.off

    var isJerking: Bool { phase == .jerk }
    var isChecking: Bool { phase == .check }

    enum Trigger: Equatable, Sendable {
        /// The queue is full and the step cannot be placed either.
        case queueFull(queued: Int)
        /// The page was decided to stand `count` steps in a row, with `queued`
        /// steps waiting that nothing placed.
        case standing(count: Int, queued: Int)
        /// The step on which a page that stands ends the capture.
        static let endingCount = 3
    }

    struct Situation: Sendable {
        var trigger: Trigger
        var isVertical: Bool
        /// A sideways gallery is latched: it has its own way out of a queue.
        var galleryActive: Bool
        /// A push, or the check of one, is under way.
        var pushing: Bool
        /// The newest frame is another screen than the last one laid
        /// (`isAnotherScreen`): a page that stands in the same frames has
        /// nothing to lay.
        var framesChange: Bool
        /// The newest frame is one the capture has seen before and left.
        var isRepeat: Bool
    }

    enum Decision: Equatable, Sendable {
        /// Lay a series edge to edge and scroll on in jerks.
        case series
        /// As ever: the capture ends with what it has.
        case save
        /// It would be a stretch too many.
        case tooMany
    }

    func decide(_ situation: Situation) -> Decision {
        guard situation.isVertical, !situation.galleryActive, !situation.pushing, phase == .off,
              situation.framesChange, !situation.isRepeat
        else { return .save }
        switch situation.trigger {
        case .queueFull(let queued):
            guard queued >= TemporarySteps.limit else { return .save }
        case .standing(let count, let queued):
            // Only the step that would end the capture. At the second the page
            // may still go on: 2026-10-13-190147 step 11, 2026-10-14-194340
            // step 15, both read to the end.
            guard count >= Trigger.endingCount, queued >= 1 else { return .save }
        }
        return stretches >= Self.stretchLimit ? .tooMany : .series
    }

    /// Which of `count` frames, oldest first, go into the series: the first, a
    /// middle one and the last, or all of them when there are no more than
    /// `seriesLimit`; a frame that shows the same page as one already taken, or
    /// as the last frame laid (`same(-1, index)`), is left out.
    static func series(count: Int, same: (Int, Int) -> Bool) -> [Int] {
        guard count > 0 else { return [] }
        let candidates = count <= seriesLimit ? Array(0..<count) : [0, count / 2, count - 1]
        var taken: [Int] = []
        var shown = [-1]
        for index in candidates where !shown.contains(where: { same($0, index) }) {
            taken.append(index)
            shown.append(index)
        }
        return taken
    }

    /// A series is laid: the next steps are jerks.
    mutating func begin() {
        stretches += 1
        jerks = 0
        phase = .jerk
    }

    /// A jerk that the matcher could not place: the next step checks whether
    /// the page moved in it.
    mutating func jerkNotPlaced() {
        guard phase == .jerk else { return }
        phase = .check
    }

    enum Check: Equatable, Sendable {
        /// The page went on: the jerk's frame is part of the page, and the way
        /// goes on as usual.
        case moves
        /// The page stood: the jerk changed the section's stage. The next jerk
        /// goes from the check's frame.
        case stands
        /// The page stood for `jerkLimit` jerks: the way goes on as usual from
        /// the check's frame, which is laid if it is another screen.
        case ceiling
    }

    /// What the check made of the jerk before it. `movesPage` as in a push's
    /// check (`ScrollPush.movesPage`): the matcher placed the step, or the
    /// tiles bore out its distance.
    @discardableResult
    mutating func checked(movesPage: Bool) -> Check {
        guard phase == .check else { return .stands }
        if movesPage {
            phase = .off
            jerks = 0
            return .moves
        }
        jerks += 1
        if jerks >= Self.jerkLimit {
            phase = .off
            return .ceiling
        }
        phase = .jerk
        return .stands
    }

    /// What follows a check, as `checked`, told by what the step came to.
    enum AfterCheck: Equatable, Sendable {
        /// The matcher placed it: the jerk's frame is laid, then the check at its distance.
        case jerkThenPlaced
        /// Only the tiles bore out its distance: the jerk's frame is laid, and
        /// the check waits as a step that was confirmed.
        case jerkThenConfirmed
        /// The page stood: the next jerk goes from the check's frame.
        case nextJerk
        /// The page stood through the last jerk: the check's frame is where the
        /// way goes on from.
        case ceiling
    }

    /// A check that the matcher placed (`decision` nil) or did not, `decision`
    /// being what the tiles said of it. Moving is decided as after a push
    /// (`ScrollPush.movesPage`); a second look that placed the step is placed.
    /// The proof that the page stood is the tiles of one pair, the jerk's frame
    /// and the check's. When the jerk's frame is a page the capture has left
    /// (`jerkRepeats`), the page may have moved, but the check cannot be laid
    /// after it — the image ends in another frame — and the way goes on as if
    /// it stood.
    @discardableResult
    mutating func afterCheck(placed: Bool, decision: ScrollStepDecision?,
                             jerkRepeats: Bool = false) -> AfterCheck {
        let moves = ScrollPush.movesPage(placed: placed, decision: decision ?? .retry) && !jerkRepeats
        switch checked(movesPage: moves) {
        case .moves: return placed ? .jerkThenPlaced : .jerkThenConfirmed
        case .stands: return .nextJerk
        case .ceiling: return .ceiling
        }
    }

    /// What a jerk's frame is to the image, once a check has shown the page going on.
    enum JerkFrame: Equatable, Sendable {
        /// Another screen: it is laid edge to edge, and the check goes on after it.
        case lay
        /// What the last frame laid shows: nothing to lay, and the check goes on after that frame.
        case thePageLaid
        /// A page the capture has left: neither it nor the check can be laid, for the
        /// check's distance is from a frame that the image does not end in.
        case repeatsPageLeft
    }

    static func jerkFrame(anotherScreen: Bool, isRepeat: Bool) -> JerkFrame {
        guard anotherScreen else { return .thePageLaid }
        return isRepeat ? .repeatsPageLeft : .lay
    }

    /// A frame of a jerk or of the way after it goes into the image, edge to
    /// edge, only if it shows another screen than the last frame laid and no
    /// page the capture has left: otherwise the page has not gone anywhere.
    static func laysFrame(anotherScreen: Bool, isRepeat: Bool) -> Bool {
        anotherScreen && !isRepeat
    }

    /// A step was placed: the page reads again, and the way goes on as usual.
    mutating func placed() {
        phase = .off
        jerks = 0
    }
}
