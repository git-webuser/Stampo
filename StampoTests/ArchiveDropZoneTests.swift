import Foundation
import Testing
@testable import Stampo

/// The drop band is split into ordered plates, and the split is decided by
/// arithmetic the user never sees — so it is worth pinning down every boundary
/// and, more importantly, which side ambiguous drops fall on.
@Suite struct ArchiveDropZoneTests {

    /// Notch style: 15pt shoulder + 5pt plate gap on each side.
    private let notch = ArchiveDropLayout(totalWidth: 600, sideInset: 20)
    /// Rounded style: the plates sit 5pt from a straight edge.
    private let rounded = ArchiveDropLayout(totalWidth: 600, sideInset: 5)

    @Test func archiveTakesTheWidestShare() {
        let widths = notch.plateWidths
        #expect(widths[1] > widths[0])
        #expect(widths[1] > widths[2])
    }

    @Test func platesAndGapsAccountForTheWholeBand() {
        #expect(abs(notch.plateWidths.reduce(0, +)
                   + notch.gap * CGFloat(notch.plates.count - 1)
                   - notch.bandWidth) < 0.0001)
        #expect(notch.sideInset * 2 + notch.bandWidth == notch.totalWidth)
    }

    @Test func everyBoundarySitsInTheMiddleOfItsGap() {
        var plateEnd = notch.sideInset + notch.plateWidths[0]
        for index in 0..<(notch.plates.count - 1) {
            let boundary = plateEnd + notch.gap / 2
            #expect(notch.zone(atX: boundary - 1) == notch.plates[index].zone)
            #expect(notch.zone(atX: boundary + 1) == notch.plates[index + 1].zone)
            plateEnd += notch.gap + notch.plateWidths[index + 1]
        }
    }

    @Test func pointsOverEachPlateResolveToIt() {
        var plateStart = notch.sideInset
        for (index, plate) in notch.plates.enumerated() {
            #expect(notch.zone(atX: plateStart + notch.plateWidths[index] / 2) == plate.zone)
            plateStart += notch.plateWidths[index] + notch.gap
        }
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
        #expect(tiny.plateWidths.allSatisfy { $0 == 0 })
        #expect(tiny.zone(atX: 15) == .archive)
        #expect(tiny.zone(atX: 25) == .archive)
    }

    @Test func bothPanelStylesKeepTheSameProportions() {
        #expect(rounded.bandWidth > notch.bandWidth)   // less inset, wider band
        for layout in [notch, rounded] {
            let usable = layout.bandWidth - layout.gap * CGFloat(layout.plates.count - 1)
            #expect(abs(layout.plateWidths[0] / usable - layout.plates[0].fraction) < 0.0001)
            #expect(abs(layout.plateWidths[1] / usable - layout.plates[1].fraction) < 0.0001)
            #expect(abs(layout.plateWidths[2] / usable - layout.plates[2].fraction) < 0.0001)
        }
    }

    @Test func zoneLookupFollowsTheTableEvenWhenOrderChanges() {
        let layout = ArchiveDropLayout(
            totalWidth: 600,
            sideInset: 20,
            plates: [
                .init(zone: .editor, fraction: 0.20),
                .init(zone: .archive, fraction: 0.60),
                .init(zone: .airDrop, fraction: 0.20)
            ]
        )

        var plateStart = layout.sideInset
        for (index, plate) in layout.plates.enumerated() {
            #expect(layout.zone(atX: plateStart + layout.plateWidths[index] / 2) == plate.zone)
            plateStart += layout.plateWidths[index] + layout.gap
        }
    }
}
