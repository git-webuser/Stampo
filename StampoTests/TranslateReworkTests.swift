import AppKit
import Testing
@testable import Stampo

/// The panel dims its body while the next language is on its way, and the
/// dimming is cleared by the notification pair posted *around a translation*.
/// A route that produces no translation posts nothing — which is how the body
/// came to stay dimmed for good, taking ⇥ with it: the key is guarded by the
/// very flag that was stuck.
///
/// Both tests drive code that opens the shared setup window on its way past —
/// nothing is installed in a test run, so a translation request leads there
/// rather than translating. The window is closed again on the way out: left
/// open it outlived the test, and another suite closing it mid-assertion is
/// the flake that followed.
@MainActor
@Suite struct TranslateReworkTests {

    /// Detection is answered against the shared store, which no test refreshes,
    /// so `installed` is empty and every text reads as `.unknown` — the
    /// `.unknownSource` refusal, which is exactly one of the routes that used
    /// to leave the flag set.
    @Test func arefusedTranslationUndimsTheBody() {
        defer { TranslationSetupWindowController.shared.close() }
        let model = TranslationPanelModel.shared
        model.present(.init(text: "Снимок экрана", language: Locale.Language(identifier: "ru")),
                      bodyWidth: 200)
        model.beginRework()
        #expect(model.isReworking)

        ArchiveTranslate.run("Снимок экрана",
                             to: Locale.Language(identifier: "en"),
                             archiveModel: NotchArchiveModel(),
                             on: nil)

        #expect(!model.isReworking,
                "a route that starts no translation must still clear the dimming")
        model.clear()
    }

    /// The automatic side of the same door: no language named, nothing to do,
    /// and the panel is opened on the text instead. That path posts a
    /// notification rather than translating, so it has the same duty.
    @Test func anAutomaticRefusalUndimsTheBodyToo() {
        defer { TranslationSetupWindowController.shared.close() }
        let model = TranslationPanelModel.shared
        model.present(.init(text: "1 234,56 — v2.7.1", language: Locale.Language(identifier: "en")),
                      bodyWidth: 200)
        model.beginRework()

        ArchiveTranslate.run("1 234,56 — v2.7.1",
                             archiveModel: NotchArchiveModel(),
                             on: nil)

        #expect(!model.isReworking)
        model.clear()
    }
}
