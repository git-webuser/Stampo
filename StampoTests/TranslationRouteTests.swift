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

    @Test func englishTargetSendsEnglishTextAway() {
        // Mirror of the Cyrillic case for a user whose target is English:
        // English in, and the fallback has to take it somewhere else.
        let pair = TranslationService.route(for: "Screenshot", target: en,
                                            away: ru)
        #expect(pair.source.languageCode?.identifier == "en")
        #expect(pair.target.languageCode?.identifier == "ru")
    }
}
