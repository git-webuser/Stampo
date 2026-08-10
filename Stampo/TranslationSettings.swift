import SwiftUI
import Translation

// MARK: - TranslationSettingsModel

/// Drives the Translation section: refreshes what macOS has, and runs the one
/// install at a time that the section allows.
///
/// Installing is the reason this lives in the settings window rather than in
/// the panel. `prepareTranslation()` presents a system sheet, and a sheet needs
/// a real window: measured on 15.7, it attaches correctly to a titled window of
/// an `.accessory` app, while from the borderless panel the same call returns
/// in ten milliseconds having shown nothing and installed nothing. There is no
/// error in that second case — which is exactly why the install button cannot
/// live anywhere but here.
@Observable final class TranslationSettingsModel {
    var languages = TranslationLanguages.shared

    /// The language whose system sheet is up right now. One at a time: macOS
    /// runs that sheet, and two of them at once is not a state worth having.
    private(set) var installing: String?

    /// The sheet for this language, or a pack of its own coming down.
    ///
    /// The download half lives in `TranslationLanguages` rather than here:
    /// this model is `@State` and there are two of them — the settings pane and
    /// the setup window each build their own — so a download started in one was
    /// invisible to the other and lost when either closed.
    func isBusy(_ language: Locale.Language) -> Bool {
        installing == language.baseCode || languages.isDownloading(language)
    }

    /// Fed to `.translationTask` by the section. Non-nil only during an install.
    private(set) var configuration: TranslationSession.Configuration?

    /// Directions still to prepare in the current run, drained one at a time
    /// because a session serves exactly one direction.
    private var remaining: [TranslationPair] = []

    func refresh() async {
        await languages.refresh()
    }

    // MARK: Install

    /// Downloads `language` by preparing a direction that involves it.
    ///
    /// A pair is the only thing the framework will prepare, so a partner is
    /// needed — an already-installed one where possible, so that only the one
    /// language the user asked for has to come down. With nothing installed
    /// yet, the first pair brings both ends, and both rows flip to installed
    /// together. That is the framework's shape, not a shortcut: there is no
    /// call that downloads one language alone.
    func install(_ language: Locale.Language) {
        guard installing == nil, let partner = partner(for: language) else { return }
        installing = language.baseCode
        // Both directions, though the pack is bidirectional and the first
        // should be enough: the check that follows is per pair, and it costs
        // nothing to prepare a direction that is already there.
        remaining = [TranslationPair(source: language, target: partner),
                     TranslationPair(source: partner, target: language)]
        startNext()
    }

    /// Called by the section's `.translationTask` once a session exists.
    func prepare(_ session: TranslationSession) async {
        // The return value carries no information: on 15.7 this comes back
        // normally whether the user accepted, declined, or was never asked.
        // Only a fresh availability check can say what actually happened, and
        // that is what `refresh()` below does.
        try? await session.prepareTranslation()

        guard remaining.isEmpty else {
            startNext()
            return
        }
        configuration = nil
        let language = installing
        installing = nil
        await refresh()
        // Handed to the store, which owns the watching task. Doing it here
        // would put the wait inside this `.translationTask` — and clearing the
        // configuration one line above is exactly what tears that task down,
        // so the wait was cancelled the moment it began.
        if let language { languages.watchForDownload(of: language) }
    }

    private func startNext() {
        guard !remaining.isEmpty else {
            configuration = nil
            installing = nil
            return
        }
        let pair = remaining.removeFirst()
        configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
    }

    /// Who to pair `language` with for the download. An installed language
    /// first, so the download is only the missing half.
    private func partner(for language: Locale.Language) -> Locale.Language? {
        let others = languages.favourites.filter { $0.baseCode != language.baseCode }
        return others.first(where: { languages.isInstalled($0) }) ?? others.first
    }
}

// MARK: - TranslationSettingsSection

/// Settings ▸ Archive ▸ Translation: the user's languages, one row each, and
/// what is missing before any of it can work.
///
/// There is no single "language pack" row any more. It made sense while the app
/// translated one pair: "installed" was a global yes or no. With a list, being
/// downloaded is a property of a language, and each row has to answer for
/// itself.
struct TranslationSettingsSection: View {
    /// True when this is the copy inside the setup window, which changes only
    /// one thing: the row offering to open that window is dropped, since it is
    /// already open and the button would go nowhere.
    var isInsideSetupWindow = false

    @State private var model = TranslationSettingsModel()
    /// Language names are shown in the app's display language, which the user
    /// can change without restarting; reading the environment locale is what
    /// redraws them when they do.
    @Environment(\.locale) private var locale

    private var languages: TranslationLanguages { model.languages }

    var body: some View {
        Group {
            // Gated on the check having landed: the list starts empty and
            // fills in a few milliseconds later, and a section that opens by
            // announcing a problem it has not looked for yet is worse than one
            // that says nothing for a moment.
            if languages.hasChecked, languages.favourites.count < 2 {
                needsSecondLanguageRow
            }

            ForEach(languages.favourites, id: \.baseCode) { language in
                row(for: language)
            }

            addLanguageRow

            // Below the list because it is a statement about the list, and only
            // once the list is long enough for the answer to differ: with two
            // languages the destination follows from the text either way.
            if languages.offersChoice {
                primaryLanguageRow
            }
        }
        .translationTask(model.configuration) { session in
            await model.prepare(session)
        }
        .task { await model.refresh() }
        // Packs belong to macOS and can be removed in System Settings behind
        // our back — including by the trip to System Settings that this very
        // section sends people on. Coming back to the app is the moment to
        // ask again.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: Rows

    /// Not a footnote but a state of the section: with fewer than two
    /// languages there is nothing to translate between, and that is the normal
    /// first-run state for a reader of one language.
    ///
    /// Built like General's "Introduction — Show…": a row that opens the window
    /// which explains the thing and does it. The same window the translation
    /// hotkeys open when they find nothing to work with, so there is one
    /// explanation rather than one per way of arriving at the problem.
    ///
    /// Inside the setup window the row stays but loses its button, which would
    /// offer to open the window it is already in. The words have to stay: the
    /// paragraph up there describes what translation is, and this is the only
    /// thing on screen that says why *this* user is looking at it.
    private var needsSecondLanguageRow: some View {
        SettingRow(
            // Not `translate`, which the rest of the app uses for this: that
            // symbol draws in its own blue whatever `foregroundStyle` and
            // `symbolRenderingMode` are told, so it sat in a column of grey
            // glyphs shouting, and repeated the window's hero icon besides.
            icon: "exclamationmark.bubble",
            title: "Translation needs two languages",
            description: "Add one more and translation works in both directions"
        ) {
            if !isInsideSetupWindow {
                Button("Set Up…") { TranslationSetupWindowController.shared.show() }
            }
        }
    }

    private func row(for language: Locale.Language) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: TranslationService.displayName(language))
                // Lined up with the titles of the icon-bearing rows around it,
                // rather than given an icon of its own: four identical globes
                // down a list name nothing.
                .padding(.leading, 40)

            Spacer()

            state(for: language)

            Button {
                languages.remove(language)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            // Says what it does *not* do: the pack is system-owned, so no disk
            // space comes back and the word "delete" would be a promise the
            // app cannot keep.
            .help("Removes the language from this list. macOS keeps the downloaded pack.")
            // Only while the system sheet is up. A download in the background
            // used to lock the whole section for its duration, which made
            // "add the next language while this one comes down" impossible.
            .disabled(model.installing != nil)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func state(for language: Locale.Language) -> some View {
        // The sheet is up for this language, or its pack is coming down. There
        // is no progress to show — the framework has none — so the spinner
        // says only that something is happening, which is the whole of what is
        // known. It replaces the Install button rather than sitting beside it:
        // pressing that button again while the download runs does nothing, and
        // a button that does nothing is the thing being fixed.
        if model.isBusy(language) {
            ProgressView()
                .controlSize(.small)
        } else if !languages.hasChecked {
            ProgressView()
                .controlSize(.small)
        } else if languages.isInstalled(language) {
            // A statement of fact, not a control: there is nothing to press
            // once the pack is in place.
            Label("Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        } else if languages.favourites.count >= 2 {
            Button("Install…") { model.install(language) }
                .disabled(model.installing != nil)
        } else {
            // Nothing to press either: a pack is a pair, and there is no
            // second language to pair this one with yet.
            Text("Not downloaded")
                .foregroundStyle(.secondary)
        }
    }

    /// Where translations go when nobody said otherwise.
    ///
    /// "Automatic" means the first language in the list above, and keeps
    /// following that list if it changes. Naming one pins it — which is the
    /// point, because the destination is otherwise the kind of thing that
    /// quietly follows whatever was done last.
    ///
    /// That is not spelled out in the row. The description says what the
    /// setting is for; what one of its options resolves to is documentation of
    /// the option, and the option is one menu item away from being tried.
    ///
    /// The description names both surfaces that read this, not just the
    /// clipboard one. A scan started with ⌃ reads it too — it is the language
    /// on the badge before ⇥ says otherwise — and a row that promised only the
    /// hotkey would be describing half of what the setting does.
    ///
    /// The commands are named, not their shortcuts: every one of them can be
    /// rebound in the Shortcuts pane, and a printed ⌃⌥⌘T would be a lie the
    /// moment it was.
    private var primaryLanguageRow: some View {
        SettingRow(
            icon: "character.book.closed",
            title: "Translate into",
            description: "Used by Translate and by scanning when no language is picked"
        ) {
            Picker("Translate into", selection: Binding(
                get: { languages.primary?.baseCode ?? "" },
                set: { code in
                    languages.primary = languages.favourites.first { $0.baseCode == code }
                }
            )) {
                Text("Automatic").tag("")
                ForEach(languages.favourites, id: \.baseCode) { language in
                    Text(verbatim: TranslationService.displayName(language)).tag(language.baseCode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// The download is hundreds of megabytes behind a control that looks like
    /// ticking a box, so the row says so before it is pressed. Progress is not
    /// ours to show — macOS runs the download behind its own sheet and only
    /// lets us poll the result.
    ///
    /// Silent about the cost inside the setup window, where the paragraph
    /// above the list has just said the same thing in the same words. Twice on
    /// one screen reads as a stutter, not as emphasis.
    private var addLanguageRow: some View {
        SettingRow(
            icon: "plus.circle",
            title: "Add language",
            description: isInsideSetupWindow
                ? nil
                : "Each language is downloaded once by macOS, usually a few hundred megabytes"
        ) {
            Menu {
                ForEach(languages.addable, id: \.baseCode) { language in
                    Button(TranslationService.displayName(language)) {
                        languages.add(language)
                    }
                }
            } label: {
                Text("Add…")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(languages.addable.isEmpty || model.installing != nil)
        }
    }
}
