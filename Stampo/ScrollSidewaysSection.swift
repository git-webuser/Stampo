/// A sideways match establishes the gallery. Its row structure may then keep
/// it latched through video frames until a vertical append places the page.
nonisolated struct ScrollSidewaysSection: Sendable {
    static let limit = 24
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
    func inspect(previous: CaptureFrame, current: CaptureFrame, expected: Int?,
                 consistent: Int, required: Int, queuedHistory: CaptureFrame? = nil) -> Stage? {
        let limit = previous.width / 2
        if let match = try? FrameMatcher.match(previous: previous, current: current, axis: .horizontal,
                                               maximumOffset: limit) {
            return .sideways(match)
        }
        if needsFilteredSearch(consistent: consistent, required: required),
           let match = try? FrameMatcher.match(previous: ScrollBackgroundFilter.highPass(previous, radius: 4),
                                               current: ScrollBackgroundFilter.highPass(current, radius: 4),
                                               axis: .horizontal, maximumOffset: limit) {
            return .sideways(match)
        }
        // A profile is weaker than a sideways match: never enter with it or
        // overrule tiles that already support the calibrated vertical step.
        let history = queuedHistory ?? (latest == previous ? self.history : nil)
        if isActive, consistent < required, let expected, let history,
           ScrollRowProfile.inspect(history: history, previous: previous, current: current,
                                    expected: expected)?.stands == true {
            if queuedHistory != nil {
                // Rows can stand again after the queued frames have left the
                // gallery. They must still share its last laid vertical position.
                guard let latest, let earlier = self.history,
                      ScrollRowProfile.inspect(history: earlier, previous: latest, current: current,
                                               expected: expected)?.zeroIsNearMinimum == true
                else { return nil }
            }
            return .standing
        }
        return nil
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
    mutating func replaceQueuedStage(previous: CaptureFrame, current: CaptureFrame,
                                     in assembler: inout ImageAssembler, queue: inout TemporarySteps,
                                     consistent: Int, required: Int) throws -> Int? {
        guard isActive else { return nil }
        guard !releaseForVerticalSupport(consistent: consistent, required: required),
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
