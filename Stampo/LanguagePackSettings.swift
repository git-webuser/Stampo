import SwiftUI
import Translation

// MARK: - LanguagePackModel

/// Tracks whether macOS can translate the pair the app uses, and installs it.
///
/// Installing is the reason this lives in the settings window rather than in
/// the panel. `prepareTranslation()` presents a system sheet, and a sheet needs
/// a real window: measured on 15.7, it attaches correctly to a titled window of
/// an `.accessory` app, while from the borderless panel the same call returns
/// in ten milliseconds having shown nothing and installed nothing. There is no
/// error in that second case — which is exactly why the install button cannot
/// live anywhere but here.
@Observable final class LanguagePackModel {

    enum State: Equatable {
        case checking
        /// Every direction the app uses is installed.
        case ready
        /// At least one direction is downloadable but not installed.
        case missing
        /// macOS cannot translate the pair at all. Not reachable for English
        /// and Russian, kept because the answer is not ours to assume.
        case unavailable
    }

    private(set) var state: State = .checking
    /// True while a system sheet is up or a pair is being prepared.
    private(set) var isInstalling = false

    /// Fed to `.translationTask` by the row. Non-nil only during an install.
    private(set) var configuration: TranslationSession.Configuration?

    /// Both directions are checked, not just one: availability is per-pair, so
    /// English → Russian being installed says nothing about the way back, and
    /// the archive translates in whichever direction the text asks for.
    private static let pairs = [
        TranslationPair(source: Locale.Language(identifier: "en"),
                        target: Locale.Language(identifier: "ru")),
        TranslationPair(source: Locale.Language(identifier: "ru"),
                        target: Locale.Language(identifier: "en")),
    ]

    /// Pairs still to prepare in the current install run. Drained one at a
    /// time because a session serves exactly one direction.
    private var remaining: [TranslationPair] = []

    // MARK: Status

    func refresh() async {
        let service = TranslationService.shared
        var missing = false
        for pair in Self.pairs {
            switch await service.status(for: pair) {
            case .installed: continue
            case .supported: missing = true
            default:
                state = .unavailable
                return
            }
        }
        state = missing ? .missing : .ready
    }

    // MARK: Install

    func install() {
        guard !isInstalling else { return }
        isInstalling = true
        remaining = Self.pairs
        startNext()
    }

    /// Called by the row's `.translationTask` once a session for the current
    /// configuration exists.
    func prepare(_ session: TranslationSession) async {
        // The return value carries no information: on 15.7 this comes back
        // normally whether the user accepted, declined, or was never asked.
        // Only a fresh availability check can say what actually happened, and
        // that runs below for every pair regardless of outcome.
        try? await session.prepareTranslation()

        if remaining.isEmpty {
            configuration = nil
            isInstalling = false
            await refresh()
        } else {
            startNext()
        }
    }

    private func startNext() {
        guard !remaining.isEmpty else {
            configuration = nil
            isInstalling = false
            return
        }
        let pair = remaining.removeFirst()
        configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
    }
}

// MARK: - LanguagePackRow

/// The settings row: what the pack situation is, and the one button that fixes
/// it. Owns the `.translationTask` that the install needs, which is why the
/// modifier hangs on a row rather than on the pane.
struct LanguagePackRow: View {
    @State private var model = LanguagePackModel()

    var body: some View {
        SettingRow(
            icon: "translate",
            title: "Language pack",
            description: "Downloads once from macOS, then translation works offline"
        ) {
            control
        }
        .translationTask(model.configuration) { session in
            await model.prepare(session)
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var control: some View {
        switch model.state {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .ready:
            // A statement of fact, not a control: there is nothing to press
            // once the packs are in place.
            Label("Installed", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        case .missing:
            Button("Install…") { model.install() }
                .disabled(model.isInstalling)
        case .unavailable:
            Text("Not available")
                .foregroundStyle(.secondary)
        }
    }
}
