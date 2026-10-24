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
