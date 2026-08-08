import AppKit
import Testing
@testable import Stampo

/// The Translator sizes itself to its text before it is drawn. That is the
/// whole reason the measurement is a function of the string and the width
/// rather than something read back out of a layout pass, and it is the part
/// worth holding still.
@MainActor
@Suite struct TranslatePanelHeightTests {

    private let width: CGFloat = 420

    @Test func aShortTranslationSitsOnTheFloor() {
        let height = TranslationPanelModel.height(of: "Готово", width: width)
        #expect(height == NotchTranslateView.minBodyHeight)
    }

    @Test func emptyTextStillHasAPanel() {
        // Nothing to show is not the same as no panel: the route can be
        // reached before a result lands, and a zero-height body would leave
        // the shape collapsed into its own corners.
        #expect(TranslationPanelModel.height(of: "", width: width)
                == NotchTranslateView.minBodyHeight)
    }

    @Test func aLongTranslationStopsAtTheCeiling() {
        let long = String(repeating: "Снимок экрана, сканер и палитра цветов для macOS. ", count: 40)
        let height = TranslationPanelModel.height(of: long, width: width)
        #expect(height == NotchTranslateView.maxBodyHeight)
    }

    @Test func heightGrowsWithTheTextBeforeTheCeiling() {
        let one = TranslationPanelModel.height(of: "One line of translated text.", width: width)
        let many = TranslationPanelModel.height(
            of: String(repeating: "One line of translated text. ", count: 4), width: width)
        #expect(many > one)
        #expect(many <= NotchTranslateView.maxBodyHeight)
    }

    @Test func narrowerPanelsNeedMoreHeight() {
        // The same sentence wraps more in a narrower panel, which is why the
        // width has to be handed in rather than assumed.
        let text = String(repeating: "Screenshot, scan and colour picker. ", count: 3)
        let wide = TranslationPanelModel.height(of: text, width: 520)
        let narrow = TranslationPanelModel.height(of: text, width: 260)
        #expect(narrow >= wide)
    }

    @Test func aDegenerateWidthNeverProducesADegeneratePanel() {
        // Called before the panel has geometry, or on a screen that reports
        // nothing useful: the answer still has to be a height a panel can be.
        for width in [CGFloat(0), 1, -50] {
            let height = TranslationPanelModel.height(of: "Anything at all", width: width)
            #expect(height >= NotchTranslateView.minBodyHeight)
            #expect(height <= NotchTranslateView.maxBodyHeight)
        }
    }

    @Test func everyHeightFitsBetweenTheFloorAndTheArtwork() {
        // The ceiling is the exported shape's body: 168 tall overall against
        // the archive's 89. Anything past it would draw outside the panel.
        // Stated as the panel it produces, not as arithmetic: the artwork is
        // 168 tall and the notch strip on top of it is 34.
        #expect(34 + NotchTranslateView.maxBodyHeight == 168)
        #expect(NotchTranslateView.minBodyHeight < NotchTranslateView.maxBodyHeight)
    }
}
