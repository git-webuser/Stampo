import Testing
@testable import Stampo

/// What is decided of a step the matcher could not place (`ScrollStepDecision`).
@Suite struct ScrollStepDecisionTests {
    private func evidence(undecided: Bool = true, canExpect: Bool = true, consistent: Int = 0, against: Int = 0,
                          contradicted: Bool = false, unpinnedStanding: Int = 0, queued: Int = 0,
                          frameUnchanged: Bool = false) -> ScrollStepDecision.Evidence {
        .init(undecided: undecided, canExpect: canExpect, consistent: consistent, against: against,
              contradicted: contradicted, required: 1, unpinnedStanding: unpinnedStanding, queued: queued,
              frameUnchanged: frameUnchanged)
    }

    /// 2026-10-11-185058, 185700: at the end of a page the frames were the same,
    /// difference 0.0000, and the bars of the footer, pinned, were all that stood:
    /// nine steps went into the queue as "unconfirmed" and the capture ended
    /// after eight waiting.
    @Test func aFrameTheSameAsTheLastIsStationaryWhateverStands() {
        #expect(ScrollStepDecision.decide(evidence(unpinnedStanding: 0, frameUnchanged: true)) == .stationary)
        #expect(ScrollStepDecision.decide(evidence(unpinnedStanding: 6, frameUnchanged: true)) == .stationary)
        // Without it, none standing and nothing against: queued, as before.
        #expect(ScrollStepDecision.decide(evidence(unpinnedStanding: 0)) == .temporary(confirmed: false))
        // With the queue full and the frame the same: stationary, not the end for the queue.
        #expect(ScrollStepDecision.decide(evidence(queued: TemporarySteps.limit, frameUnchanged: true)) == .stationary)
        #expect(ScrollStepDecision.decide(evidence(queued: TemporarySteps.limit)) == .finish)
    }

    @Test func aFrameTheSameAsTheLastCannotMakeAFailureOfAnotherKindStationary() {
        #expect(ScrollStepDecision.decide(evidence(undecided: false, frameUnchanged: true)) == .retry)
    }

    @Test func aChangedFrameIsDecidedAsBefore() {
        #expect(ScrollStepDecision.decide(evidence(consistent: 2, unpinnedStanding: 3)) == .temporary(confirmed: true))
        #expect(ScrollStepDecision.decide(evidence(unpinnedStanding: 1)) == .stationary)
        #expect(ScrollStepDecision.decide(evidence(contradicted: true)) == .retry)
        #expect(ScrollStepDecision.decide(evidence(canExpect: false)) == .retry)
    }
}
