import Testing
@testable import Stampo

@Suite struct ScrollParallaxTests {
    private func lays(_ pair: ScrollQueueLaying.PairCost?, axis: ScrollAxis = .vertical,
                      calibrated: Bool = true, clean: Bool = true, push: Bool = false,
                      expected: Int? = 160, changed: Bool = true) -> Bool {
        ScrollParallax.shouldLay(axis: axis, calibrationConfirmed: calibrated, cleanStep: clean,
                                 isPush: push, expected: expected, frameChanged: changed, pair: pair)
    }

    @Test func onlyAClearImprovementAtTheCalibratedDistanceIsLaid() {
        #expect(lays(.init(shifted: 7.4, still: 10)))
        #expect(!lays(.init(shifted: 8.85, still: 10)))
        #expect(!lays(.init(shifted: 8, still: 10)))
        #expect(!lays(nil))
    }

    @Test func anIdenticalPairOrTheEndOfThePageCannotBeLaid() {
        #expect(!lays(.init(shifted: 0.1, still: 0.4)))
        #expect(!lays(.init(shifted: 10, still: 0)))
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
