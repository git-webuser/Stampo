import Testing
@testable import Stampo

/// Where the page is after it was sent back to the frame kept (`ScrollReturn`).
@Suite struct ScrollReturnTests {
    typealias Landing = ScrollReturn.Landing

    /// The frame after the return is the frame returned to, as far as a
    /// thousandth: nothing is done, whatever the matcher might say of it.
    @Test func aFrameThatIsTheSameIsTheSame() {
        #expect(ScrollReturn.landing(difference: 0.0, forward: nil) == .same)
        #expect(ScrollReturn.landing(difference: 0.0008, forward: nil) == .same)
        #expect(ScrollReturn.landing(difference: 0.00099, forward: 546) == .same)
        // The same bound as a push's: one frame is the same frame by it.
        #expect(ScrollReturn.landing(difference: ScrollPush.changedFrom, forward: nil) == .elsewhere)
    }

    /// 2026-10-11-235202 step 15: back 24 lines landed 546 px further along than
    /// the frame of the section; the frame shows the dock and the start of a
    /// quotation, content no step from the frame kept would have reached.
    @Test func aFrameThePlacedFurtherAlongIsLaidAsAStep() {
        #expect(ScrollReturn.landing(difference: 0.2634, forward: 546) == .further(546))
        #expect(ScrollReturn.landing(difference: 0.001, forward: 3) == .further(3))
    }

    /// Placed behind the frame kept (134734 step 40, 195 px, the matcher is asked
    /// forward only), not placed (16 frames of the recordings, 0.007 to 0.19:
    /// an animation, a panel, a video) or placed at nothing: as before.
    @Test func aFrameThatIsBehindOrNotPlacedLeavesItToTheNextStep() {
        #expect(ScrollReturn.landing(difference: 0.0283, forward: nil) == .elsewhere)
        #expect(ScrollReturn.landing(difference: 0.1918, forward: nil) == .elsewhere)
        #expect(ScrollReturn.landing(difference: 0.0224, forward: 0) == .elsewhere)
        #expect(ScrollReturn.landing(difference: 0.0224, forward: -195) == .elsewhere)
    }
}
