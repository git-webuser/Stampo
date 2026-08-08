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

    /// Translates `text` and files the result at the top of the archive.
    ///
    /// Both ends of the direction come from the text — the app handles one
    /// language pair today, so there is nothing for the caller to choose.
    /// Every failure ends in the HUD rather than silently: the user asked for
    /// something visible to happen, so something visible has to happen even
    /// when it could not.
    static func run(_ text: String,
                    archiveModel: NotchArchiveModel,
                    on screen: NSScreen?) {
        let pair = TranslationService.englishRussianRoute(for: text)

        Task { @MainActor in
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
                        source: text, translated: translated, pair: pair)
                )
            } catch TranslationFailure.packMissing(let pair) {
                feedbackHUD.show(
                    .translationPackMissing(language: TranslationService.displayName(pair.target)),
                    on: screen)
                // Naming the missing pack is not enough — the toast has no
                // button, and the one place that can install it is the
                // settings window, because the system sheet needs a real
                // window to attach to. So the toast says what is wrong and
                // this opens where it gets fixed.
                NotificationCenter.default.post(
                    name: .requestOpenSettings,
                    object: nil,
                    userInfo: [SettingsWindowController.tabUserInfoKey: SettingsTab.archive.rawValue]
                )
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
