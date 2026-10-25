import AppKit
import SwiftUI
import Testing
@testable import Stampo

@MainActor @Suite struct ArcFrameLayoutTests {
    @Test func wideScreenKeepsTheNormalWindowMinimum() {
        #expect(ArcFrameLayout.minimumContentWidth(visibleScreenWidth: 1470) == 1140)
    }

    @Test func narrowScreenLimitsTheWindowMinimum() {
        #expect(ArcFrameLayout.minimumContentWidth(visibleScreenWidth: 1024) == 1024)
    }

    @Test func arcConstantsKeepTheApprovedColumnSizes() {
        #expect(ArcFrameLayout.panelDefaultWidth == 320)
        #expect(ArcFrameLayout.panelMinimumWidth == PresentationInspector.contentMinimumWidth)
        #expect(ArcFrameLayout.panelMinimumWidth == 320)
        #expect(ArcFrameLayout.panelMaximumWidth == 400)
        #expect(ArcFrameLayout.detailMinimumWidth == 787)
        #expect(ArcFrameLayout.frameGap == 8)
        #expect(ArcFrameLayout.cardCornerRadius == 10)
        #expect(ArcFrameLayout.minimumWidth == 1140)
    }

    /// The toolbar's own 8pt gap is not repeated; the panel adds 6pt so the
    /// first header's centre stands on the second line's axis (see `panelTopInset`).
    @Test func panelInsetsPutTheFirstHeaderOnTheSecondLinesAxis() {
        #expect(ArcFrameLayout.panelTopInset == 6)
        let insets = ArcFrameLayout.panelContentInsets
        #expect(insets.top == 6)
        #expect(insets.leading == 8)
        #expect(insets.bottom == 8)
        #expect(insets.trailing == 0)
    }

    /// The compact colour button's one place for its size, so a rollback is
    /// one edit: 28pt of label plus the bordered style's 24 makes 52.
    @Test func colourButtonKeepsItsApprovedSize() {
        #expect(ColorPopoverButton.dotSide == 16)
        #expect(ColorPopoverButton.labelWidth == 28)
    }

    @Test func frameColorChangesWithAppearance() throws {
        let light = try resolved(ArcFrameLayout.frameColor, appearance: .aqua)
        let dark = try resolved(ArcFrameLayout.frameColor, appearance: .darkAqua)
        #expect(light != dark)
    }

    @Test func frameColorIsDifferentFromTheCardInBothAppearances() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let frame = try resolved(ArcFrameLayout.frameColor, appearance: appearance)
            let card = try resolved(NSColor.textBackgroundColor, appearance: appearance)
            #expect(frame != card)
        }
    }

    @Test func settingsRowThresholdsKeepTheApprovedBand() {
        #expect(ArcFrameLayout.settingsRowCompactBelow == 896)
        #expect(ArcFrameLayout.settingsRowExpandAtOrAbove == 904)
    }

    /// The widest line is "Text" with its colours, 895.5pt wide plus 12pt
    /// of margin each side. 896 is the first card width that is not folded.
    @Test func settingsRowFoldsOnlyBelowTheThresholdFromTheOpenForm() {
        let table: [(width: CGFloat, folded: Bool)] = [
            (804, true), (895.9, true), (896, false), (904, false), (1124, false)
        ]
        for (width, folded) in table {
            #expect(ArcFrameLayout.settingsRowIsCompact(cardWidth: width, wasCompact: false) == folded,
                    "open form at \(width)")
        }
    }

    @Test func settingsRowStaysFoldedUntilTheCardClearsTheBand() {
        let table: [(width: CGFloat, folded: Bool)] = [
            (804, true), (896, true), (903.9, true), (904, false), (1124, false)
        ]
        for (width, folded) in table {
            #expect(ArcFrameLayout.settingsRowIsCompact(cardWidth: width, wasCompact: true) == folded,
                    "folded form at \(width)")
        }
    }

    /// A card dragged across the band: each width answers from the previous
    /// answer, which is what the editor stores between layouts.
    @Test func settingsRowDoesNotFlickerAlongTheThreshold() {
        let widths: [CGFloat] = [910, 899, 895, 899, 903, 904, 899]
        let expected = [false, false, true, true, true, false, false]
        var folded = false
        var seen: [Bool] = []
        for width in widths {
            folded = ArcFrameLayout.settingsRowIsCompact(cardWidth: width, wasCompact: folded)
            seen.append(folded)
        }
        #expect(seen == expected)
    }

    /// Only the Arc card sets the fold. A window that never does — the drawn
    /// rows of the old editor, macOS 15.7 — reads the default and keeps its swatches.
    @Test func settingsRowIsOpenUnlessTheCardFoldsIt() {
        #expect(EnvironmentValues().settingsRowCompact == false)
    }

    /// The dot grid's look in one place, so taking it back is one edit.
    @Test func dotGridKeepsItsApprovedLook() {
        #expect(ArcFrameLayout.dotStep == 24)
        #expect(ArcFrameLayout.dotDiameter == 2.6)
        #expect(ArcFrameLayout.dotOpacity == 0.14)
    }

    /// 944 × 650 is the canvas of a 1140 × 720 window with the panel shut;
    /// 1500 × 900 is a large one.
    @Test func dotsStartHalfAStepInAndFillTheArea() {
        let small = ArcFrameLayout.dotCenters(in: CGSize(width: 944, height: 650))
        #expect(small.count == 39 * 27)
        #expect(small.count == 1053)
        #expect(small.first == CGPoint(x: 12, y: 12))
        #expect(small.last == CGPoint(x: 12 + 24 * 38, y: 12 + 24 * 26))
        #expect(small.last == CGPoint(x: 924, y: 636))
        #expect(ArcFrameLayout.dotCenters(in: CGSize(width: 1500, height: 900)).count == 62 * 37)
    }

    @Test func dotsStandOnOneGridInReadingOrder() {
        let centers = ArcFrameLayout.dotCenters(in: CGSize(width: 100, height: 70))
        let columns = [12, 36, 60, 84].map { CGFloat($0) }
        let rows = [12, 36, 60].map { CGFloat($0) }
        let expected = rows.flatMap { y in columns.map { CGPoint(x: $0, y: y) } }
        #expect(centers == expected)
    }

    @Test func aDotsCentreOnTheEdgeIsOutside() {
        let step = ArcFrameLayout.dotStep
        // A centre exactly on the edge is out; a hair more width brings the next one in.
        #expect(ArcFrameLayout.dotCenters(in: CGSize(width: step * 1.5, height: step)).count == 1)
        #expect(ArcFrameLayout.dotCenters(in: CGSize(width: step * 1.5 + 0.5, height: step)).count == 2)
        #expect(ArcFrameLayout.dotCenters(in: CGSize(width: step, height: step * 1.5)).count == 1)
        #expect(ArcFrameLayout.dotCenters(in: CGSize(width: step, height: step * 1.5 + 0.5)).count == 2)
    }

    @Test func noAreaNoDots() {
        let sizes: [CGSize] = [
            .zero, CGSize(width: 0, height: 650), CGSize(width: 944, height: 0),
            CGSize(width: -10, height: 650), CGSize(width: 944, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: 650), CGSize(width: 944, height: CGFloat.infinity)
        ]
        for size in sizes {
            #expect(ArcFrameLayout.dotCenters(in: size).isEmpty, "\(size)")
        }
    }

    @Test func legacyEditorConstantsKeepTheirExistingSizes() {
        #expect(EditorView.minimumContentSize == CGSize(width: 900, height: 360))
        #expect(EditorView.presentationInspectorMinimumWidth == 320)
        #expect(EditorView.presentationInspectorIdealWidth == 360)
        #expect(EditorView.presentationInspectorMaximumWidth == 460)
    }

    private func resolved(_ color: NSColor, appearance name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return try #require(result)
    }
}
