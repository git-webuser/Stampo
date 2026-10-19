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
        // Not after a check found the page going on under a push, until a frame is laid.
        #expect(ScrollPush.startsPush(zeroMotionCount: 2, queueIsEmpty: true, allowed: true))
        #expect(!ScrollPush.startsPush(zeroMotionCount: 2, queueIsEmpty: true, allowed: false))
    }

    @Test func onlyTheFirstPushAndTheSectionSendOne() {
        #expect(ScrollPush.sendsPush(.push))
        #expect(ScrollPush.sendsPush(.section(pushes: 3)))
        #expect(!ScrollPush.sendsPush(.none))
        #expect(!ScrollPush.sendsPush(.settle))
        // The step after a push that changed the frame is an ordinary one.
        #expect(!ScrollPush.sendsPush(.check(pushes: 1)))
    }

    @Test func anOrdinaryStationaryStepCountsAsItDid() {
        #expect(next(.none, .stationary(changed: false)) == Step(action: .count, mode: .none))
        // Even a changed frame, with no push before it: as now.
        #expect(next(.none, .stationary(changed: true)) == Step(action: .count, mode: .none))
    }

    @Test func aPushThatChangesNothingIsTheEnd() {
        #expect(next(.push, .stationary(changed: false)) == Step(action: .end, mode: .none))
    }

    /// A push that changed the frame is not yet a stage of a section: an ordinary
    /// step from its frame comes first (`afterCheck`), and only a page that stood
    /// under it makes the push a stage.
    @Test func aPushThatChangesTheFrameIsCheckedBeforeItBeginsASection() {
        #expect(next(.push, .stationary(changed: true)) == Step(action: .check, mode: .check(pushes: 1)))
        #expect(next(.section(pushes: 1), .stationary(changed: true))
                == Step(action: .check, mode: .check(pushes: 2)))
        #expect(ScrollPush.pushes(in: .section(pushes: 2)) == 2)
        #expect(ScrollPush.pushes(in: .check(pushes: 3)) == 3)
        #expect(ScrollPush.pushes(in: .none) == 0)
    }

    /// The page stood under the check: the push was a stage, and each further
    /// push is checked the same way.
    @Test func aCheckThatFindsThePageStandingMakesTheSectionAndTheNextPushIsCheckedToo() {
        #expect(ScrollPush.afterCheck(mode: .check(pushes: 1), movesPage: false)
                == Step(action: .replace, mode: .section(pushes: 1)))
        #expect(ScrollPush.afterCheck(mode: .check(pushes: 2), movesPage: false)
                == Step(action: .replace, mode: .section(pushes: 2)))
        // The next push sees the section again.
        #expect(next(.section(pushes: 1), .stationary(changed: true)) == Step(action: .check, mode: .check(pushes: 2)))
    }

    /// 2026-10-11-201829: the wheel turned a box with a scroll of its own until it
    /// ended, then the page; the push took the page past more than a frame. The
    /// check step is placed: nothing is replaced, the page goes back, and no push
    /// is sent until a frame is laid.
    @Test func aCheckThatFindsThePageMovingUndoesThePush() {
        #expect(ScrollPush.afterCheck(mode: .check(pushes: 1), movesPage: true) == Step(action: .undo, mode: .none))
        #expect(ScrollPush.afterCheck(mode: .check(pushes: 4), movesPage: true) == Step(action: .undo, mode: .none))
        // Not a mode of a check: nothing to say.
        for mode in [Mode.none, .push, .section(pushes: 2), .settle] {
            #expect(ScrollPush.afterCheck(mode: mode, movesPage: true) == Step(action: .proceed, mode: .none), "\(mode)")
            #expect(ScrollPush.afterCheck(mode: mode, movesPage: false) == Step(action: .proceed, mode: .none), "\(mode)")
        }
        // And what follows: two steps that stand, none of them a push now.
        #expect(!ScrollPush.startsPush(zeroMotionCount: 2, queueIsEmpty: true, allowed: false))
    }

    /// The page moves when the matcher placed the step, or when the tiles bear
    /// the distance it was sent for out although it could not be placed. A step
    /// whose tiles stand, or agree with nothing and speak against nothing, or are
    /// contradicted, shows no movement: the section changed its stage.
    @Test func theStepAfterAPushShowsThePageMovingWhenPlacedOrBornOutByTheTiles() {
        #expect(ScrollPush.movesPage(placed: true, decision: .retry))
        #expect(ScrollPush.movesPage(placed: false, decision: .temporary(confirmed: true)))
        #expect(!ScrollPush.movesPage(placed: false, decision: .temporary(confirmed: false)))
        #expect(!ScrollPush.movesPage(placed: false, decision: .stationary))
        #expect(!ScrollPush.movesPage(placed: false, decision: .retry))
        #expect(!ScrollPush.movesPage(placed: false, decision: .finish))
    }

    /// The section's stage is the check's frame when that changed after the
    /// push — the section went on to a later stage — and the push's otherwise.
    @Test func theStageIsTheChecksFrameWhenItChangedAfterThePush() {
        #expect(ScrollPush.stageFrameIsChecks(differenceFromPush: 0.0441))
        #expect(ScrollPush.stageFrameIsChecks(differenceFromPush: 0.001))
        #expect(!ScrollPush.stageFrameIsChecks(differenceFromPush: 0.00099))
        #expect(!ScrollPush.stageFrameIsChecks(differenceFromPush: 0.0))
    }

    @Test func aStepPlacedOrAnythingElseLeavesTheModeFromAnyMode() {
        for mode in [Mode.none, .push, .section(pushes: 4), .settle, .check(pushes: 2)] {
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
            let pushed = next(mode, .stationary(changed: true))
            #expect(pushed == Step(action: .check, mode: .check(pushes: expected)))
            let step = ScrollPush.afterCheck(mode: pushed.mode, movesPage: false)
            #expect(step.action == .replace && step.mode == .section(pushes: expected))
            #expect(!ScrollPush.isExhausted(step.mode))
            mode = step.mode
        }
        let pushed = next(mode, .stationary(changed: true))
        let sixth = ScrollPush.afterCheck(mode: pushed.mode, movesPage: false)
        #expect(sixth.mode == .section(pushes: 6))
        #expect(ScrollPush.isExhausted(sixth.mode))
        #expect(!ScrollPush.isExhausted(.none) && !ScrollPush.isExhausted(.settle) && !ScrollPush.isExhausted(.push))
        // A push waiting to be checked is not a stage yet.
        #expect(!ScrollPush.isExhausted(.check(pushes: 6)))
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
        #expect(next(.push, .stationary(changed: ScrollPush.isChanged(againstKept))).action == .check)
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
    /// was "retry". A push that changed the frame is checked by an ordinary step,
    /// whether or not the two steps before it were ones to rely on: 2026-10-11-200300,
    /// where a demo animating in the section made them not (one tile standing,
    /// differences 0.0213 and 0.0431), was a retry before.
    @Test func aChangedPushIsCheckedWhateverThePairBeforeItWas() {
        func outcome(_ stationary: Bool, undecided: Bool = true, changed: Bool = true,
                     mode: Mode = .push) -> ScrollPush.Outcome {
            ScrollPush.outcome(decidedStationary: stationary, undecided: undecided, changed: changed, mode: mode)
        }
        // The case: changed, not placed, no tile stands.
        #expect(outcome(false) == .stationary(changed: true))
        #expect(ScrollPush.acceptsWithoutStandingTiles(decidedStationary: false, undecided: true, changed: true,
                                                       mode: .push))
        #expect(outcome(false, mode: .section(pushes: 2)) == .stationary(changed: true))
        // A decided stationary counts as it did.
        #expect(outcome(true) == .stationary(changed: true))
        // Nothing changed: no section, and a decided stationary is the end.
        #expect(outcome(false, changed: false) == .other)
        #expect(outcome(true, changed: false) == .stationary(changed: false))
        #expect(next(.push, outcome(true, changed: false)) == Step(action: .end, mode: .none))
        // Not "cannot tell" — some other refusal: no.
        #expect(outcome(false, undecided: false) == .other)
        // Ordinary steps, the step after a quiet push and the check step are not pushes.
        #expect(outcome(false, mode: .none) == .other)
        #expect(outcome(false, mode: .settle) == .other)
        #expect(outcome(false, mode: .check(pushes: 1)) == .other)
        // And what follows: the push is checked before the section replaces the frame.
        #expect(next(.push, outcome(false)) == Step(action: .check, mode: .check(pushes: 1)))
        #expect(next(.section(pushes: 1), outcome(false)) == Step(action: .check, mode: .check(pushes: 2)))
    }

    /// The walk of a pinned section as the capture goes through it: two steps
    /// that stand, a push that changes the frame twice (each checked by an
    /// ordinary step that leaves the page where it was), a push that places.
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
            let pushed = next(mode, .stationary(changed: true))
            #expect(pushed == Step(action: .check, mode: .check(pushes: pushes)))
            let step = ScrollPush.afterCheck(mode: pushed.mode, movesPage: false)
            #expect(step.action == .replace && step.mode == .section(pushes: pushes))
            mode = step.mode
        }
        #expect(next(mode, .placed) == Step(action: .proceed, mode: .none))
    }

    /// The walk of a page that a push took past content: two steps that stand (a
    /// box with a scroll of its own turned), a push that changes the frame, a
    /// check that is placed, and the push undone.
    @Test func theWalkOfAPageThatThePushTookPastContent() {
        var mode = Mode.none
        for _ in 0..<2 { mode = next(mode, .stationary(changed: false)).mode }
        mode = .push
        let pushed = next(mode, .stationary(changed: true))
        #expect(pushed == Step(action: .check, mode: .check(pushes: 1)))
        let checked = ScrollPush.afterCheck(mode: pushed.mode, movesPage: ScrollPush.movesPage(placed: true, decision: .retry))
        #expect(checked == Step(action: .undo, mode: .none))
        #expect(!ScrollPush.sendsPush(checked.mode))
    }

    // MARK: A check that moves the page by a part of the step

    private func decision(_ offset: Int, of expected: Int?, confidence: Double = 0.99,
                          pushes: Int = 4) -> ScrollPush.MovingCheck {
        ScrollPush.afterMovingCheck(offset: offset, expected: expected, confidence: confidence, mode: .check(pushes: pushes))
    }

    @Test func aFirmCheckThatMovesAPartOfTheStepKeepsThePush() {
        // 2026-10-20-000209: 233 of 800, firm, after three stages of the section.
        #expect(decision(233, of: 800) == .keepReplacingStage)
        // The same on the first push after the page stood: no stage is laid yet.
        #expect(decision(233, of: 800, pushes: 1) == .keepEdgeToEdge)
        #expect(decision(233, of: 800, pushes: 2) == .keepReplacingStage)
    }

    @Test func aCheckThatMovesTheWholeStepOrIsNotFirmUndoesThePush() {
        // claude.com: the page was free and the check went the whole step.
        #expect(decision(720, of: 720, confidence: 0.98) == .undo)
        #expect(decision(800, of: 800, confidence: 1.0) == .undo)
        // Safari 2026-10-19-182251: 724 of 800, and not firm either.
        #expect(decision(724, of: 800, confidence: 0.73) == .undo)
        #expect(decision(724, of: 800, confidence: 0.99) == .undo)
        // 2026-10-19-133530: 35 of 400 at 0.75 — a small share, but not firm.
        #expect(decision(35, of: 400, confidence: 0.75) == .undo)
    }

    @Test func theShareAndTheFirmnessAreWhereTheyAreFixed() {
        #expect(ScrollPush.sectionEndsInCheckBelow == 0.75)
        #expect(ScrollQueueRelay.firmConfidence == 0.9)
        // Three quarters of the step is not less than three quarters.
        #expect(decision(599, of: 800) == .keepReplacingStage)
        #expect(decision(600, of: 800) == .undo)
        // Firm from 0.9.
        #expect(decision(233, of: 800, confidence: 0.9) == .keepReplacingStage)
        #expect(decision(233, of: 800, confidence: 0.899) == .undo)
    }

    @Test func withoutADistanceToJudgeByOrOutsideACheckThePushIsUndone() {
        #expect(decision(233, of: nil) == .undo)
        #expect(decision(233, of: 0) == .undo)
        #expect(decision(0, of: 800) == .undo)
        #expect(decision(-5, of: 800) == .undo)
        for mode: ScrollPush.Mode in [.none, .push, .section(pushes: 3), .settle] {
            #expect(ScrollPush.afterMovingCheck(offset: 233, expected: 800, confidence: 0.99, mode: mode) == .undo)
        }
    }
}
