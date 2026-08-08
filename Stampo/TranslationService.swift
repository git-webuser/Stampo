import Foundation
import SwiftUI
import Translation

// MARK: - Pair

/// A translation direction. Both ends are always named: leaving the source to
/// the framework looks tempting, but its language identifier is a separate
/// asset that is not installed either, so auto-detection fails and the
/// translation that follows never returns.
/// `nonisolated` because the project defaults every type to the main actor,
/// which would isolate the `Equatable` conformance too — and a plain value
/// like this gets compared from wherever a caller happens to be.
nonisolated struct TranslationPair: Equatable {
    var source: Locale.Language
    var target: Locale.Language
}

// MARK: - Failure

/// Why a translation could not be produced. Deliberately free of user-facing
/// text: the panel and the settings pane word these differently, and a missing
/// pack is an offer to install rather than an error to report.
nonisolated enum TranslationFailure: Error, Equatable {
    /// macOS can translate this pair, but the language pack is not downloaded.
    /// The only case the user can act on.
    case packMissing(TranslationPair)
    /// macOS does not translate this pair at all. A dead end.
    case unsupported(TranslationPair)
    /// The session failed after the pack was confirmed present.
    case failed(String)
}

// MARK: - TranslationService

/// The app's single door to on-device translation.
///
/// Everything about this type is shaped by one API constraint: a
/// `TranslationSession` has no public initializer. It exists only for the
/// duration of a `.translationTask` closure, which means translation cannot
/// happen inside a service, an actor, or a pure function — it needs a mounted
/// SwiftUI view. Three call sites need translations (the archive menu, the
/// clipboard hotkey, the scan overlay) and none of them is a view that could
/// own a session, so one hidden host owns it for all of them and this type is
/// the queue in between.
///
/// Callers see a plain async function and never learn any of that.
///
/// **Requirement on callers:** `TranslationHost` must be mounted when a
/// translation is requested — a `.translationTask` in a window that was
/// ordered out is not running, and the request would wait forever. Every
/// entry point shows the panel before asking, which satisfies this, but the
/// order matters and is not enforceable here.
@Observable final class TranslationService {
    static let shared = TranslationService()

    private init() {}

    // MARK: Session plumbing

    /// What the host view feeds to `.translationTask`. Reading it from a view
    /// body is what makes SwiftUI re-run the task when it changes.
    private(set) var configuration: TranslationSession.Configuration?

    private struct Job {
        let text: String
        let pair: TranslationPair
        let continuation: CheckedContinuation<String, Error>
    }

    private var queue: [Job] = []
    /// True while a session is draining the queue. `pump` must not touch the
    /// configuration during that window: invalidating a configuration that is
    /// currently being served cancels the session mid-translation.
    private var isServing = false

    // MARK: Public API

    /// Translates `text`, waiting for a session if one is not live yet.
    ///
    /// Availability is checked before anything is queued. This is not caution
    /// but a requirement: with the pack missing, the framework's own remedy
    /// (`prepareTranslation()`) either shows a system sheet — which needs a
    /// real window and is therefore the settings pane's job, not ours — or,
    /// from the borderless panel, returns instantly having done nothing at
    /// all. Neither outcome is one this function could report honestly, so it
    /// declines up front and hands the caller something actionable instead.
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let pair = TranslationPair(source: source, target: target)
        switch await status(for: pair) {
        case .installed:
            break
        case .supported:
            throw TranslationFailure.packMissing(pair)
        default:
            throw TranslationFailure.unsupported(pair)
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.append(Job(text: trimmed, pair: pair, continuation: continuation))
            pump()
        }
    }

    /// Whether the pack for `pair` is installed, downloadable, or hopeless.
    /// Free-standing — unlike a session, `LanguageAvailability` needs no view,
    /// so this is callable from anywhere including the settings pane.
    ///
    /// Asked per request rather than cached at launch: the direction follows
    /// the text, and EN → RU being installed says nothing about RU → EN.
    func status(for pair: TranslationPair) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: pair.source, to: pair.target)
    }

    /// "Русский", "English" — named in the language the app is displayed in,
    /// not in the system's. Those two can differ, and a menu item worded in
    /// one language inside a menu worded in another reads as a mistake.
    static func displayName(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier,
              let name = LocaleManager.shared.locale.localizedString(forLanguageCode: code)
        else {
            return language.languageCode?.identifier.uppercased() ?? "?"
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Direction

    /// The one direction pair the app handles today: English and Russian, with
    /// the text deciding which way round.
    ///
    /// Two languages is what makes a single "Translate" command honest — the
    /// destination follows from the source, so there is no choice left to
    /// offer. A menu of targets would have to claim otherwise, and on a
    /// two-language pair it would claim it wrongly: "Translate ▸ English" over
    /// English text produces Russian, because the text is already English.
    ///
    /// When more languages arrive they come with a target setting, and this is
    /// where that setting gets read.
    static func englishRussianRoute(for text: String) -> TranslationPair {
        route(for: text, target: Locale.Language(identifier: "ru"))
    }

    /// Picks the direction from the text itself.
    ///
    /// Decided by script rather than by language detection: a single word is
    /// far too short to identify reliably, and "привет" comes back as
    /// Bulgarian often enough to matter.
    ///
    /// Two-language heuristic on purpose — it holds while the target language
    /// is a setting with one value. When the settings picker lands, the source
    /// half stays and the target half comes from there.
    static func route(for text: String,
                      target preferred: Locale.Language,
                      away fallback: Locale.Language = Locale.Language(identifier: "en")) -> TranslationPair {
        let isCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let source = Locale.Language(identifier: isCyrillic ? "ru" : "en")
        // Text already in the target language goes the other way instead of
        // being "translated" into itself.
        let target = source.languageCode == preferred.languageCode ? fallback : preferred
        return TranslationPair(source: source, target: target)
    }

    // MARK: Host plumbing

    /// Called by `TranslationHost` when SwiftUI hands over a session. Drains
    /// every queued job that matches the session's pair, then returns — which
    /// ends the session, because the framework ties its lifetime to this
    /// closure.
    func serve(_ session: TranslationSession) async {
        isServing = true
        defer {
            isServing = false
            // Anything left is for a different pair; ask for its session next.
            pump()
        }

        while let index = queue.firstIndex(where: { matches($0.pair, session) }) {
            let job = queue.remove(at: index)
            do {
                let response = try await session.translate(job.text)
                job.continuation.resume(returning: response.targetText)
            } catch {
                job.continuation.resume(throwing: TranslationFailure.failed(error.localizedDescription))
            }
        }
    }

    /// Called when the host leaves the view hierarchy — the panel was
    /// destroyed on sleep, a Space change, or a display reconfiguration.
    ///
    /// Waiting callers must be released here. A `CheckedContinuation` that is
    /// never resumed is not a stalled request, it is a leak the runtime traps
    /// on, so the queue cannot simply be dropped.
    func hostWentAway() {
        let stranded = queue
        queue.removeAll()
        configuration = nil
        for job in stranded {
            job.continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: Private

    /// Asks SwiftUI for a session for the head of the queue.
    ///
    /// Same pair as the live configuration means the task would not re-run on
    /// its own — the value it is keyed on has not changed — so `invalidate()`
    /// is what makes a second request for the same direction happen at all.
    /// This is also what makes "translate this again" work on unchanged text.
    private func pump() {
        guard !isServing, let next = queue.first else { return }
        if configuration?.source == next.pair.source, configuration?.target == next.pair.target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: next.pair.source,
                                                             target: next.pair.target)
        }
    }

    private func matches(_ pair: TranslationPair, _ session: TranslationSession) -> Bool {
        session.sourceLanguage == pair.source && session.targetLanguage == pair.target
    }
}

// MARK: - TranslationHost

/// Zero-sized view whose only job is to own the translation session.
///
/// It draws nothing and takes no space; it exists because `.translationTask`
/// is the only way to obtain a `TranslationSession`, and a modifier needs a
/// view to hang on. Mounted once in the panel's root so every entry point can
/// translate without owning a session of its own.
struct TranslationHost: View {
    var service = TranslationService.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(service.configuration) { session in
                await service.serve(session)
            }
            .onDisappear { service.hostWentAway() }
    }
}
