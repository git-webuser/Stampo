import AppKit
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

    @Test func panelInsetsDoNotRepeatTheNativeToolbarGap() {
        let insets = ArcFrameLayout.panelContentInsets
        #expect(insets.top == 0)
        #expect(insets.leading == 8)
        #expect(insets.bottom == 8)
        #expect(insets.trailing == 0)
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
