import Foundation
import Testing
@testable import Stampo

/// The queue behind `NotchPanelController.hideAnimated`: what a second close
/// does while the first is still running, and which caller action — a capture,
/// the colour picker, a scan — is waiting for the panel to be gone.
///
/// What these cannot reach is the controller's own wiring: that a join returns
/// before `bumpGeneration()` and before the animation starts, and that a show
/// or a sleep calls `discard()`. Those lines need a real `NSPanel`.
@Suite struct PanelHideQueueTests {

    /// Which caller actions ran, in order.
    private final class Ran {
        var names: [String] = []
    }

    private func action(_ name: String, _ ran: Ran) -> () -> Void {
        { ran.names.append(name) }
    }

    /// What `firePendingHideCompletion()` does with the queue.
    private func fire(_ queue: inout PanelHideQueue) {
        queue.take()?()
    }

    // MARK: One close — nothing changes

    @Test func aLoneCloseBeginsAHideAndDeliversItsActionOnce() {
        let ran = Ran()
        var queue = PanelHideQueue()

        let request = queue.request(isHiding: false, now: 0, completion: action("capture", ran))
        #expect(request == .begin)
        #expect(ran.names.isEmpty, "the action waits for the panel to be gone")

        fire(&queue)
        fire(&queue)
        #expect(ran.names == ["capture"])
    }

    @Test func aLoneCloseWithoutAnActionHasNothingToDeliver() {
        var queue = PanelHideQueue()
        #expect(queue.request(isHiding: false, now: 0, completion: nil) == .begin)
        #expect(!queue.hasPendingCompletion)
    }

    // MARK: Second close, neither has an action

    @Test func aSecondCloseWhileHidingJoinsTheFirst() {
        var queue = PanelHideQueue()
        #expect(queue.request(isHiding: false, now: 10, completion: nil) == .begin)

        // The close button and the click on the notch arrive together.
        #expect(queue.request(isHiding: true, now: 10.05, completion: nil) == .join)
        #expect(!queue.hasPendingCompletion)
    }

    @Test func aJoinDoesNotRestartTheClock() {
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 10, completion: nil)

        #expect(queue.request(isHiding: true, now: 10.6, completion: nil) == .join)
        #expect(queue.startedAt == 10, "the first close still owns the hide")
        // Counted from the first close, not from the last join.
        #expect(queue.request(isHiding: true, now: 10.9, completion: nil) == .join)
        #expect(queue.request(isHiding: true, now: 11.0, completion: nil) == .restart)
    }

    // MARK: An action arrives while a hide is already running

    @Test func anActionAskedDuringAHideWaitsAndRunsOnce() {
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: nil)

        #expect(queue.request(isHiding: true, now: 0.2, completion: action("capture", ran)) == .join)
        #expect(ran.names.isEmpty, "not before the panel has gone")

        fire(&queue)
        fire(&queue)
        #expect(ran.names == ["capture"])
    }

    // MARK: A close with no action must not cancel the one that is waiting

    @Test func aCloseWithoutAnActionKeepsTheWaitingOne() {
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: action("capture", ran))

        // The click outside the panel, right after the capture hotkey.
        #expect(queue.request(isHiding: true, now: 0.05, completion: nil) == .join)
        #expect(queue.request(isHiding: true, now: 0.10, completion: nil) == .join)

        fire(&queue)
        #expect(ran.names == ["capture"])
    }

    // MARK: Two actions — the last one wins

    @Test func theLastOfTwoActionsWinsAndOnlyOneRuns() {
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: action("first", ran))
        #expect(queue.request(isHiding: true, now: 0.1, completion: action("second", ran)) == .join)

        fire(&queue)
        fire(&queue)
        #expect(ran.names == ["second"])
    }

    // MARK: A show, a sleep or a Space change drops what was waiting

    @Test func discardDropsTheWaitingAction() {
        // `showAnimated` and `invalidatePanelAfterEnvironmentChange` both end
        // here: a show that interrupts a hide aborts it, and a capture overlay
        // must not pop up after the Mac wakes.
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: action("capture", ran))

        queue.discard()

        #expect(!queue.hasPendingCompletion)
        fire(&queue)
        #expect(ran.names.isEmpty)
    }

    @Test func aCloseAfterAShowBeginsAgainEvenWithinTheWindow() {
        // Hide, show cuts it short, hide again 0.3 s later: the panel is not
        // `.hiding` at that moment, so this is a new hide, not a join of the
        // one the show cancelled — and the cancelled hide's action is gone.
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: action("old", ran))
        queue.discard()

        #expect(queue.request(isHiding: false, now: 0.3, completion: action("new", ran)) == .begin)
        #expect(queue.startedAt == 0.3)

        fire(&queue)
        #expect(ran.names == ["new"])
    }

    // MARK: The fuse — a hide that is stuck is run again, as it was before

    @Test func theJoinWindowIsOneSecond() {
        #expect(PanelHideQueue.joinWindow == 1.0)
    }

    @Test(arguments: [0.0, 0.1, 0.56, 0.999])
    func aHideYoungerThanTheWindowIsJoined(elapsed: TimeInterval) {
        #expect(PanelHideQueue.decide(isHiding: true, elapsed: elapsed) == .join)
    }

    @Test(arguments: [1.0, 1.5, 30.0, -0.1, Double.nan])
    func aHideAsOldAsTheWindowOrOlderIsRestarted(elapsed: TimeInterval) {
        // Negative and NaN cannot happen with a monotonic clock; if they did,
        // running the animation again is the behaviour from before joining.
        #expect(PanelHideQueue.decide(isHiding: true, elapsed: elapsed) == .restart)
    }

    @Test func aRestartTakesTheNewActionAsBefore() {
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: action("old", ran))

        #expect(queue.request(isHiding: true, now: 2, completion: action("new", ran)) == .restart)
        #expect(queue.startedAt == 2, "the restart is a new hide with a new window")

        fire(&queue)
        #expect(ran.names == ["new"])
    }

    @Test func aRestartWithoutAnActionDropsTheOldOneAsBefore() {
        // Pinned on purpose: the table says "later — restart as it is now".
        let ran = Ran()
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: action("old", ran))

        #expect(queue.request(isHiding: true, now: 2, completion: nil) == .restart)

        fire(&queue)
        #expect(ran.names.isEmpty)
    }

    @Test func afterARestartTheNextCloseJoinsIt() {
        var queue = PanelHideQueue()
        _ = queue.request(isHiding: false, now: 0, completion: nil)
        _ = queue.request(isHiding: true, now: 2, completion: nil)

        #expect(queue.request(isHiding: true, now: 2.4, completion: nil) == .join)
    }

    // MARK: No hide running

    @Test func notHidingAlwaysBegins() {
        #expect(PanelHideQueue.decide(isHiding: false, elapsed: nil) == .begin)
        #expect(PanelHideQueue.decide(isHiding: false, elapsed: 0.1) == .begin)
        // `.hiding` set by something that never started the clock.
        #expect(PanelHideQueue.decide(isHiding: true, elapsed: nil) == .begin)
    }

    @Test func takeOnAnEmptyQueueGivesNothing() {
        var queue = PanelHideQueue()
        let taken = queue.take()
        #expect(taken == nil)
    }
}
