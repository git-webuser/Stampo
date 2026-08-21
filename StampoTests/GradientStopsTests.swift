import CoreGraphics
import Testing
@testable import Stampo

/// The row these back went through three shapes, and each test below is one of
/// the things that could not be done in an earlier one: reach a middle stop,
/// say where a colour sits, add a handle without changing what is on screen.
@Suite struct GradientStopsTests {

    private let white = Presentation.Color.white
    private let black = Presentation.Color.black
    private var red: Presentation.Color {
        Presentation.Color(red: 1, green: 0, blue: 0, alpha: 1)
    }

    private var whiteToBlack: [Presentation.Stop] {
        Presentation.Stop.spread([white, black])
    }

    /// Colours with no opinion about where they go get laid out evenly — the
    /// way every gradient was built before positions existed.
    @Test func spreadingColoursPutsThemAtEvenPlaces() {
        let three = Presentation.Stop.spread([white, red, black])

        #expect(three.map(\.location) == [0, 0.5, 1])
        #expect(three.map(\.color) == [white, red, black])
        #expect(Presentation.Stop.spread([white]).map(\.location) == [0])
        #expect(Presentation.Stop.spread([]).isEmpty)
    }

    /// A stop added on the ramp takes the colour that was already there, so the
    /// gradient does not change until the new handle is moved or recoloured.
    @Test func addingAStopChangesNothingUntilItMoves() {
        let stops = GradientStops.inserted(into: whiteToBlack, at: 0.25)

        #expect(stops.count == 3)
        #expect(stops[1].location == 0.25)
        #expect(abs(stops[1].color.red - 0.75) < 0.001)
        #expect(abs(stops[1].color.green - 0.75) < 0.001)
    }

    @Test func aStopLandsWhereItWasAskedFor() {
        #expect(GradientStops.inserted(into: whiteToBlack, at: 0.9)[1].location == 0.9)
        // Outside the ramp is not a place; it lands on the end.
        #expect(GradientStops.inserted(into: whiteToBlack, at: 1.4).last?.location == 1)
        #expect(GradientStops.inserted(into: whiteToBlack, at: -2).first?.location == 0)
    }

    @Test func theListStopsGrowingAtEight() {
        var stops = whiteToBlack
        for i in 0..<20 { stops = GradientStops.inserted(into: stops, at: CGFloat(i) / 21) }

        #expect(stops.count == GradientStops.maximum)
    }

    /// Dragging a stop past its neighbour *is* reordering — there is nothing
    /// else to reorder with, and the caller's selection has to follow the stop
    /// it was holding rather than the slot.
    @Test func draggingPastANeighbourReordersAndKeepsTheSelection() {
        let stops = Presentation.Stop.spread([white, red, black])   // 0, 0.5, 1
        // White dragged past red: the list re-sorts, and the selection has to
        // follow the stop that was dragged rather than the slot it left.
        let moved = GradientStops.moved(stops, at: 0, to: 0.8)

        #expect(moved.stops.map(\.color) == [red, white, black])
        #expect(moved.index == 1)
        #expect(moved.stops[1].location == 0.8)
    }

    @Test func aStopCannotLeaveTheRamp() {
        #expect(GradientStops.moved(whiteToBlack, at: 0, to: 3).stops[1].location == 1)
        #expect(GradientStops.moved(whiteToBlack, at: 1, to: -1).stops[0].location == 0)
    }

    /// The stop the user picked, not the one that happens to be last.
    @Test func removingTakesTheStopItWasGiven() {
        let stops = Presentation.Stop.spread([white, red, black])

        #expect(GradientStops.removed(from: stops, at: 1).map(\.color) == [white, black])
    }

    @Test func aGradientNeverFallsBelowTwoStops() {
        #expect(GradientStops.removed(from: whiteToBlack, at: 0) == whiteToBlack)
    }

    /// The colour the ramp shows at a point — the same blend Core Graphics
    /// draws, which is what makes an added stop invisible until it moves.
    @Test func theRampReadsTheSameWayItIsDrawn() {
        #expect(GradientStops.color(of: whiteToBlack, at: 0).red == 1)
        #expect(GradientStops.color(of: whiteToBlack, at: 1).red == 0)
        #expect(abs(GradientStops.color(of: whiteToBlack, at: 0.5).red - 0.5) < 0.001)

        // Before the first stop and after the last, the ramp is flat.
        let inset = [Presentation.Stop(white, at: 0.3), Presentation.Stop(black, at: 0.7)]
        #expect(GradientStops.color(of: inset, at: 0.1).red == 1)
        #expect(GradientStops.color(of: inset, at: 0.95).red == 0)
        #expect(abs(GradientStops.color(of: inset, at: 0.5).red - 0.5) < 0.001)
    }

    /// Two stops in the same spot are a hard edge, which is allowed; the reader
    /// must not divide by the zero between them.
    @Test func twoStopsInOnePlaceAreAnEdge() {
        let edge = [Presentation.Stop(white, at: 0.5), Presentation.Stop(black, at: 0.5)]

        // Either colour is defensible *on* the seam; what matters is that the
        // reader does not divide by the zero between them, and that each side
        // is its own colour.
        #expect(GradientStops.color(of: edge, at: 0.49).red == 1)
        #expect(GradientStops.color(of: edge, at: 0.51).red == 0)
    }

    @Test func theSelectionFollowsTheListItPointsInto() {
        #expect(GradientStops.clampedSelection(2, in: whiteToBlack) == 1)
        #expect(GradientStops.clampedSelection(-1, in: whiteToBlack) == 0)
    }
}
