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
        #expect(0.0000 < ScrollPush.changedFrom)
        #expect(0.0446 >= ScrollPush.changedFrom)
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
