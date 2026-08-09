import AppKit
import SwiftUI

/// Translating an archive text entry into another archive text entry.
///
/// Translation produces a new entry rather than replacing the old one, and the
/// result is an ordinary `ArchiveText`: it copies on tap, drags out, shares,
/// and is removed like any other. Nothing about the archive learns that
/// translation exists — which is the whole reason this fits in one file.
enum ArchiveTranslate {

    /// One HUD for every translation, mirroring `AirDropSender`: the toast is
    /// a transient screen-level thing with no owner in the view tree, and a
    /// per-cell instance would go away with the cell that started the work.
    @MainActor private static let feedbackHUD = TextCaptureHUD()

    /// Lets the translator's own surfaces reach the same toast the archive
    /// path uses, so one outcome never gets two voices.
    static func report(_ outcome: TextCaptureHUD.Outcome, on screen: NSScreen?) {
        feedbackHUD.show(outcome, on: screen)
    }

    /// Translates `text` and files the result at the top of the archive.
    ///
    /// Nobody chose a target, so the app reads one: the source off the text,
    /// the destination off the user's setting. Every failure ends in the HUD
    /// rather than silently: the user asked for something visible to happen,
    /// so something visible has to happen even when it could not.
    static func run(_ text: String,
                    archiveModel: NotchArchiveModel,
                    on screen: NSScreen?) {
        let languages = TranslationLanguages.shared
        run(text,
            route: TranslationService.automaticRoute(from: TranslationService.detect(text),
                                                     destination: languages.destination,
                                                     favourites: languages.favourites),
            chosen: false,
            archiveModel: archiveModel, on: screen)
    }

    /// The same work for a language the user picked by hand, from a menu. The
    /// direction is not second-guessed here — an explicit pick is answered as
    /// asked or refused, never reversed.
    ///
    /// `nil` means nobody picked anything after all, which is what the scan
    /// overlay hands over when ⇥ was never pressed.
    static func run(_ text: String,
                    to target: Locale.Language?,
                    archiveModel: NotchArchiveModel,
                    on screen: NSScreen?) {
        guard let target else {
            run(text, archiveModel: archiveModel, on: screen)
            return
        }
        run(text,
            route: TranslationService.route(from: TranslationService.detect(text), to: target),
            chosen: true,
            archiveModel: archiveModel, on: screen)
    }

    /// Turns a route into either work or the one thing worth saying about why
    /// there is none.
    private static func run(_ text: String,
                            route: TranslationRoute,
                            chosen: Bool,
                            archiveModel: NotchArchiveModel,
                            on screen: NSScreen?) {
        guard case .translate(let pair) = route else {
            // Nothing is going to run, and the callers that dim the panel body
            // before asking cannot know that. `beginRework()` is normally
            // undone by `.translationDidEnd`, which is posted around the work
            // itself — so a route that produces no work left the body dimmed
            // for good, and ⇥ dead behind its own `!isReworking` guard.
            //
            // Cleared here rather than at each caller because this is the only
            // place that knows the answer, and the next caller to dim the panel
            // will be just as unable to tell.
            TranslationPanelModel.shared.endRework()
            report(route, chosen: chosen, for: text, on: screen)
            return
        }
        run(text, pair: pair, archiveModel: archiveModel, on: screen)
    }

    /// The one thing worth saying about why there is no translation.
    private static func report(_ route: TranslationRoute,
                               chosen: Bool,
                               for text: String,
                               on screen: NSScreen?) {
        switch route {
        case .translate:
            // Handled by the caller; here only because the switch is total.
            break
        case .alreadyThere where !chosen:
            // Nobody named a language, and the text is already in the one this
            // would have sent it to. A toast here was a dead end: it named the
            // problem and offered no way out, so text in the primary language
            // simply could not be translated at all from the hotkey.
            //
            // So the panel opens on it instead, where the header menu lists
            // every language and ⇥ steps them. The refusal becomes the
            // question it was standing in for — where should this go?
            NotificationCenter.default.post(name: .requestTranslatePreview, object: text)
        case .alreadyThere:
            // A language picked by hand, over text already in it. The menu is
            // already open in front of the user with the tick on the item they
            // just pressed, so there is nothing to offer them that they are not
            // already looking at.
            report(.translationUnchanged, on: screen)
        case .sourceMissing(let language):
            // The most useful thing the feature does: the app has read the
            // text, named the language, and the only thing missing is a
            // download. Same remedy as a missing target pack — say which
            // language, then open the one window that can install it.
            feedbackHUD.show(
                .translationPackMissing(language: TranslationService.displayName(language)),
                on: screen)
            openTranslationSettings()
        case .unknownSource:
            report(.translationFailed, on: screen)
        }
    }

    /// The settings window is the only surface that can install a pack: the
    /// system sheet needs a real window to attach to, and from the borderless
    /// panel `prepareTranslation()` returns having shown nothing.
    private static func openTranslationSettings() {
        NotificationCenter.default.post(
            name: .requestOpenSettings,
            object: nil,
            userInfo: [SettingsWindowController.tabUserInfoKey: SettingsTab.archive.rawValue]
        )
    }

    private static func run(_ text: String,
                            pair: TranslationPair,
                            archiveModel: NotchArchiveModel,
                            on screen: NSScreen?) {
        NotificationCenter.default.post(name: .translationDidStart, object: nil)

        Task { @MainActor in
            // Balanced whatever happens below, including the throws.
            defer { NotificationCenter.default.post(name: .translationDidEnd, object: nil) }
            do {
                let translated = try await TranslationService.shared.translate(
                    text, from: pair.source, to: pair.target)

                // Nothing to file. Worth saying out loud: `add(text:)`
                // deduplicates on the exact string, so filing this would
                // delete the original entry and re-insert it at the top —
                // reading, from the outside, as a cell that jumped for no
                // reason and no translation at all.
                guard translated.trimmingCharacters(in: .whitespacesAndNewlines)
                        != text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    feedbackHUD.show(.translationUnchanged, on: screen)
                    return
                }

                withAnimation(.easeInOut(duration: 0.18)) {
                    archiveModel.add(text: translated)
                }
                // Filed and shown: the archive keeps it for later, the panel
                // puts it where it can actually be read. A 55pt archive cell
                // shows one line of a paragraph.
                NotificationCenter.default.post(
                    name: .translationDidFinish,
                    object: TranslationPanelModel.Result(
                        text: translated, language: pair.target)
                )
            } catch TranslationFailure.packMissing(let pair) {
                feedbackHUD.show(
                    .translationPackMissing(language: TranslationService.displayName(pair.target)),
                    on: screen)
                // Naming the missing pack is not enough — the toast has no
                // button, so this opens where it gets fixed.
                openTranslationSettings()
            } catch TranslationFailure.unsupported {
                feedbackHUD.show(.translationFailed, on: screen)
            } catch is CancellationError {
                // The panel went away mid-flight (sleep, Space change). The
                // user is not looking at a panel any more, so a toast about it
                // would arrive with no context to land in.
                return
            } catch {
                feedbackHUD.show(.translationFailed, on: screen)
            }
        }
    }
}
