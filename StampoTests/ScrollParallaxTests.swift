import Testing
@testable import Stampo

@Suite struct ScrollParallaxTests {
    private func lays(_ pair: ScrollQueueLaying.PairCost?, axis: ScrollAxis = .vertical,
                      calibrated: Bool = true, clean: Bool = true, push: Bool = false,
                      expected: Int? = 160, changed: Bool = true) -> Bool {
        ScrollParallax.shouldLay(axis: axis, calibrationConfirmed: calibrated, cleanStep: clean,
                                 isPush: push, expected: expected, frameChanged: changed, pair: pair)
    }

    /// An explicit pair, not `.init(…)` inside `#expect(!lays(…))`: Xcode 26.6
    /// expands that form into an unused call and the expectation fails.
    private func cost(_ shifted: Double, _ still: Double) -> ScrollQueueLaying.PairCost {
        ScrollQueueLaying.PairCost(shifted: shifted, still: still)
    }

    @Test func onlyAClearImprovementAtTheCalibratedDistanceIsLaid() {
        #expect(lays(cost(7.4, 10)))
        #expect(!lays(cost(8.85, 10)))
        #expect(!lays(cost(8, 10)))
        #expect(!lays(nil))
    }

    @Test func anIdenticalPairOrTheEndOfThePageCannotBeLaid() {
        #expect(!lays(cost(0.1, 0.4)))
        #expect(!lays(cost(10, 0)))
    }

    @Test func everyPrerequisiteIsRequired() {
        let pair = ScrollQueueLaying.PairCost(shifted: 7.4, still: 10)
        #expect(!lays(pair, axis: .horizontal))
        #expect(!lays(pair, calibrated: false))
        #expect(!lays(pair, clean: false))
        #expect(!lays(pair, push: true))
        #expect(!lays(pair, expected: nil))
        #expect(!lays(pair, changed: false))
    }

    @Test func anInferredPlacementCannotRelayOrChangeCalibration() {
        let placement = ScrollStepPlacement.parallax
        #expect(!placement.cleanStep)
        #expect(!placement.updatesCalibration)
    }
}
