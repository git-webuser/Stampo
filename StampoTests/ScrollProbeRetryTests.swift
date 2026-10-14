import Foundation
import Testing
@testable import Stampo

/// The probe taken again while a page plays an intro of its own (apple.com/mac-mini, apple.com/iphone-18-pro).
@Suite struct ScrollProbeRetryTests {
    @Test func theLimitIsTenSecondsAndThePauseOne() {
        #expect(ScrollProbeRetry.limit == 10)
        #expect(ScrollProbeRetry.pause == 1)
    }

    /// An attempt begins while less than ten seconds have passed since the first refusal.
    @Test func anAttemptBeginsOnlyWithinTenSecondsOfTheFirstRefusal() {
        #expect(ScrollProbeRetry.beginsAttempt(after: 0))
        #expect(ScrollProbeRetry.beginsAttempt(after: 1.2))
        #expect(ScrollProbeRetry.beginsAttempt(after: 9.9))
        #expect(!ScrollProbeRetry.beginsAttempt(after: 10))
        #expect(!ScrollProbeRetry.beginsAttempt(after: 14.3))
    }

    /// With none matched the capture goes on from the last pair the probe moved something in, and from the first when
    /// the probe moved nothing in any attempt.
    @Test func theLastPairInWhichTheProbeMovedSomethingIsKept() {
        #expect(ScrollProbeRetry.attemptToKeep(moved: [true, true, true]) == 2)
        #expect(ScrollProbeRetry.attemptToKeep(moved: [true, false, true, false]) == 2)
        #expect(ScrollProbeRetry.attemptToKeep(moved: [false, true, false, false]) == 1)
        #expect(ScrollProbeRetry.attemptToKeep(moved: [false, false]) == nil)
        #expect(ScrollProbeRetry.attemptToKeep(moved: []) == nil)
    }
}
