import Foundation
import NaturalLanguage
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

// MARK: - Detection

/// What language a piece of text turned out to be in — and, just as important,
/// whether the app can act on it.
///
/// Three cases rather than an optional language, because "German, which you
/// have not downloaded" is not a failure to report but the most useful offer
/// the feature can make.
nonisolated enum DetectedLanguage: Equatable {
    /// Recognized, and its pack is present. Translate from it.
    case installed(Locale.Language)
    /// Recognized, macOS can translate it, the pack is not downloaded.
    case notInstalled(Locale.Language)
    /// Nothing macOS can translate was recognized.
    case unknown
}

// MARK: - Route

/// What to do about a request to translate, once the text has been read.
nonisolated enum TranslationRoute: Equatable {
    case translate(TranslationPair)
    /// The text is already in the language asked for, and no other target
    /// follows from the set.
    case alreadyThere
    /// The source language needs downloading first. Carried so the refusal can
    /// name it: "looks like German — add it?".
    case sourceMissing(Locale.Language)
    case unknownSource
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

    // MARK: Detection

    /// What language the text is in, as far as the app can act on it.
    ///
    /// Script was enough while there were two languages — "does it contain
    /// Cyrillic" separates Russian from English and nothing else. It cannot
    /// separate the eleven Latin ones, so a third language makes it wrong
    /// rather than merely narrow.
    ///
    /// The rule below was measured on 24 samples across six languages at one
    /// word, one phrase and one sentence, and again through real OCR output:
    /// unconstrained ranking, then the first hypothesis the app can act on,
    /// 23/24 and 9/10.
    ///
    /// **`languageConstraints` must not be used**, though it is the obvious
    /// reach. A recognizer constrained to the installed set answers with
    /// confidence 1.00 every time — including Ukrainian called Russian and
    /// German called English. It cannot say "not one of yours", and that is
    /// precisely the sentence this returns.
    ///
    /// **Confidence is not a gate either**: a correct "Settings" → en scored
    /// 0.25 while a wrong "Привет" → bg scored 0.53. Skipping hypotheses macOS
    /// cannot translate at all is what rescues short strings — bg and da drop
    /// out and the right answer is underneath.
    nonisolated static func detect(_ text: String,
                                   supported: Set<String>,
                                   installed: Set<String>) -> DetectedLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(recognizableText(in: trimmed))
        // Deeper than the eight the rule was measured on, because the two ends
        // of the ranking are used for different things — see below. macOS
        // returns about twenty.
        let ranked = recognizer.languageHypotheses(withMaximum: 25)
            .sorted { $0.value > $1.value }
            .map { Locale.Language(identifier: $0.key.rawValue).baseCode }

        // Below two words, do not offer a download. The one surviving miss in
        // the whole measurement is "Download" → Indonesian at zero OCR damage:
        // real ambiguity that no scan quality fixes. Asking for several
        // hundred megabytes on the strength of one common word is a worse
        // outcome than quietly using the best installed language, which is
        // what skipping past it does.
        //
        // Words with letters in them, not tokens: a scanned price tag or
        // version number ("1 234,56 — v2.7.1 (#42)") is half a dozen tokens of
        // no language at all, and it must not be able to talk the app into
        // offering a download either.
        let words = trimmed.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains(where: \.isLetter) }
        let offersDownload = words.count >= 2

        // The decision proper, over the eight hypotheses the rule was measured
        // on: the first one the app can act on wins.
        for code in ranked.prefix(8) where supported.contains(code) {
            if installed.contains(code) { return .installed(Locale.Language(identifier: code)) }
            if offersDownload { return .notInstalled(Locale.Language(identifier: code)) }
        }

        // Nothing decidable up there. Rather than refuse, take the best
        // installed language from anywhere in the ranking — this is the case
        // the word threshold exists to reach, and it is not rare: a scanned
        // button reading "Download" ranks Indonesian, Danish, Hungarian and
        // Finnish above English, which comes ninth at 0.04. Translating it as
        // English is right; a toast saying the language could not be told is
        // both unhelpful and, on one common word, beside the point.
        if let code = ranked.first(where: { installed.contains($0) }) {
            return .installed(Locale.Language(identifier: code))
        }
        return .unknown
    }

    /// Scripts told apart far enough to know which one a text is really in.
    ///
    /// Script cannot separate the eleven Latin languages — that is what the
    /// recognizer is for. Across scripts it is decisive, and the recognizer
    /// needs the help: it weighs by character, and a Chinese sentence is
    /// shorter in characters than the one English product name inside it.
    nonisolated private enum Script {
        case latin, cyrillic, greek, arabic, devanagari
        /// One character carries about as much as a short word.
        case han, kana, hangul, thai

        /// What one character is worth against a Latin letter.
        ///
        /// Three, measured: it is what separates "打开 Stampo 并按 ⌘C" —
        /// Chinese quoting a product name, four Han characters against six
        /// Latin letters — from "Open 设置 now to continue", English quoting a
        /// Chinese term. Unweighted, the first is read as Italian at 1.00
        /// confidence with Chinese nowhere in the ranking at all.
        var weight: Int {
            switch self {
            case .han, .kana, .hangul, .thai: return 3
            default: return 1
            }
        }
    }

    nonisolated private static func script(of scalar: UnicodeScalar) -> Script? {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return .latin
        case 0x0370...0x03FF:                                   return .greek
        case 0x0400...0x052F:                                   return .cyrillic
        case 0x0600...0x06FF:                                   return .arabic
        case 0x0900...0x097F:                                   return .devanagari
        case 0x0E00...0x0E7F:                                   return .thai
        case 0x3040...0x30FF:                                   return .kana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF:                  return .han
        case 0x1100...0x11FF, 0xAC00...0xD7AF:                  return .hangul
        default:                                                return nil
        }
    }

    /// The text with borrowed foreign words taken out, when there are any.
    ///
    /// A Latin run inside Chinese, Japanese, Korean or Thai is almost always a
    /// product name or a UI term, and it is enough to take the whole answer
    /// over: "在 Finder 中显示" is read as Danish at 0.93 with Chinese absent
    /// from the ranking. Dropping the letters of the losing scripts puts the
    /// answer back — measured at zh:1.00, ko:1.00 and ja:1.00 for the four
    /// cases above.
    ///
    /// Latin text is returned untouched, which is what keeps every earlier
    /// measurement of the rule valid: the whole of it was Latin and Cyrillic.
    nonisolated static func recognizableText(in text: String) -> String {
        var weights: [Script: Int] = [:]
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars {
            guard let script = script(of: scalar) else { continue }
            counts[script, default: 0] += 1
            weights[script, default: 0] += script.weight
        }

        guard let winner = weights.max(by: { $0.value < $1.value })?.key,
              winner != .latin,
              // One stray character is a symbol, not a language.
              counts[winner, default: 0] >= 2
        else { return text }

        // Japanese is written in both at once, so neither can be dropped when
        // the other wins.
        let keep: Set<Script> = (winner == .han || winner == .kana) ? [.han, .kana] : [winner]
        return String(String.UnicodeScalarView(text.unicodeScalars.filter {
            guard let script = script(of: $0) else { return true }
            return keep.contains(script)
        }))
    }

    /// The same rule against the user's current languages.
    ///
    /// Depends on `TranslationLanguages` having refreshed at least once —
    /// `AppDelegate` does that at launch, long before any of the three entry
    /// points can be reached.
    @MainActor
    static func detect(_ text: String) -> DetectedLanguage {
        let languages = TranslationLanguages.shared
        return detect(text,
                      supported: Set(languages.supported.map(\.baseCode)),
                      installed: languages.installed)
    }

    // MARK: Direction

    /// The direction for a language the user picked by hand.
    ///
    /// Never flipped. Automatic routing turns "into Russian" into "out of
    /// Russian" so a Russian scan is not translated into itself — sensible
    /// when nobody chose anything. Applied to a deliberate pick it does the
    /// opposite of what the menu said: choosing Russian over Russian text
    /// handed back English, from a menu whose every entry then produced the
    /// same result.
    nonisolated static func route(from detected: DetectedLanguage,
                                  to target: Locale.Language) -> TranslationRoute {
        switch detected {
        case .unknown:
            return .unknownSource
        case .notInstalled(let language):
            return .sourceMissing(language)
        case .installed(let source):
            guard source.baseCode != target.baseCode else { return .alreadyThere }
            return .translate(TranslationPair(source: source, target: target))
        }
    }

    /// The direction when nobody chose a target — the scan modifier, the
    /// clipboard hotkey, the archive's plain Translate.
    ///
    /// Text already in the target language is the interesting case. With
    /// exactly two languages there is one other place it could go, and going
    /// there is what "Translate" has always meant here — no choice is being
    /// invented. With three there are several, and picking one would be a
    /// guess the user cannot see being made, so the honest answer is that the
    /// text is already in that language and the menus are where a target gets
    /// chosen.
    nonisolated static func automaticRoute(from detected: DetectedLanguage,
                                           destination: Locale.Language,
                                           favourites: [Locale.Language]) -> TranslationRoute {
        guard case .installed(let source) = detected else {
            return route(from: detected, to: destination)
        }
        guard source.baseCode == destination.baseCode else {
            return .translate(TranslationPair(source: source, target: destination))
        }
        let others = favourites.filter { $0.baseCode != source.baseCode }
        guard others.count == 1, let only = others.first else { return .alreadyThere }
        return .translate(TranslationPair(source: source, target: only))
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
