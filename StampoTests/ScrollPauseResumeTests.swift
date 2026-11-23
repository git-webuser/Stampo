import Testing
@testable import Stampo

/// What a pause leaves for the resume to look at.
@Suite struct ScrollPauseResumeTests {
    /// A pause between a push that changed the frame and its check: no wheel event is in flight, and the page is
    /// past the frame that is kept. The resume has to look for the place, with nothing done by the user.
    @MainActor
    @Test func aPushWaitingForItsCheckSendsTheResumeToLookForThePlace() {
        let quiet = UserScrollLedger()
        let inFlight = ScrollResume.stepInFlightAfterPause(stepInFlight: false, pushCheckPending: true)
        #expect(inFlight)
        #expect(ScrollResume.needsLooking(ledger: quiet, stepWasInFlight: inFlight))
    }

    /// Every other pause is as it was: a step in flight stays in flight, and with neither a step nor a push to
    /// check there is nothing to look for.
    @MainActor
    @Test func everyOtherPauseKeepsTheFlagItHad() {
        let quiet = UserScrollLedger()
        #expect(ScrollResume.stepInFlightAfterPause(stepInFlight: true, pushCheckPending: true))
        #expect(ScrollResume.stepInFlightAfterPause(stepInFlight: true, pushCheckPending: false))
        let none = ScrollResume.stepInFlightAfterPause(stepInFlight: false, pushCheckPending: false)
        #expect(!none)
        #expect(!ScrollResume.needsLooking(ledger: quiet, stepWasInFlight: none))
    }
}
