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
