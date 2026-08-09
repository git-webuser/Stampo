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
    }

    // MARK: Target

    /// Where an unprompted translation goes — the scan modifier, the clipboard
    /// hotkey, the archive's plain Translate. The scanner cycles it with F, the
    /// way the colour HUD cycles its format.
    ///
    /// Always one of the user's own languages: a target that had been removed
    /// from the list would send translations somewhere the user can no longer
    /// see, so the stored value is checked against the list on every read
    /// rather than trusted.
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
    var primary: Locale.Language? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: AppSettings.Keys.translationPrimary)
            else { return nil }
            return favourites.first { $0.baseCode == stored }
        }
        set {
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
    var destination: Locale.Language {
        primary ?? favourites.first ?? Locale.Language(identifier: "en")
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
        supported = await availability.supportedLanguages
            .filter { seen.insert($0.baseCode).inserted }
            .sorted { TranslationService.displayName($0) < TranslationService.displayName($1) }

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
            saveFavourites()
            return
        }
        // Filtered against `supported` on every load: the stored list outlives
        // the OS that wrote it, and a language macOS has stopped translating
        // would otherwise sit in the list with no state it could ever reach.
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
