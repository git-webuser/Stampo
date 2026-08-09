import Foundation
import Testing
@testable import Stampo

/// The pure half of the translation facade: deciding which way to translate.
/// Everything else in `TranslationService` needs a live session and a mounted
/// view, so this is the part a test can hold.
@MainActor
@Suite struct TranslationRouteTests {

    private let ru = Locale.Language(identifier: "ru")
    private let en = Locale.Language(identifier: "en")

    @Test func latinTextGoesToThePreferredTarget() {
        let pair = TranslationService.route(for: "Nothing leaves your Mac.", target: ru)
        #expect(pair.source.languageCode?.identifier == "en")
        #expect(pair.target.languageCode?.identifier == "ru")
    }

    @Test func cyrillicTextGoesTheOtherWay() {
        // Already in the target language: translating it into itself is the
        // one outcome that is never what was wanted.
        let pair = TranslationService.route(for: "Снимок экрана", target: ru)
        #expect(pair.source.languageCode?.identifier == "ru")
        #expect(pair.target.languageCode?.identifier == "en")
    }

    @Test func mixedTextFollowsItsCyrillic() {
        // Real scans are rarely pure: a Russian sentence quoting an English
        // product name must still be treated as Russian.
        let pair = TranslationService.route(for: "Открой Stampo и нажми ⌘C", target: ru)
        #expect(pair.source.languageCode?.identifier == "ru")
        #expect(pair.target.languageCode?.identifier == "en")
    }

    @Test func punctuationAndDigitsAreNotCyrillic() {
        // A scan of a price tag or a version number has no letters at all;
        // it must not be mistaken for the target language and bounced back.
        let pair = TranslationService.route(for: "1 234,56 — v2.7.1 (#42)", target: ru)
        #expect(pair.source.languageCode?.identifier == "en")
        #expect(pair.target.languageCode?.identifier == "ru")
    }

    @Test func targetOtherThanRussianKeepsLatinSourceIntact() {
        // The heuristic is two-language today, but it must not hardcode the
        // pair: with German as the target, English text still goes to German.
        let de = Locale.Language(identifier: "de")
        let pair = TranslationService.route(for: "Screenshot and scan", target: de)
        #expect(pair.source.languageCode?.identifier == "en")
        #expect(pair.target.languageCode?.identifier == "de")
    }

    @Test func englishRussianRouteFlipsWithTheText() {
        // The shipping entry point: one call, no target to pass, direction
        // read off the text in both directions.
        let out = TranslationService.englishRussianRoute(for: "Nothing leaves your Mac.")
        #expect(out.source.languageCode?.identifier == "en")
        #expect(out.target.languageCode?.identifier == "ru")

        let back = TranslationService.englishRussianRoute(for: "Снимок экрана")
        #expect(back.source.languageCode?.identifier == "ru")
        #expect(back.target.languageCode?.identifier == "en")
    }

    @Test func englishRussianRouteNeverTranslatesIntoItself() {
        // The failure this pair makes easy: a direction whose two ends match
        // would ask the framework to translate Russian into Russian.
        for text in ["Привет", "Hello", "1 234,56", "", "Открой Stampo"] {
            let pair = TranslationService.englishRussianRoute(for: text)
            #expect(pair.source.languageCode != pair.target.languageCode)
        }
    }

    // MARK: Explicit picks

    /// The bug this pair of functions was split to fix: the menu named the
    /// target, and picking the language the text was already in handed back the
    /// other one — so every entry in a two-language menu produced the same
    /// result while appearing to offer a choice.
    @Test func aPickedLanguageIsNeverTurnedIntoItsOpposite() {
        let picked = TranslationService.explicitRoute(for: "Снимок экрана", to: en)
        #expect(picked?.source.languageCode?.identifier == "ru")
        #expect(picked?.target.languageCode?.identifier == "en")

        // The automatic route still flips — that is what it is for.
        let automatic = TranslationService.route(for: "Снимок экрана", target: ru)
        #expect(automatic.target.languageCode?.identifier == "en")
    }

    @Test func pickingTheLanguageTheTextIsInIsRefusedRatherThanReversed() {
        #expect(TranslationService.explicitRoute(for: "Снимок экрана", to: ru) == nil)
        #expect(TranslationService.explicitRoute(for: "Screenshot and scan", to: en) == nil)
    }

    /// The panel shows a text and the language it is in, and a pick translates
    /// *that* text. Chained: Russian → English → German is en→de at the last
    /// step, not ru→de. With two languages the difference cannot be seen; with
    /// three it is the whole behaviour, so it is pinned before there are three.
    @Test func aChainTranslatesWhatIsOnScreenNotTheOriginal() {
        let shown = TranslationPanelModel.Result.preview(of: "Снимок экрана")
        #expect(shown.language.languageCode?.identifier == "ru")

        let step = TranslationService.explicitRoute(for: shown.text, to: en)
        #expect(step?.source.languageCode?.identifier == "ru")

        // Whatever comes back is now the text, in the language just asked for —
        // and the next step starts from there.
        let next = TranslationPanelModel.Result(text: "Screenshot", language: en)
        #expect(TranslationService.explicitRoute(for: next.text, to: ru)?
            .source.languageCode?.identifier == "en")
    }

    @Test func aPreviewKnowsWhichLanguageItIsShowing() {
        #expect(TranslationPanelModel.Result.preview(of: "Screenshot and scan")
            .language.languageCode?.identifier == "en")
        #expect(TranslationPanelModel.Result.preview(of: "Снимок экрана")
            .language.languageCode?.identifier == "ru")
    }

    @Test func detectionIsTheSameWhicheverRouteAsksForIt() {
        for text in ["Снимок экрана", "Screenshot", "1 234,56", ""] {
            let source = TranslationService.detectedSource(of: text)
            #expect(TranslationService.route(for: text, target: ru).source == source)
            if let explicit = TranslationService.explicitRoute(for: text, to: ru) {
                #expect(explicit.source == source)
            }
        }
    }

    @Test func englishTargetSendsEnglishTextAway() {
        // Mirror of the Cyrillic case for a user whose target is English:
        // English in, and the fallback has to take it somewhere else.
        let pair = TranslationService.route(for: "Screenshot", target: en,
                                            away: ru)
        #expect(pair.source.languageCode?.identifier == "en")
        #expect(pair.target.languageCode?.identifier == "ru")
    }
}
