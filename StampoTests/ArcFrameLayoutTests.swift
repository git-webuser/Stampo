import CoreGraphics
import Testing
@testable import Stampo

@MainActor @Suite struct ArcFrameLayoutTests {
    @Test func minimumWindowLeaves345PointsForThePanel() {
        #expect(ArcFrameLayout.panelWidthLimit(windowWidth: 1140) == 345)
    }

    @Test func widerWindowAllowsTheFullPanel() {
        #expect(ArcFrameLayout.panelWidthLimit(windowWidth: 1280) == 400)
    }

    @Test func fullPanelStartsAt1195Points() {
        #expect(ArcFrameLayout.panelWidthLimit(windowWidth: 1195) == 400)
    }

    @Test func onePointBelowTheBoundaryLimitsThePanel() {
        #expect(ArcFrameLayout.panelWidthLimit(windowWidth: 1194) == 399)
    }

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
        #expect(ArcFrameLayout.dividerThickness == 8)
        #expect(ArcFrameLayout.minimumWidth == 1140)
    }

    @Test func legacyEditorConstantsKeepTheirExistingSizes() {
        #expect(EditorView.minimumContentSize == CGSize(width: 900, height: 360))
        #expect(EditorView.presentationInspectorMinimumWidth == 320)
        #expect(EditorView.presentationInspectorIdealWidth == 360)
        #expect(EditorView.presentationInspectorMaximumWidth == 460)
    }
}
