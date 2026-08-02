import Foundation
import Testing
@testable import Stampo

/// The drop band is split in two, and the split is decided by arithmetic the
/// user never sees — so it is worth pinning down where the boundary sits and,
/// more importantly, which side ambiguous drops fall on.
@Suite struct ArchiveDropZoneTests {

    /// Notch style: 15pt shoulder + 5pt plate gap on each side.
    private let notch = ArchiveDropLayout(totalWidth: 600, sideInset: 20)
    /// Rounded style: the plates sit 5pt from a straight edge.
    private let rounded = ArchiveDropLayout(totalWidth: 600, sideInset: 5)

    @Test func airDropTakesTheSmallerLeadingShare() {
        #expect(notch.airDropWidth < notch.archiveWidth)
        // Band, gap and plates account for the full width.
        #expect(notch.airDropWidth + notch.gap + notch.archiveWidth == notch.bandWidth)
        #expect(notch.sideInset * 2 + notch.bandWidth == notch.totalWidth)
    }

    @Test func theBoundarySitsInTheMiddleOfTheGap() {
        let leftEdgeOfArchive = notch.sideInset + notch.airDropWidth + notch.gap
        #expect(notch.boundaryX > notch.sideInset + notch.airDropWidth)
        #expect(notch.boundaryX < leftEdgeOfArchive)
        #expect(notch.zone(atX: notch.boundaryX - 1) == .airDrop)
        #expect(notch.zone(atX: notch.boundaryX + 1) == .archive)
    }

    @Test func pointsOverEachPlateResolveToIt() {
        #expect(notch.zone(atX: notch.sideInset + 1) == .airDrop)
        #expect(notch.zone(atX: notch.sideInset + notch.airDropWidth - 1) == .airDrop)
        #expect(notch.zone(atX: notch.totalWidth - notch.sideInset - 1) == .archive)
        #expect(notch.zone(atX: notch.totalWidth / 2) == .archive)
    }

    /// The shoulders are outside both plates but still inside the panel; a drop
    /// there must keep the files rather than fire a send sheet nobody aimed at.
    @Test func theShouldersFallBackToTheArchive() {
        #expect(notch.zone(atX: 0) == .archive)
        #expect(notch.zone(atX: notch.sideInset - 1) == .archive)
        #expect(notch.zone(atX: notch.totalWidth) == .archive)
        #expect(notch.zone(atX: notch.totalWidth + 50) == .archive)
    }

    @Test func aPanelTooNarrowForASplitIsAllArchive() {
        let tiny = ArchiveDropLayout(totalWidth: 30, sideInset: 20)
        #expect(tiny.bandWidth == 0)
        #expect(tiny.airDropWidth == 0)
        #expect(tiny.zone(atX: 15) == .archive)
        #expect(tiny.zone(atX: 25) == .archive)
    }

    @Test func bothPanelStylesKeepTheSameProportions() {
        #expect(rounded.bandWidth > notch.bandWidth)   // less inset, wider band
        for layout in [notch, rounded] {
            let usable = layout.bandWidth - layout.gap
            #expect(abs(layout.airDropWidth / usable - layout.airDropFraction) < 0.0001)
        }
    }
}
