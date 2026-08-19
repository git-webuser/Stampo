import Testing
@testable import Stampo

/// The row these back used to act on the end of the list whatever the user
/// pointed at: "+" appended, "−" took the last one away, and order could not be
/// changed at all. Each test below is one of the things that could not be done.
@Suite struct GradientStopsTests {

    private let white = Presentation.Color.white
    private let black = Presentation.Color.black
    private var red: Presentation.Color {
        Presentation.Color(red: 1, green: 0, blue: 0, alpha: 1)
    }

    /// A stop added in the middle sits between the two it was added between,
    /// and carries their blend — so the ramp keeps its shape and only gains a
    /// handle.
    @Test func insertingInTheMiddleLandsBetweenTheNeighbours() {
        let stops = GradientStops.inserted(into: [white, black], after: 0)

        #expect(stops.count == 3)
        #expect(stops[0] == white)
        #expect(stops[2] == black)
        #expect(stops[1] == GradientStops.blend(white, black, amount: 0.5))
    }

    /// After the last stop there is nothing to meet, so the ramp carries on
    /// darker rather than repeating the colour it already ends on.
    @Test func insertingAfterTheLastStopContinuesTheRamp() {
        let stops = GradientStops.inserted(into: [white, red], after: 1)

        #expect(stops.count == 3)
        #expect(stops[2] != red)
        #expect(stops[2] == GradientStops.blend(red, black, amount: 0.35))
    }

    @Test func theListStopsGrowingAtFive() {
        var stops = [white, black]
        for _ in 0..<10 { stops = GradientStops.inserted(into: stops, after: 0) }

        #expect(stops.count == GradientStops.maximum)
    }

    /// The one the user picked, not the one that happens to be last.
    @Test func removingTakesTheStopItWasGiven() {
        let stops = GradientStops.removed(from: [white, red, black], at: 1)

        #expect(stops == [white, black])
    }

    @Test func aGradientNeverFallsBelowTwoStops() {
        let stops = GradientStops.removed(from: [white, black], at: 0)

        #expect(stops == [white, black])
    }

    /// `to` is the slot in the finished list — the spelling both a drag and a
    /// "move left" mean.
    @Test func movingPutsTheStopInTheSlotItWasDroppedOn() {
        #expect(GradientStops.moved([white, red, black], from: 2, to: 0) == [black, white, red])
        #expect(GradientStops.moved([white, red, black], from: 0, to: 1) == [red, white, black])
    }

    @Test func movingNowhereChangesNothing() {
        let stops = [white, red, black]

        #expect(GradientStops.moved(stops, from: 1, to: 1) == stops)
        #expect(GradientStops.moved(stops, from: 0, to: -1) == stops)
        #expect(GradientStops.moved(stops, from: 3, to: 0) == stops)
    }

    /// The selection outlives the list changing under it, which is the whole
    /// reason it is clamped on every read rather than trusted.
    @Test func theSelectionFollowsTheListItPointsInto() {
        #expect(GradientStops.clampedSelection(2, in: [white, black]) == 1)
        #expect(GradientStops.clampedSelection(-1, in: [white, black]) == 0)
        #expect(GradientStops.clampedSelection(1, in: [white, red, black]) == 1)
    }
}
