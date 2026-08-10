import Foundation
import Testing
@testable import Stampo

/// The pure half of the translation facade: reading which language a text is
/// in, and deciding which way to translate it. Everything else in
/// `TranslationService` needs a live session and a mounted view, so this is the
/// part a test can hold.
@MainActor
@Suite struct TranslationRouteTests {

    private let ru = Locale.Language(identifier: "ru")
    private let en = Locale.Language(identifier: "en")
    private let de = Locale.Language(identifier: "de")

    /// The nineteen macOS can translate, as measured — a curated list is not
    /// needed and would go stale.
    private let supported: Set<String> = ["ar", "de", "en", "es", "fr", "hi", "id", "it",
                                          "ja", "ko", "nl", "pl", "pt", "ru", "th", "tr",
                                          "uk", "vi", "zh"]

    private func detect(_ text: String, installed: Set<String> = ["en", "ru"]) -> DetectedLanguage {
        TranslationService.detect(text, supported: supported, installed: installed)
    }

    // MARK: Detection

    @Test func aSentenceIsReadInItsOwnLanguage() {
        #expect(detect("Nothing leaves your Mac.") == .installed(en))
        #expect(detect("Снимок экрана сохранён") == .installed(ru))
    }

    @Test func mixedTextFollowsTheLanguageItIsWrittenIn() {
        // Real scans are rarely pure: a Russian sentence quoting an English
        // product name is still Russian. Detection reads letter statistics, so
        // the borrowed word does not move it.
        #expect(detect("Открой Stampo и нажми ⌘C") == .installed(ru))
    }

    @Test func aLanguageWithNoPackIsAnOfferRatherThanAFailure() {
        // The most useful thing the rule does: the app names what it saw, and
        // the refusal becomes an invitation.
        #expect(detect("Bildschirmfoto wurde gespeichert") == .notInstalled(de))
        // Downloaded, and the same text now translates instead.
        #expect(detect("Bildschirmfoto wurde gespeichert",
                       installed: ["en", "ru", "de"]) == .installed(de))
    }

    @Test func shortStringsAreRescuedBySkippingWhatMacOSCannotTranslate() {
        // Measured misses, both of them languages macOS cannot translate at
        // all: "Привет" ranks Bulgarian first at 0.53, above the correct
        // Russian at 0.42. Dropping the hypotheses the app could never act on
        // leaves the right answer underneath — which is also why confidence
        // must not be a gate.
        #expect(detect("Привет") == .installed(ru))
        #expect(detect("Settings") == .installed(en))
    }

    @Test func oneWordNeverAsksForADownload() {
        // "Download" ranks Indonesian first — real ambiguity that no scan
        // quality fixes. Asking for several hundred megabytes on the strength
        // of one common word is worse than quietly using the best installed
        // language, so the offer needs two words and this falls through to
        // English, which the ranking puts ninth.
        #expect(detect("Download") == .installed(en))
        #expect(detect("Download", installed: ["en", "ru", "id"]) == .installed(id: "id"))
    }

    @Test func digitsAndPunctuationCannotTalkTheAppIntoADownload() {
        // A scanned price tag or version number is several tokens of no
        // language at all. It must never produce an offer, whatever the
        // recognizer ranks first.
        for text in ["1 234,56 — v2.7.1 (#42)", "42 €", "#tag"] {
            if case .notInstalled = detect(text) {
                Issue.record("offered a download for \(text)")
            }
        }
    }

    @Test func nothingRecognizableIsSaidRatherThanGuessed() {
        #expect(detect("") == .unknown)
        #expect(detect("   \n ") == .unknown)
        // No installed language to fall back on either.
        #expect(detect("Bildschirmfoto wurde gespeichert", installed: []) == .notInstalled(de))
    }

    // MARK: Scripts

    /// The failure that only appears once a third language is a real one:
    /// `NLLanguageRecognizer` weighs by character, so one Latin product name
    /// outweighs a whole Chinese sentence. Unhelped, "在 Finder 中显示" comes
    /// back Danish at 0.93 with Chinese absent from the ranking entirely — and
    /// the app would have offered to download Danish.
    @Test func denseScriptsAreNotOutvotedByABorrowedWord() {
        let installed: Set<String> = ["en", "ru", "zh"]
        #expect(detect("打开 Stampo 并按 ⌘C", installed: installed) == .installed(id: "zh"))
        #expect(detect("在 Finder 中显示", installed: installed) == .installed(id: "zh"))
        #expect(detect("屏幕截图已保存到 Downloads", installed: installed) == .installed(id: "zh"))
        #expect(detect("설정 열기 Finder", installed: ["en", "ko"]) == .installed(id: "ko"))
        #expect(detect("スクリーンショットを保存 Downloads", installed: ["en", "ja"]) == .installed(id: "ja"))
    }

    @Test func aBorrowedWordDoesNotTakeOverTheOtherWayRound() {
        // The mirror case, which the recognizer already gets right and must
        // keep getting right: an English sentence quoting a foreign term is
        // English, not the term's language.
        #expect(detect("Open 设置 now to continue") == .installed(en))
        #expect(detect("Press 확인 to continue") == .installed(en))
        #expect(detect("The Русский option is here") == .installed(en))
    }

    /// A tie used to be broken by `Dictionary.max`, which answers in hash
    /// order — and Swift seeds that per process, so the same text could be
    /// filtered on one launch and not on the next. "打开 Stampo" is exactly a
    /// tie: two Han characters at weight three against six Latin letters.
    @Test func anExactTieResolvesTheSameWayEveryTime() {
        let text = "打开 Stampo"
        let filtered = TranslationService.recognizableText(in: text)
        #expect(!filtered.contains("S"), "the borrowed Latin name must lose the tie")
        #expect(filtered.contains("打"))
        #expect(detect(text, installed: ["en", "ru", "zh"]) == .installed(id: "zh"))
        // Stability across launches comes from `Script.rank` being a total
        // order; what can be pinned from here is the outcome it produces, and
        // that outcome is what the hash-ordered version could not promise.
    }

    @Test func latinTextIsHandedOverUntouched() {
        // What keeps every earlier measurement of the rule valid: all of it
        // was Latin and Cyrillic, and neither is filtered.
        let text = "Nothing leaves your Mac."
        #expect(TranslationService.recognizableText(in: text) == text)
        let mixed = "Открой Stampo и нажми ⌘C"
        #expect(TranslationService.recognizableText(in: mixed) != mixed)
        #expect(detect(mixed) == .installed(ru))
    }

    // MARK: Explicit picks

    /// The bug the two route functions were split to prevent: the menu named
    /// the target, and picking the language the text was already in handed back
    /// a different one — so every entry appeared to offer a choice and produced
    /// the same result.
    @Test func aPickedLanguageIsNeverTurnedIntoItsOpposite() {
        #expect(TranslationService.route(from: .installed(ru), to: en)
                == .translate(TranslationPair(source: ru, target: en)))
    }

    @Test func pickingTheLanguageTheTextIsInIsRefusedRatherThanReversed() {
        #expect(TranslationService.route(from: .installed(ru), to: ru) == .alreadyThere)
        #expect(TranslationService.route(from: .installed(en), to: en) == .alreadyThere)
    }

    /// The panel shows a text and the language it is in, and a pick translates
    /// *that* text: Russian → English → German is en→de at the last step, not
    /// ru→de. Each step starts from what is on screen rather than from an
    /// original nobody can see any more.
    @Test func aChainTranslatesWhatIsOnScreenNotTheOriginal() {
        let shown = "Снимок экрана сохранён"
        #expect(TranslationService.route(from: detect(shown), to: en)
                == .translate(TranslationPair(source: ru, target: en)))

        // Whatever came back is now the text, and the next step reads it.
        let next = "The screenshot was saved"
        #expect(TranslationService.route(from: detect(next, installed: ["en", "ru", "de"]), to: de)
                == .translate(TranslationPair(source: en, target: de)))
    }

    @Test func aPickCarriesTheMissingSourceThroughSoItCanBeNamed() {
        #expect(TranslationService.route(from: .notInstalled(de), to: ru) == .sourceMissing(de))
        #expect(TranslationService.route(from: .unknown, to: ru) == .unknownSource)
    }

    // MARK: Automatic direction

    @Test func textGoesToTheTargetWhenItIsNotAlreadyThere() {
        #expect(TranslationService.automaticRoute(from: .installed(en),
                                                  destination: ru, favourites: [ru, en])
                == .translate(TranslationPair(source: en, target: ru)))
    }

    @Test func twoLanguagesStillFlipTheWayTheyAlwaysHave() {
        // The shipped behaviour: with one other place the text could go, going
        // there is what Translate has always meant, and no choice is being
        // invented.
        #expect(TranslationService.automaticRoute(from: .installed(ru),
                                                  destination: ru, favourites: [ru, en])
                == .translate(TranslationPair(source: ru, target: en)))
    }

    @Test func threeLanguagesRefuseToGuessWhichWayToFlip() {
        // Several places it could go and no way to show which was chosen, so
        // the honest answer is that it is already in that language — the menus
        // are where a target gets picked.
        #expect(TranslationService.automaticRoute(from: .installed(ru),
                                                  destination: ru, favourites: [ru, en, de])
                == .alreadyThere)
    }

    @Test func anAutomaticRouteNeverTranslatesSomethingIntoItself() {
        // The failure this makes easy: a direction whose two ends match asks
        // the framework to translate Russian into Russian.
        for favourites in [[ru, en], [ru, en, de], [ru]] {
            for detected in [DetectedLanguage.installed(ru), .installed(en), .installed(de)] {
                let route = TranslationService.automaticRoute(from: detected,
                                                              destination: ru,
                                                              favourites: favourites)
                if case .translate(let pair) = route {
                    #expect(pair.source.baseCode != pair.target.baseCode)
                }
            }
        }
    }

    /// The dead end that shipped for a day: a language chosen in passing on the
    /// scan overlay became the destination the clipboard hotkey used, and text
    /// in *that* language then had nowhere to go — refused by a toast with no
    /// control on it. The route still refuses, correctly; what changed is that
    /// the destination is now a setting nothing writes behind the user's back,
    /// and the refusal opens the panel where a language can be picked.
    @Test func textInTheDestinationLanguageIsRefusedRatherThanMisrouted() {
        let zh = Locale.Language(identifier: "zh")
        #expect(TranslationService.automaticRoute(from: .installed(zh),
                                                  destination: zh,
                                                  favourites: [ru, en, zh])
                == .alreadyThere)
        // And with the destination back where it belongs, the same text moves.
        #expect(TranslationService.automaticRoute(from: .installed(zh),
                                                  destination: ru,
                                                  favourites: [ru, en, zh])
                == .translate(TranslationPair(source: zh, target: ru)))
    }

    @Test func aMissingSourceSurvivesTheAutomaticRouteToo() {
        #expect(TranslationService.automaticRoute(from: .notInstalled(de),
                                                  destination: ru, favourites: [ru, en])
                == .sourceMissing(de))
    }

    // MARK: The panel's pop-up

    /// The pop-up is a pull-down, so its first item is a hidden title and the
    /// languages start one along. Off by one here does not crash — it
    /// translates into the language next to the one that was pressed.
    @Test func theMenuMapsEveryRowToWhatItSays() {
        let languages = [ru, en, de]
        #expect(TranslateLanguageMenu.selection(atItemIndex: 0, in: languages) == nil)
        #expect(TranslateLanguageMenu.selection(atItemIndex: 1, in: languages) == ru)
        #expect(TranslateLanguageMenu.selection(atItemIndex: 2, in: languages) == en)
        #expect(TranslateLanguageMenu.selection(atItemIndex: 3, in: languages) == de)
    }

    @Test func everythingPastTheSeparatorLeavesForSettings() {
        let languages = [ru, en, de]
        // 4 is the separator's own index, 5 the "Add language…" row. Neither
        // is a language, and the separator cannot be clicked anyway.
        #expect(TranslateLanguageMenu.selection(atItemIndex: 4, in: languages) == nil)
        #expect(TranslateLanguageMenu.selection(atItemIndex: 5, in: languages) == nil)
        // An empty list is all Add row and nothing else.
        #expect(TranslateLanguageMenu.selection(atItemIndex: 1, in: []) == nil)
    }

    // MARK: The target the scanner cycles

    @Test func theTargetWrapsThroughTheUsersOwnOrder() {
        let order = [ru, en, de]
        #expect(TranslationLanguages.language(after: ru, in: order)?.baseCode == "en")
        #expect(TranslationLanguages.language(after: en, in: order)?.baseCode == "de")
        #expect(TranslationLanguages.language(after: de, in: order)?.baseCode == "ru")
    }

    @Test func shiftTabWalksTheSameListTheOtherWay() {
        let order = [ru, en, de]
        #expect(TranslationLanguages.language(after: ru, in: order, backwards: true)?.baseCode == "de")
        #expect(TranslationLanguages.language(after: de, in: order, backwards: true)?.baseCode == "en")
        #expect(TranslationLanguages.language(after: en, in: order, backwards: true)?.baseCode == "ru")
    }

    /// The primary language is only asked for once the list is long enough to
    /// show the row that sets it. Below that the row is hidden, and a setting
    /// in force with no control anywhere to read it off is worse than one that
    /// is dormant — so it is ignored rather than obeyed invisibly.
    @Test func aPrimaryLanguageIsIgnoredWhileItsRowIsHidden() {
        let de = Locale.Language(identifier: "de")
        #expect(TranslationLanguages.destination(primary: en, favourites: [ru, en, de]).baseCode == "en")
        // Third language removed: the row goes, and so does its effect.
        #expect(TranslationLanguages.destination(primary: en, favourites: [ru, en]).baseCode == "ru")
        // The stored answer is kept, not cleared — adding a third back
        // restores the choice rather than costing it.
        #expect(TranslationLanguages.destination(primary: en, favourites: [ru, en, de]).baseCode == "en")
    }

    @Test func withoutAPrimaryTheListDecides() {
        #expect(TranslationLanguages.destination(primary: nil, favourites: [ru, en]).baseCode == "ru")
        #expect(TranslationLanguages.destination(primary: nil, favourites: []).baseCode == "en")
    }

    @Test func aSingleLanguageHasNowhereToCycleTo() {
        #expect(TranslationLanguages.language(after: ru, in: [ru]) == nil)
        #expect(TranslationLanguages.language(after: ru, in: []) == nil)
        // A target that is no longer in the list still lands somewhere in it.
        #expect(TranslationLanguages.language(after: de, in: [ru, en])?.baseCode == "en")
    }
}

private extension DetectedLanguage {
    /// Spelling `.installed(Locale.Language(identifier:))` in every expectation
    /// buried what was being asserted.
    static func installed(id code: String) -> DetectedLanguage {
        .installed(Locale.Language(identifier: code))
    }
}
