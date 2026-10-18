/// A sideways match establishes the gallery. Its row structure may then keep
/// it latched through video frames until a vertical append places the page.
nonisolated struct ScrollSidewaysSection: Sendable {
    static let limit = 24
    static let queuedStageLimit = 2
    private(set) var stages = 0
    private var history: CaptureFrame?
    private var latest: CaptureFrame?

    var isActive: Bool { stages > 0 }
    var isExhausted: Bool { stages >= Self.limit }

    enum Stage: Equatable, Sendable {
        case sideways(FrameMatch)
        case standing

        var note: String {
            switch self {
            case .sideways(let match): return "sideways \(match.offset) px"
            case .standing: return "standing"
            }
        }
    }

    enum Entry: Equatable {
        case replace
        case lay(Int)
    }

    static func canInspect(axis: ScrollAxis, verticalUndecided: Bool, isPush: Bool, expected: Int?,
                           calibrationConfirmed: Bool, frameChanged: Bool, contradicted: Bool,
                           pushMode: ScrollPush.Mode, checking: Bool) -> Bool {
        axis == .vertical && verticalUndecided && !isPush && expected != nil && calibrationConfirmed
            && frameChanged && !contradicted && pushMode == .none && !checking
    }

    func canContinue(axis: ScrollAxis, verticalUndecided: Bool, isPush: Bool,
                     frameChanged: Bool, pushMode: ScrollPush.Mode, checking: Bool) -> Bool {
        isActive && axis == .vertical && verticalUndecided && !isPush
            && frameChanged && pushMode == .none && !checking
    }

    func entry(queueIsEmpty: Bool, calibrationConfirmed: Bool, expected: Int?) -> Entry? {
        if isActive { return .replace }
        guard calibrationConfirmed, let expected else { return nil }
        return queueIsEmpty ? .replace : .lay(expected)
    }

    /// Raw sideways matches can enter even beside vertical votes. The costly
    /// filter is only needed without that support, or to keep a gallery latched.
    func needsFilteredSearch(consistent: Int, required: Int) -> Bool {
        isActive || consistent < required
    }

    /// A horizontal match measures its own displacement. Filter only after a
    /// raw refusal, at four physical pixels, leaving vertical second look alone.
    /// `queued` are the frames that wait behind the laid gallery, the last of
    /// them `previous`: what a stage found through them would discard.
    func inspect(previous: CaptureFrame, current: CaptureFrame, expected: Int?,
                 consistent: Int, required: Int, queued: [CaptureFrame] = []) -> Stage? {
        let throughQueue = isActive && !queued.isEmpty
        if throughQueue {
            // Tiles that bear out the vertical step make the queue a real exit,
            // and a long queue is more than a missed stage or two.
            guard queued.count <= Self.queuedStageLimit, consistent < required else { return nil }
        }
        let limit = previous.width / 2
        var sideways = try? FrameMatcher.match(previous: previous, current: current, axis: .horizontal,
                                               maximumOffset: limit)
        if sideways == nil, needsFilteredSearch(consistent: consistent, required: required) {
            sideways = try? FrameMatcher.match(previous: ScrollBackgroundFilter.highPass(previous, radius: 4),
                                               current: ScrollBackgroundFilter.highPass(current, radius: 4),
                                               axis: .horizontal, maximumOffset: limit)
        }
        if let sideways {
            // The match is with the queue's end, which may be a different
            // section that also moves sideways. It replaces the laid gallery
            // only if the queue never left the height where that gallery stood.
            return !throughQueue || queueStaysAtLaidStage(queued, expected: expected)
                ? .sideways(sideways) : nil
        }
        // A profile is weaker than a sideways match: never enter with it or
        // overrule tiles that already support the calibrated vertical step.
        let history = throughQueue ? (queued.count > 1 ? queued[queued.count - 2] : latest)
            : (latest == previous ? self.history : nil)
        if isActive, consistent < required, let expected, let history,
           ScrollRowProfile.inspect(history: history, previous: previous, current: current,
                                    expected: expected)?.stands == true {
            // Rows can stand again after the queued frames have left the
            // gallery. They must still share its last laid vertical position.
            if throughQueue, !sharesLaidRows(current: current, expected: expected) { return nil }
            return .standing
        }
        return nil
    }

    /// Whether the rows of `current` stand where the rows of the last laid
    /// stage stood, judged against the frame that stage replaced.
    private func sharesLaidRows(current: CaptureFrame, expected: Int) -> Bool {
        guard let latest, let earlier = history else { return false }
        return ScrollRowProfile.inspect(history: earlier, previous: latest, current: current,
                                        expected: expected)?.sharesHeight == true
    }

    /// Missed stages of a gallery stand where it stood, frame after frame. A
    /// queue that went down with the page, even by one frame, is an exit: the
    /// pair of the laid stage and a later stage says nothing about it, for the
    /// cards of two stages hardly share a row profile.
    func queueStaysAtLaidStage(_ queued: [CaptureFrame], expected: Int?) -> Bool {
        guard let expected, let latest, var older = history else { return false }
        var before = latest
        for frame in queued {
            guard ScrollRowProfile.inspect(history: older, previous: before, current: frame,
                                           expected: expected)?.sharesHeight == true
            else { return false }
            older = before
            before = frame
        }
        return true
    }

    mutating func acceptedStage(previous: CaptureFrame, current: CaptureFrame) {
        stages += 1
        history = previous
        latest = current
    }

    /// The guard belongs to the operation, so a queued or push-check frame
    /// cannot accidentally overwrite a different last laid position.
    mutating func replaceLast(previous: CaptureFrame, current: CaptureFrame,
                              in assembler: inout ImageAssembler) throws -> Bool {
        guard assembler.lastFrame == previous else { return false }
        try assembler.replaceLast(with: current)
        acceptedStage(previous: previous, current: current)
        return true
    }

    /// The queued frames may be missed stages of the same pinned section.
    /// Replace its laid position first; discard them only after that succeeds.
    /// `inspect` judged the stage off the main thread; this only guards that
    /// the state it was judged against is still the one in the assembler.
    mutating func replaceQueuedStage(previous: CaptureFrame, current: CaptureFrame,
                                     in assembler: inout ImageAssembler, queue: inout TemporarySteps,
                                     consistent: Int, required: Int) throws -> Int? {
        guard isActive else { return nil }
        guard !releaseForVerticalSupport(consistent: consistent, required: required),
              queue.count <= Self.queuedStageLimit,
              let latest, assembler.lastFrame == latest, queue.steps.last?.frame == previous
        else { return nil }
        try assembler.replaceLast(with: current)
        acceptedStage(previous: previous, current: current)
        return queue.discard()
    }

    /// A refused frame with supported downward motion must keep its queue;
    /// a later sideways match cannot turn that exit into discarded stages.
    @discardableResult
    mutating func releaseForVerticalSupport(consistent: Int, required: Int) -> Bool {
        guard isActive, consistent >= required else { return false }
        self = Self()
        return true
    }

    /// All session placements share this append, including queued calibration
    /// steps and forward landings. Reset only after a successful vertical lay.
    mutating func append(_ frame: CaptureFrame, movement: Int, to assembler: inout ImageAssembler,
                         pinned: PinnedGrid? = nil) throws {
        try assembler.append(frame, movement: movement, pinned: pinned)
        if assembler.axis == .vertical { self = Self() }
    }
}
