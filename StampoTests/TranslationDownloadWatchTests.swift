import Foundation
import Testing
@testable import Stampo

/// A pack takes minutes and macOS reports nothing while it comes down, so the
/// row's spinner is driven by a poll the app runs itself. Twice now that poll
/// has been attached to something shorter-lived than the download.
@MainActor
@Suite(.serialized) struct TranslationDownloadWatchTests {

    // Serialized, and a different code per test: the store is a singleton, and
    // these tests both watch it and clear it. Run in parallel they wipe each
    // other's state — the same collision the panel's window tests hit.

    /// The bug this pins: the wait used to run inside the section's
    /// `.translationTask`, and clearing the configuration — the first thing the
    /// install does once the sheet closes — tore that task down. A cancelled
    /// `Task.sleep` returns immediately, so a hundred polls went by in a blink
    /// and the spinner vanished seconds after it appeared.
    @Test func theWatchOutlivesTheTaskThatStartedIt() async {
        let store = TranslationLanguages.shared
        defer { store.stopWatchingDownloads() }

        let starter = Task { @MainActor in
            store.watchForDownload(of: "xa")
        }
        await starter.value
        starter.cancel()

        try? await Task.sleep(for: .milliseconds(300))

        #expect(store.downloading.contains("xa"),
                "cancelling whoever asked for the watch must not end the download")
    }

    /// Removing a language from the list does not call off the download —
    /// nothing can, it belongs to macOS — so putting it back must find the
    /// spinner still turning rather than an Install button that would do
    /// nothing.
    @Test func removingTheLanguageDoesNotEndTheWatch() async {
        let store = TranslationLanguages.shared
        defer { store.stopWatchingDownloads() }

        store.watchForDownload(of: "xb")
        store.remove(Locale.Language(identifier: "xb"))

        #expect(store.downloading.contains("xb"))
        #expect(store.isDownloading(Locale.Language(identifier: "xb")))
    }

    /// The wait has no clock of its own: a timer the user cannot see, expiring
    /// on a download that is still running, turns the spinner back into the
    /// button they already pressed and asks them to press it again. Only they
    /// know when the download is not coming, so only they end the wait.
    @Test func theWaitEndsWhenTheUserSaysSoAndNotOnATimer() async {
        let store = TranslationLanguages.shared
        defer { store.stopWatchingDownloads() }
        let ghost = Locale.Language(identifier: "xd")

        store.watchForDownload(of: "xd")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(store.isDownloading(ghost), "still waiting: the pack has not landed")

        store.stopWaiting(for: ghost)
        #expect(!store.isDownloading(ghost))
    }

    @Test func askingTwiceKeepsOneWatch() async {
        let store = TranslationLanguages.shared
        defer { store.stopWatchingDownloads() }

        store.watchForDownload(of: "xc")
        store.watchForDownload(of: "xc")

        #expect(store.downloading == ["xc"])
    }
}
