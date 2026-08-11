import Foundation
import Translation

// MARK: - Locale.Language

nonisolated extension Locale.Language {
    /// "ru" out of "ru-RU". Regions are dropped everywhere translation is
    /// concerned: macOS lists English and Chinese twice by region, and the
    /// download is the same one either way.
    var baseCode: String { languageCode?.identifier ?? minimalIdentifier }
}

// MARK: - TranslationLanguages

/// The languages the user keeps for translation, and which of them macOS has
/// actually downloaded.
///
/// Two measured facts about `Translation.framework` shape all of this (15.7 —
/// re-measure before trusting them on a newer system):
///
/// * **Packs are per language, not per pair.** Installing English and Russian
///   made `en→ru` *and* `ru→en` report `.installed`, while `en→de` and `de→ru`
///   stayed `.supported`. The truth is a *set* of installed languages, and
///   every direction inside that set works — adding one language to a set of
///   N buys 2N new directions.
/// * **The API only ever answers about pairs.** `status(from:to:)` with the
///   same language at both ends comes back `.unsupported`, so a language
///   cannot be asked about on its own. `refresh()` recovers the set from
///   pairs instead.
///
/// Nothing ships installed, so the empty set is the normal first-run state for
/// everyone rather than an error.
@Observable final class TranslationLanguages {
    static let shared = TranslationLanguages()

    /// Every language macOS can translate, one entry per language code.
    ///
    /// `supportedLanguages` hands back 21 entries with `en` and `zh` repeated
    /// by region; a menu that offered English twice would read as a bug, and
    /// the regional split buys nothing — the pack is the same.
    private(set) var supported: [Locale.Language] = []

    /// The user's own list. The order is theirs: seeded from the order they
    /// gave the system, and new languages land at the end.
    private(set) var favourites: [Locale.Language] = []

    /// Language codes macOS has downloaded — see `refresh()` for the one case
    /// this cannot see.
    private(set) var installed: Set<String> = []

    /// False until the first `refresh()` lands, so the section can show that it
    /// is asking rather than claim nothing is installed.
    private(set) var hasChecked = false

    private init() {
        // The stored list is read here rather than waiting for `refresh()`:
        // the menus are built from it, and a panel opened in the first
        // milliseconds of a launch would otherwise offer an empty one. The
        // async half — what is supported and what is downloaded — catches up
        // when `refresh()` lands.
        if let stored = UserDefaults.standard.array(forKey: AppSettings.Keys.translationLanguages) as? [String] {
            favourites = stored.map { Locale.Language(identifier: $0) }
        }
        primaryCode = UserDefaults.standard.string(forKey: AppSettings.Keys.translationPrimary)
    }

    // MARK: Where translations go

    /// The language the user reads in, if they have said so. `nil` means they
    /// have not, and `destination` follows their list instead.
    ///
    /// A *setting*, deliberately. It is the one thing about translation that
    /// must not change because of something done in passing: an earlier build
    /// let the scan overlay's ⇥ write the destination that the clipboard
    /// hotkey reads, so choosing "this scan into Chinese" quietly rewired
    /// ⌃⌥⌘T — and Chinese text then had nowhere left to go, being already in
    /// the language everything was being sent to.
    ///
    /// Checked against the list on every read rather than trusted: a primary
    /// language since removed would aim translations at somewhere the user can
    /// no longer see named anywhere.
    /// Mirrored in a stored property rather than read straight from the
    /// defaults on every access. `@Observable` tracks stored properties only,
    /// so a computed getter over `UserDefaults` notifies nobody: the picker
    /// went on showing the old language until something unrelated redrew the
    /// pane, which in practice meant closing Settings and opening it again.
    private var primaryCode: String?

    var primary: Locale.Language? {
        get {
            guard let primaryCode else { return nil }
            return favourites.first { $0.baseCode == primaryCode }
        }
        set {
            primaryCode = newValue?.baseCode
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(newValue.baseCode, forKey: AppSettings.Keys.translationPrimary)
            } else {
                defaults.removeObject(forKey: AppSettings.Keys.translationPrimary)
            }
        }
    }

    /// Where a translation nobody chose a target for goes.
    ///
    /// The primary language when there is one, otherwise the first in the
    /// user's own list — the first one they told the system they read. Nothing
    /// writes this: a per-scan choice lives and dies with the overlay that
    /// made it.
    ///
    /// The primary language is only consulted while `offersChoice` — which is
    /// exactly while the row that shows it is on screen. Removing a third
    /// language hides that row, and a setting still in force with no control
    /// anywhere to read it off is worse than one that is dormant. The stored
    /// answer is kept rather than cleared: adding a third language back should
    /// not cost the user the choice they already made.
    var destination: Locale.Language {
        Self.destination(primary: primary, favourites: favourites)
    }

    /// Pure half of `destination`, so the rule above can be tested without
    /// writing to the defaults the shared instance reads.
    nonisolated static func destination(primary: Locale.Language?,
                                        favourites: [Locale.Language]) -> Locale.Language {
        let chosen = favourites.count > 2 ? primary : nil
        return chosen ?? favourites.first ?? Locale.Language(identifier: "en")
    }

    /// One step along the user's own order, wrapping. Their order, not ours —
    /// it is the order the list is shown in everywhere else, so ⇥ walks the
    /// list the user can already see.
    nonisolated static func language(after current: Locale.Language,
                                     in languages: [Locale.Language],
                                     backwards: Bool = false) -> Locale.Language? {
        guard languages.count > 1 else { return nil }
        let index = languages.firstIndex { $0.baseCode == current.baseCode } ?? 0
        let step = backwards ? languages.count - 1 : 1
        return languages[(index + step) % languages.count]
    }

    // MARK: Reading

    /// True once the destination stops following from the text and has to be
    /// asked for.
    ///
    /// With two languages there is nothing to choose: whatever the text is,
    /// the translation goes to the other one. Past two, every surface has to
    /// offer the choice — the archive grows a submenu, the scan badge names
    /// where it is going, ⇥ steps it, and Settings asks for a primary
    /// language.
    ///
    /// One property rather than `favourites.count > 2` written out at each of
    /// them: they drifted apart the first time it was, and the two halves of
    /// the scan overlay disagreeing meant ⇥ changed the destination while the
    /// badge showed nothing.
    var offersChoice: Bool { favourites.count > 2 }

    // MARK: Downloads in flight

    /// Languages whose packs are on their way down.
    ///
    /// Here rather than in the settings model, and watched by a task this type
    /// owns, because both of those were wrong before and each in its own way:
    ///
    /// * The wait ran inside the section's `.translationTask`, whose lifetime
    ///   ends when the configuration is cleared — which is the first thing the
    ///   install does when the sheet closes. The task was cancelled, so
    ///   `Task.sleep` returned instantly, a hundred polls went by in a blink,
    ///   and the spinner disappeared seconds after it appeared.
    /// * The state lived in a `@State` model, and there are two of them — the
    ///   settings pane and the setup window each build their own. Closing one,
    ///   or opening the other, lost the fact that anything was downloading.
    ///
    /// macOS keeps downloading through all of that, so the app has to keep
    /// knowing about it through all of that.
    private(set) var downloading: Set<String> = []
    private var watchers: [String: Task<Void, Never>] = [:]

    /// Watches for `code` to arrive, and says so meanwhile.
    ///
    /// Nothing observes a download: `LanguageAvailability.Status` is installed,
    /// supported or unsupported, with no state in between, and
    /// `TranslationSession.isReady` is macOS 26. So this polls, and the row
    /// spins until it lands.
    ///
    /// **A download that is running and one that was cancelled look identical
    /// from here** — `.supported` in both cases, and a dismissed sheet returns
    /// exactly like an accepted one.
    ///
    /// So this does not guess for the user by giving up after a while. It ran
    /// on a timer twice and both timers were wrong: the user had already asked
    /// for the language, and a clock they cannot see expiring turned the
    /// spinner back into the button they just pressed — asking them to repeat a
    /// command they had given, for no reason visible to them, on a download
    /// that was still running. Several packs on a slow line take longer than
    /// any number worth hard-coding.
    ///
    /// It therefore waits until the pack lands, and the one person who can
    /// know the download is not coming — the one who cancelled it — can stop
    /// the wait from the row. See `stopWaiting(for:)`.
    ///
    /// The poll slows down rather than stopping: three seconds while the
    /// download is plausibly short, fifteen after the first minute, so an
    /// hour-long wait costs nothing worth counting.
    func watchForDownload(of code: String) {
        guard watchers[code] == nil, !installed.contains(code) else { return }
        downloading.insert(code)
        watchers[code] = Task { [weak self] in
            defer {
                self?.downloading.remove(code)
                self?.watchers[code] = nil
            }
            var polls = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(polls < 20 ? 3 : 15))
                if Task.isCancelled { return }
                guard let self else { return }
                polls += 1
                await self.refresh()
                if self.installed.contains(code) { return }
            }
        }
    }

    /// Stops waiting for one language, at the user's word.
    ///
    /// It does not cancel anything: the download belongs to macOS and there is
    /// no call to stop it. All this does is put the row back to offering an
    /// install, for the case only the user can recognise — that the download
    /// they started is not coming, because they called it off themselves.
    func stopWaiting(for language: Locale.Language) {
        let code = language.baseCode
        watchers[code]?.cancel()
        watchers[code] = nil
        downloading.remove(code)
    }

    func isDownloading(_ language: Locale.Language) -> Bool {
        downloading.contains(language.baseCode)
    }

    /// Stops every watch. Nothing in the app calls this: a download belongs to
    /// macOS, and there is no interface for calling one off — removing the
    /// language from the list does not stop the bytes arriving. It exists so
    /// tests can leave the shared store as they found it instead of leaving a
    /// ten-minute poll running behind them.
    func stopWatchingDownloads() {
        watchers.values.forEach { $0.cancel() }
        watchers.removeAll()
        downloading.removeAll()
    }

    /// Whether translation can do anything at all.
    ///
    /// Two installed languages is the floor: a pack is only ever half a
    /// direction, and nothing ships installed, so this is false for every user
    /// until they have been through the setup once.
    ///
    /// `hasChecked` is part of the question. Before the first refresh the
    /// installed set is empty for want of asking, and an entry point that read
    /// that as "not set up" would send a brand-new window at someone in the
    /// first frames of a launch.
    var canTranslate: Bool { hasChecked && installed.count >= 2 }

    func isInstalled(_ language: Locale.Language) -> Bool {
        installed.contains(language.baseCode)
    }

    /// Supported languages the user has not added, by display name.
    var addable: [Locale.Language] {
        let taken = Set(favourites.map(\.baseCode))
        return supported.filter { !taken.contains($0.baseCode) }
    }

    // MARK: Refresh

    /// Re-reads both lists from the system.
    ///
    /// Called on every appearance of the section, not once at launch: the packs
    /// belong to macOS, and the user can remove them in System Settings without
    /// telling us. A language whose pack has gone must go back to offering an
    /// install rather than failing when it is used.
    ///
    /// **The one blind spot:** with exactly one language installed no pair can
    /// report `.installed`, so that language reads as not downloaded. It is
    /// also the one case where the distinction changes nothing — a single
    /// language translates nothing, and the section is already saying that a
    /// second one is needed.
    func refresh() async {
        let availability = LanguageAvailability()

        var seen = Set<String>()
        let reported = await availability.supportedLanguages
            .filter { seen.insert($0.baseCode).inserted }
            .sorted { TranslationService.displayName($0) < TranslationService.displayName($1) }

        // An empty answer means the framework would not tell us — translation
        // is unprovisioned on this Mac, or restricted where it is — not that
        // macOS has stopped translating the languages the user already picked.
        // Taking it at face value emptied their list against it below, and the
        // section then blamed them for a machine capability.
        if !reported.isEmpty { supported = reported }

        loadFavourites()

        // Favourites first: the pair that answers "yes" is almost always one of
        // the user's own, which ends the search on the first probe or two.
        let ordered = favourites.map(\.baseCode) + addable.map(\.baseCode)
        installed = await installedSet(among: ordered, availability)
        hasChecked = true
    }

    /// Recovers the installed set from pair answers.
    ///
    /// A pair reads `.installed` only when *both* its languages are downloaded,
    /// so one installed pair is enough to name a reference language, and every
    /// other language can then be tested against that one. Roughly 5 ms per 18
    /// probes when measured, so the worst case — nothing installed, every pair
    /// tried — stays well under a tenth of a second.
    private func installedSet(among codes: [String],
                              _ availability: LanguageAvailability) async -> Set<String> {
        guard let reference = await anyInstalledLanguage(among: codes, availability) else { return [] }

        var result: Set<String> = [reference]
        for code in codes where code != reference {
            let status = await availability.status(from: Locale.Language(identifier: code),
                                                   to: Locale.Language(identifier: reference))
            if status == .installed { result.insert(code) }
        }
        return result
    }

    private func anyInstalledLanguage(among codes: [String],
                                      _ availability: LanguageAvailability) async -> String? {
        for (index, code) in codes.enumerated() {
            for other in codes[(index + 1)...] {
                let status = await availability.status(from: Locale.Language(identifier: code),
                                                       to: Locale.Language(identifier: other))
                if status == .installed { return code }
            }
        }
        return nil
    }

    // MARK: Editing

    func add(_ language: Locale.Language) {
        guard !favourites.contains(where: { $0.baseCode == language.baseCode }) else { return }
        favourites.append(language)
        saveFavourites()
    }

    /// Drops a language from the list. It cannot delete the macOS pack — that
    /// is system-owned and no disk space is freed, which is why nothing in the
    /// interface calls this deleting.
    func remove(_ language: Locale.Language) {
        favourites.removeAll { $0.baseCode == language.baseCode }
        saveFavourites()
    }

    // MARK: Persistence

    private func loadFavourites() {
        let defaults = UserDefaults.standard
        guard let stored = defaults.array(forKey: AppSettings.Keys.translationLanguages) as? [String] else {
            favourites = seed()
            // Not persisted when there is nothing to seed against: writing the
            // empty result would make the key present, and a first run on a
            // Mac that answered nothing would lock the user out of ever being
            // seeded again.
            if !supported.isEmpty { saveFavourites() }
            return
        }
        // Filtered against `supported` on every load: the stored list outlives
        // the OS that wrote it, and a language macOS has stopped translating
        // would otherwise sit in the list with no state it could ever reach.
        //
        // Unless there is no list to filter against — an unanswered check must
        // not read as "none of your languages are translatable".
        guard !supported.isEmpty else {
            favourites = stored.map { Locale.Language(identifier: $0) }
            return
        }
        let known = Set(supported.map(\.baseCode))
        favourites = stored.filter { known.contains($0) }.map { Locale.Language(identifier: $0) }
    }

    private func saveFavourites() {
        UserDefaults.standard.set(favourites.map(\.baseCode),
                                  forKey: AppSettings.Keys.translationLanguages)
    }

    /// First run: the languages the user already told the system they read,
    /// in their order, kept to the ones macOS can translate.
    ///
    /// Never invents a second language. For a reader of one language this
    /// seeds one entry and the section says a second is needed — guessing
    /// which one would cost them a several-hundred-megabyte download to
    /// find out we guessed wrong.
    private func seed() -> [Locale.Language] {
        let known = Set(supported.map(\.baseCode))
        var seen = Set<String>()
        return Locale.preferredLanguages
            .map { Locale.Language(identifier: $0).baseCode }
            .filter { known.contains($0) && seen.insert($0).inserted }
            .map { Locale.Language(identifier: $0) }
    }
}
