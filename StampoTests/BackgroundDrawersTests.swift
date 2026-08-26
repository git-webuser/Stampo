import CoreGraphics
import Testing
@testable import Stampo

/// Switching between the background kinds used to convert, and a conversion is
/// lossy: a four-stop gradient became four corners, and coming back gave two
/// stops derived from those corners. What the user saw was their work being
/// reset by a control that only claimed to change the shape.
@Suite struct BackgroundDrawersTests {

    private let angle: CGFloat = .pi / 2
    private var four: [Presentation.Stop] {
        [Presentation.Stop(.white, at: 0),
         Presentation.Stop(Presentation.Color(red: 1, green: 0, blue: 0, alpha: 1), at: 0.2),
         Presentation.Stop(Presentation.Color(red: 0, green: 0, blue: 1, alpha: 1), at: 0.75),
         Presentation.Stop(.black, at: 1)]
    }

    /// The point of the whole type: leave a drawer, come back, find your work.
    @Test func aGradientComesBackAsItWasLeft() {
        var drawers = BackgroundDrawers()
        let linear = Presentation.Background.linearGradient(stops: four, angle: angle)

        let mesh = drawers.switching(from: linear, to: .mesh, angle: angle)
        let back = drawers.switching(from: mesh, to: .linear, angle: angle)

        #expect(back == linear)
    }

    /// Including the trip through a third drawer, and including the solid
    /// colour, which has exactly the same problem for one value instead of
    /// four.
    @Test func everyDrawerKeepsItsOwn() {
        var drawers = BackgroundDrawers()
        let sand = Presentation.Color(red: 0.93, green: 0.89, blue: 0.85, alpha: 1)
        let linear = Presentation.Background.linearGradient(stops: four, angle: angle)

        var current = drawers.switching(from: .solid(sand), to: .linear, angle: angle)
        current = drawers.switching(from: linear, to: .radial, angle: angle)
        current = drawers.switching(from: current, to: .mesh, angle: angle)
        current = drawers.switching(from: current, to: .solid, angle: angle)

        #expect(current == .solid(sand))
        #expect(drawers.switching(from: current, to: .linear, angle: angle) == linear)
    }

    /// The first time a drawer is opened there is nothing to put back, and
    /// arriving at an empty mesh should not mean arriving at black.
    @Test func anUnopenedDrawerIsBuiltFromTheColoursOnScreen() {
        var drawers = BackgroundDrawers()
        let linear = Presentation.Background.linearGradient(
            stops: Presentation.Stop.spread([.white, .black]), angle: angle)

        let mesh = drawers.switching(from: linear, to: .mesh, angle: angle)

        #expect(mesh.meshColors.count == 4)
        #expect(mesh.meshColors.first == .white)
        #expect(mesh.meshColors.last == .black)
    }

    /// A gradient's positions cannot come along to a mesh — four corners sit in
    /// a square — but the colours must.
    @Test func aMeshTakesTheColoursAndNotThePlaces() {
        let stops = four
        let mesh = BackgroundDrawers.converted(
            .linearGradient(stops: stops, angle: angle), to: .mesh, angle: angle)

        #expect(mesh.meshColors.first == stops.first?.color)
        #expect(mesh.meshColors.last == stops.last?.color)
        #expect(mesh.stops.isEmpty)   // a mesh has no ramp to report
    }

    /// "Gradient" returns to the gradient you were last in, not to a linear one
    /// you may never have chosen.
    @Test func theGradientTileRemembersWhichGradient() {
        var drawers = BackgroundDrawers()
        #expect(drawers.lastGradient == .linear)

        let mesh = drawers.switching(from: .solid(.white), to: .mesh, angle: angle)
        #expect(drawers.lastGradient == .mesh)

        _ = drawers.switching(from: mesh, to: .solid, angle: angle)
        #expect(drawers.lastGradient == .mesh)
    }

    /// Transparent has nothing in it to keep, and must not overwrite the drawer
    /// of whatever was there before.
    @Test func transparentKeepsNothing() {
        var drawers = BackgroundDrawers()
        let linear = Presentation.Background.linearGradient(stops: four, angle: angle)
        drawers.keep(linear)

        drawers.keep(.none)

        #expect(drawers.kept(.linear) == linear)
        #expect(BackgroundDrawers.drawer(of: .none) == nil)
    }
}
