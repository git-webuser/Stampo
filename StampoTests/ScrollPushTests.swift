import Testing
@testable import Stampo

/// A push through a section pinned to the viewport (`ScrollPush`): what the
/// capture does when steps leave the page where it was.
@Suite struct ScrollPushTests {
    typealias Mode = ScrollPush.Mode
    typealias Step = ScrollPush.Step

    private func next(_ mode: Mode, _ outcome: ScrollPush.Outcome) -> Step {
        ScrollPush.next(mode: mode, outcome: outcome)
    }

    @Test func aPushStartsAfterTwoStationaryStepsAndOnlyWithNothingWaiting() {
        #expect(ScrollPush.startsPush(zeroMotionCount: 2, queueIsEmpty: true))
        #expect(!ScrollPush.startsPush(zeroMotionCount: 2, queueIsEmpty: false))
        #expect(!ScrollPush.startsPush(zeroMotionCount: 1, queueIsEmpty: true))
        #expect(!ScrollPush.startsPush(zeroMotionCount: 3, queueIsEmpty: true))
        #expect(!ScrollPush.startsPush(zeroMotionCount: 0, queueIsEmpty: true))
    }

    @Test func onlyTheFirstPushAndTheSectionSendOne() {
        #expect(ScrollPush.sendsPush(.push))
        #expect(ScrollPush.sendsPush(.section(pushes: 3)))
        #expect(!ScrollPush.sendsPush(.none))
        #expect(!ScrollPush.sendsPush(.settle))
    }

    @Test func anOrdinaryStationaryStepCountsAsItDid() {
        #expect(next(.none, .stationary(changed: false)) == Step(action: .count, mode: .none))
        // Even a changed frame, with no push before it: as now.
        #expect(next(.none, .stationary(changed: true)) == Step(action: .count, mode: .none))
    }

    @Test func aPushThatChangesNothingIsTheEnd() {
        #expect(next(.push, .stationary(changed: false)) == Step(action: .end, mode: .none))
    }

    @Test func aPushThatChangesTheFrameBeginsASectionAndEachFurtherOneReplacesAgain() {
        #expect(next(.push, .stationary(changed: true)) == Step(action: .replace, mode: .section(pushes: 1)))
        #expect(next(.section(pushes: 1), .stationary(changed: true))
                == Step(action: .replace, mode: .section(pushes: 2)))
        #expect(ScrollPush.pushes(in: .section(pushes: 2)) == 2)
        #expect(ScrollPush.pushes(in: .none) == 0)
    }

    @Test func aStepPlacedOrAnythingElseLeavesTheModeFromAnyMode() {
        for mode in [Mode.none, .push, .section(pushes: 4), .settle] {
            #expect(next(mode, .placed) == Step(action: .proceed, mode: .none), "\(mode)")
            #expect(next(mode, .other) == Step(action: .proceed, mode: .none), "\(mode)")
        }
    }

    /// A push that stopped exactly at the end of the pinning leaves the frame as
    /// it was: one ordinary step then decides whether the page goes on.
    @Test func aQuietPushInASectionIsFollowedByOneOrdinaryStep() {
        #expect(next(.section(pushes: 2), .stationary(changed: false)) == Step(action: .hold, mode: .settle))
        #expect(next(.settle, .stationary(changed: false)) == Step(action: .end, mode: .none))
        #expect(next(.settle, .placed) == Step(action: .proceed, mode: .none))
        #expect(next(.settle, .stationary(changed: true)) == Step(action: .count, mode: .none))
    }

    @Test func sixPushesWithNothingPlacedExhaustTheSection() {
        #expect(ScrollPush.limit == 6)
        var mode = Mode.push
        for expected in 1...5 {
            let step = next(mode, .stationary(changed: true))
            #expect(step.action == .replace && step.mode == .section(pushes: expected))
            #expect(!ScrollPush.isExhausted(step.mode))
            mode = step.mode
        }
        let sixth = next(mode, .stationary(changed: true))
        #expect(sixth.mode == .section(pushes: 6))
        #expect(ScrollPush.isExhausted(sixth.mode))
        #expect(!ScrollPush.isExhausted(.none) && !ScrollPush.isExhausted(.settle) && !ScrollPush.isExhausted(.push))
    }

    @Test func aFrameIsTheSameFrameBelowAThousandth() {
        #expect(ScrollPush.changedFrom == 0.001)
        // The differences of 2026-10-11-124606 steps 10–12, and a stage change.
        #expect(!ScrollPush.isChanged(0.0000))
        #expect(ScrollPush.isChanged(0.0446))
        #expect(ScrollPush.isChanged(0.001))
        #expect(!ScrollPush.isChanged(0.00099))
    }

    @Test func aPushIsComparedWithTheLastFrameThatStoodWhenThereIsOne() {
        #expect(ScrollPush.comparesWithStationaryFrame(mode: .push, haveStationaryFrame: true))
        #expect(!ScrollPush.comparesWithStationaryFrame(mode: .push, haveStationaryFrame: false))
        // In a section and after a quiet push the frame before the step is the one kept.
        for mode in [Mode.none, .section(pushes: 2), .settle] {
            #expect(!ScrollPush.comparesWithStationaryFrame(mode: mode, haveStationaryFrame: true), "\(mode)")
        }
    }

    /// 2026-10-11-000034, 2026-10-10-150813, 2026-10-11-005720: at the end of the
    /// page the frames of three steps are the same as each other and differ from
    /// the frame kept by a steady amount (0.0129, 0.0047, 0.0037). A push shows
    /// the same frame again: against the frame kept that is a change and a
    /// section, against the one before the push it is nothing, and the end.
    @Test func aPageThatDiffersFromTheKeptFrameBySteadilyAndStandsIsTheEnd() {
        let againstKept = 0.0129, againstStanding = 0.0
        #expect(next(.push, .stationary(changed: ScrollPush.isChanged(againstKept))).action == .replace)
        #expect(next(.push, .stationary(changed: ScrollPush.isChanged(againstStanding)))
                == Step(action: .end, mode: .none))
    }

    /// A step decided as stationary is one to rely on when its frame is the same
    /// as the one kept, or three unpinned tiles of the middle rows stand.
    @Test func aStationaryStepIsReliableWhenBlankOrWhenThreeTilesStand() {
        #expect(ScrollPush.reliableStandingTiles == 3)
        // Blank: 2026-10-11-133221 steps 12, 13 (difference 0.0000), however few tiles.
        #expect(ScrollPush.isReliableStep(difference: 0.0, unpinnedStanding: 8))
        #expect(ScrollPush.isReliableStep(difference: 0.0, unpinnedStanding: 0))
        // Not blank, an animation in the section: 2026-10-11-140123 steps 10, 11
        // (0.0102, 0.0163) with four tiles standing.
        #expect(ScrollPush.isReliableStep(difference: 0.0102, unpinnedStanding: 4))
        #expect(ScrollPush.isReliableStep(difference: 0.0163, unpinnedStanding: 3))
        // Two: the old rule. One: the only false "stationary" there is,
        // 2026-10-11-124606 step 03, where the page had moved.
        #expect(!ScrollPush.isReliableStep(difference: 0.0433, unpinnedStanding: 2))
        #expect(!ScrollPush.isReliableStep(difference: 0.0433, unpinnedStanding: 1))
        #expect(!ScrollPush.isReliableStep(difference: 0.0433, unpinnedStanding: 0))
    }

    /// 2026-10-11-133221: steps 12 and 13 left the frame the same (difference
    /// 0.0000), the push of step 14 changed it (0.0668) and the matcher could not
    /// place it; not one unpinned tile of the new stage stood, and the decision
    /// was "retry". After two reliable steps that is a section changing its stage.
    @Test func aChangedPushAfterReliableStepsIsASectionWithoutStandingTiles() {
        func outcome(_ stationary: Bool, undecided: Bool = true, changed: Bool = true,
                     reliable: Bool = true, mode: Mode = .push) -> ScrollPush.Outcome {
            ScrollPush.outcome(decidedStationary: stationary, undecided: undecided, changed: changed,
                               afterReliableSteps: reliable, mode: mode)
        }
        // The case: reliable pair, changed, not placed, no tile stands.
        #expect(outcome(false) == .stationary(changed: true))
        #expect(ScrollPush.acceptsWithoutStandingTiles(decidedStationary: false, undecided: true, changed: true,
                                                       afterReliableSteps: true, mode: .push))
        #expect(outcome(false, mode: .section(pushes: 2)) == .stationary(changed: true))
        // A pair that was not reliable — an animation with two tiles standing, a
        // frame that differs from the one kept by a steady amount: only a decided
        // stationary counts, as before.
        #expect(outcome(false, reliable: false) == .other)
        #expect(outcome(true, reliable: false) == .stationary(changed: true))
        #expect(!ScrollPush.acceptsWithoutStandingTiles(decidedStationary: false, undecided: true, changed: true,
                                                        afterReliableSteps: false, mode: .push))
        // Nothing changed: no section, and a decided stationary is the end.
        #expect(outcome(false, changed: false) == .other)
        #expect(outcome(true, changed: false) == .stationary(changed: false))
        #expect(next(.push, outcome(true, changed: false)) == Step(action: .end, mode: .none))
        // Not "cannot tell" — some other refusal: no.
        #expect(outcome(false, undecided: false) == .other)
        // Ordinary steps and the step after a quiet push are not pushes.
        #expect(outcome(false, mode: .none) == .other)
        #expect(outcome(false, mode: .settle) == .other)
        // And what follows: the section replaces the frame.
        #expect(next(.push, outcome(false)) == Step(action: .replace, mode: .section(pushes: 1)))
        #expect(next(.section(pushes: 1), outcome(false)) == Step(action: .replace, mode: .section(pushes: 2)))
    }

    /// The walk of a pinned section as the capture goes through it: two steps
    /// that stand, a push that changes the frame twice, a push that places.
    @Test func theWalkThroughASection() {
        var mode = Mode.none
        var count = 0
        for _ in 0..<2 {
            let step = next(mode, .stationary(changed: false))
            #expect(step.action == .count)
            count += 1
            mode = step.mode
        }
        if ScrollPush.startsPush(zeroMotionCount: count, queueIsEmpty: true) { mode = .push }
        #expect(mode == .push)
        for pushes in 1...2 {
            let step = next(mode, .stationary(changed: true))
            #expect(step.action == .replace && step.mode == .section(pushes: pushes))
            mode = step.mode
        }
        #expect(next(mode, .placed) == Step(action: .proceed, mode: .none))
    }
}
