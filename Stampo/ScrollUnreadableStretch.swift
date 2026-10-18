/// A stretch of the page that no step can read: a section that pins the page
/// and plays a motion of its own under the wheel (lenis.dev, "SO WE BUILT WEB
/// SCROLLING AS IT SHOULD BE"). The matcher finds no shift, the tiles bear out
/// no distance, and the capture would end with the queue still unread or with
/// the page seeming to stand. The capture takes what it has instead — up to
/// three of the frames waiting, laid edge to edge — and scrolls on in jerks,
/// which pass a pinned section (`ScrollPush`), until a step can be placed.
/// Content between the frames, and the section itself, may be lost or shown
/// twice: a screenshot that goes on is more than one that stops.
nonisolated struct ScrollUnreadableStretch: Sendable {
    /// Frames laid edge to edge for one stretch, at most.
    static let seriesLimit = 3
    /// Stretches one capture meets, at most: past that the page is one this
    /// cannot get through.
    static let stretchLimit = 6
    /// Jerks in a row after a stretch, at most, before ordinary steps go on from
    /// the last frame laid.
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

    private(set) var stretches = 0
    private(set) var jerks = 0
    private(set) var isJerking = false

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
        guard situation.isVertical, !situation.galleryActive, !situation.pushing, !isJerking,
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
        isJerking = true
    }

    /// A jerk that the matcher could not place. Whether the jerks go on.
    @discardableResult
    mutating func jerkNotPlaced() -> Bool {
        guard isJerking else { return false }
        jerks += 1
        if jerks >= Self.jerkLimit { isJerking = false }
        return isJerking
    }

    /// A step was placed: the page reads again, and the way goes on as usual.
    mutating func placed() {
        isJerking = false
        jerks = 0
    }
}
