import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// Where a click on an archive cell lands.
///
/// The shim is an NSView covering the whole cell, and it steps out of the
/// top-right corner so the delete badge overlaid above it gets the click. The
/// corner it steps out of has to be the one the badge actually covers: it used
/// to yield a round 16 pt while the badge, offset 3 pt outward, reaches only
/// 13 pt back into the cell, and the 3 pt border between them answered to
/// neither — a click there did nothing at all, which is where a near miss under
/// a badge this small usually lands.
@MainActor
@Suite struct ArchiveCellHitTests {

    private let size = CGSize(width: 51, height: 32)   // a file cell: 32 × 1.6

    private func makeShim(bleed: CGFloat = 3) -> ArchiveDragShimView {
        var pressed = false
        var dragging = false
        let view = ArchiveDragShimView(
            isPressed: Binding(get: { pressed }, set: { pressed = $0 }),
            isDragging: Binding(get: { dragging }, set: { dragging = $0 }),
            onHoverChange: { _ in },
            onTap: {}
        )
        view.frame = NSRect(origin: .zero, size: size)
        view.badgeCorner = ArchiveDeleteBadge.cornerCoverage(bleed: bleed)
        return view
    }

    /// Points go in raw, in the shim's own flipped space where small y is the
    /// top — which is the space the override compares against `bounds`, and the
    /// space it gets in the real hierarchy because the shim fills its parent at
    /// the origin. Converting here instead would land in window coordinates,
    /// which are not flipped, and quietly test the cell upside down.
    private func yields(_ shim: ArchiveDragShimView, at point: CGPoint) -> Bool {
        shim.hitTest(point) == nil
    }

    @Test func theBadgesOwnCornerIsYielded() {
        let shim = makeShim()
        // Well inside the 13 pt the badge covers.
        #expect(yields(shim, at: CGPoint(x: size.width - 4, y: 4)))
    }

    /// The regression: 13 pt in from the corner is the badge's inner edge, and
    /// everything past it belongs to the cell again. This band used to be dead.
    @Test func justInsideTheBadgeTheCellAnswersAgain() {
        let shim = makeShim()
        let coverage = ArchiveDeleteBadge.cornerCoverage(bleed: 3)
        // The band the old 16 pt square swallowed: between the badge's reach
        // and the round number it was approximated with.
        for x in stride(from: size.width - 16, to: size.width - coverage, by: 0.5) {
            #expect(!yields(shim, at: CGPoint(x: x, y: 4)), "dead pixel at x=\(x)")
        }
        for y in stride(from: coverage + 0.5, through: 16, by: 0.5) {
            #expect(!yields(shim, at: CGPoint(x: size.width - 4, y: y)), "dead pixel at y=\(y)")
        }
    }

    /// The seam itself belongs to the badge on both axes. Which side gets the
    /// boundary matters less than it being the same side on each — a point can
    /// only be claimed once, and this is where it is claimed.
    @Test func theEdgeOfTheCoveredCornerGoesToTheBadge() {
        let shim = makeShim()
        let coverage = ArchiveDeleteBadge.cornerCoverage(bleed: 3)
        #expect(yields(shim, at: CGPoint(x: size.width - 4, y: coverage)))
        #expect(yields(shim, at: CGPoint(x: size.width - coverage, y: 4)))
    }

    @Test func therestOfTheCellIsTheCells() {
        let shim = makeShim()
        #expect(!yields(shim, at: CGPoint(x: 4, y: 4)))                        // top-left
        #expect(!yields(shim, at: CGPoint(x: size.width / 2, y: size.height / 2)))
        #expect(!yields(shim, at: CGPoint(x: size.width - 4, y: size.height - 4)))  // bottom-right
    }

    /// The coverage is derived, not written down twice: a badge that stopped
    /// bleeding out would hand its whole side back to the shim.
    @Test func coverageFollowsTheBleed() {
        #expect(ArchiveDeleteBadge.cornerCoverage(bleed: 0) == ArchiveDeleteBadge.side)
        #expect(ArchiveDeleteBadge.cornerCoverage(bleed: 3) == ArchiveDeleteBadge.side - 3)
        // A bleed past the badge's own size can't invert the rect.
        #expect(ArchiveDeleteBadge.cornerCoverage(bleed: 99) == 0)
    }
}
