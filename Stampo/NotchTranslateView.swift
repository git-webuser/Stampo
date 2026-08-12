import AppKit
import SwiftUI

// MARK: - TranslationPanelModel

/// The translation the panel is showing.
///
/// Held apart from `TranslationService`, which is the door to the framework and
/// has no business remembering what is on screen. One live result at a time:
/// the panel shows the last thing asked for, and everything ever translated is
/// in the archive already.
@Observable final class TranslationPanelModel {
    static let shared = TranslationPanelModel()

    private init() {}

    /// What the panel is showing.
    ///
    /// The text and the language it is in — not an original-and-translation
    /// pair. The menu marks this language, and picking another translates
    /// *this* text into it: from Russian to English to German, each step
    /// starting from what is on screen rather than from an original nobody can
    /// see any more. With two languages the difference is invisible; with
    /// three it is the whole behaviour.
    struct Result: Equatable {
        var text: String
        var language: Locale.Language

        /// An archive entry opened for reading, in whatever language it is in.
        ///
        /// A language the app cannot translate *from* yet still marks the menu:
        /// the tick says where the reader is, and that is true whether or not
        /// the pack is downloaded.
        static func preview(of text: String) -> Result {
            switch TranslationService.detect(text) {
            case .installed(let language), .notInstalled(let language):
                return Result(text: text, language: language)
            case .unknown:
                // Nothing recognizable. The menu still has to tick something,
                // and the target is the least surprising thing to tick — it is
                // where an unprompted translation would have gone.
                return Result(text: text, language: TranslationLanguages.shared.destination)
            }
        }
    }

    private(set) var result: Result?
    /// True while the next language is being fetched, so the text can dim
    /// rather than vanish and come back.
    private(set) var isReworking = false

    /// Height the translation needs, clamped to what the panel can be.
    ///
    /// A short translation should not hang a wall of empty black off the
    /// notch, and a long one should not push the panel down the screen — so
    /// the body fits its text up to a ceiling and scrolls past it.
    private(set) var bodyHeight: CGFloat = NotchTranslateView.minBodyHeight

    /// Measured with Foundation rather than by laying the view out and reading
    /// it back.
    ///
    /// A `GeometryReader` in the body could only report after a layout pass,
    /// which is a pass too late: the panel would open at the floor height and
    /// grow afterwards, visibly trailing its own text. Worse, the answer has
    /// to be ignored while the panel is animating — the window's width is
    /// still travelling, so the text re-wraps — and a preference that is
    /// rejected once never fires again, because its value never changes.
    ///
    /// The string, the font and the width are all known before anything is
    /// drawn, so the height is too.
    static func height(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 1 else { return NotchTranslateView.minBodyHeight }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        // A point of slack: SwiftUI's own line breaking can land a hair taller
        // than Foundation's, and being one point short crops a descender.
        let wanted = ceil(bounds.height) + 1 + NotchTranslateView.bodyPadding
        return min(NotchTranslateView.maxBodyHeight,
                   max(NotchTranslateView.minBodyHeight, wanted))
    }

    /// `bodyWidth` is the width the text will be laid out at — the caller
    /// knows the panel's geometry, this type does not.
    func present(_ result: Result, bodyWidth: CGFloat) {
        self.result = result
        isReworking = false
        bodyHeight = Self.height(of: result.text, width: bodyWidth)
    }

    /// Dim the body while the next language is on its way. Cleared by the
    /// result arriving, or by the translation ending without one.
    func beginRework() { isReworking = true }
    func endRework() { isReworking = false }

    func clear() {
        result = nil
        isReworking = false
    }
}

extension Notification.Name {
    /// Posted with a `TranslationPanelModel.Result` once a translation lands,
    /// so the panel can bring the Translator route up over whatever it was
    /// showing. A notification rather than a callback because the three entry
    /// points reach the translator from three different places in the view
    /// tree, and only one of them can see the controller.
    static let translationDidFinish = Notification.Name("Stampo.translationDidFinish")

    /// Posted around the work itself, so the panel can say it is thinking. The
    /// pair is always balanced — the end is posted whatever the outcome, or a
    /// failed translation would leave a ring turning forever.
    static let translationDidStart = Notification.Name("Stampo.translationDidStart")
    /// Carries a String: show this text in the Translator so a language can be
    /// chosen for it. Posted when an unprompted translation had nowhere to send
    /// the text — it was already in the language it would have gone to.
    static let requestTranslatePreview = Notification.Name("Stampo.requestTranslatePreview")
    static let translationDidEnd = Notification.Name("Stampo.translationDidEnd")
}

// MARK: - TranslatingView

/// The wait. A strip the height of the notch row: the translator's glyph on
/// the left shoulder, a turning ring on the right where the countdown puts its
/// arc.
///
/// The ring turns rather than fills. The countdown knows how long it has —
/// that is what a countdown is — while a translation finishes when the model
/// finishes: a first run after launch can take seconds, a second one is
/// instant, and there is no fraction to report. An arc filling towards a
/// completion it cannot see would be a guess drawn as a fact.
struct TranslatingView: View {
    let metrics: NotchMetrics
    var interaction: NotchPanelInteractionState

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isTurning = false

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: metrics.panelHeight)
        .allowsHitTesting(false)
        .onAppear { isTurning = true }
        .onDisappear { isTurning = false }
    }

    /// Both layouts are the same: the strip is its own width, narrow enough
    /// that the notch is not a thing to lay out around — the two glyphs simply
    /// sit at either end of it.
    private var notchLayout: some View { strip }
    private var noNotchLayout: some View { strip }

    private var strip: some View {
        HStack(spacing: 0) {
            glyph
            Spacer(minLength: 0)
            spinner
        }
        // `edgeSafe` is the same 20pt the rest of the panel keeps off the
        // shape's side flares. In the artwork's own coordinates, which start
        // at the flare rather than 7pt before it, that reads as 13 — and
        // leaves the 5pt gap from the wall the design asks for.
        .padding(.horizontal, metrics.edgeSafe)
        .frame(height: metrics.panelHeight)
    }

    private var glyph: some View {
        Image(systemName: "translate")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PanelChrome.foreground(0.9, contrast))
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    /// Same ring as the countdown's — 14pt, 2pt stroke, a faint track under a
    /// bright arc — turning instead of filling.
    private var spinner: some View {
        ZStack {
            Circle()
                .stroke(PanelChrome.stroke(0.15, contrast), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(PanelChrome.stroke(0.8, contrast),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(isTurning ? 360 : 0))
                .animation(isTurning
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default,
                           value: isTurning)
        }
        .frame(width: 14, height: 14)
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    /// Outer width of the strip: two 32 × 24 cells, 20pt of edge inset either
    /// side, and the run between them the artwork sets. Drawn 1:1 — the panel's
    /// morph keyframes are a 536-wide viewBox scaled to the panel, and at this
    /// width that would squash every corner to half its radius while leaving
    /// its height alone.
    static func stripWidth(_ metrics: NotchMetrics) -> CGFloat {
        metrics.edgeSafe * 2 + metrics.cellWidth * 2 + 166
    }
}

// MARK: - NotchTranslateView

/// The Translator route: the same panel as the Archive, grown downward, with
/// the translated text in the body and two controls in the notch strip.
struct NotchTranslateView: View {
    let metrics: NotchMetrics
    var model: TranslationPanelModel

    let isPinned: Bool
    let onBack: () -> Void
    /// Translating needs the archive to file the copy into, which lives with
    /// the controller — so the choice is made here and carried out there.
    let onPickLanguage: (String, Locale.Language) -> Void
    let onTogglePin: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var didCopy = false

    /// Room above and below the text inside the body.
    static let bodyPadding: CGFloat = 22

    /// The text's own inset inside the scroll view, on each side.
    static let textInset: CGFloat = 4

    /// One line plus its padding — the floor, so a two-word translation still
    /// reads as a panel and not as a slot.
    static let minBodyHeight: CGFloat = 40

    /// Six lines of 17pt plus padding: the ceiling, and the height of the
    /// exported artwork (168 against the Archive's 89). Past this the text
    /// scrolls, with no indicator — the same hidden scroll the archive row uses.
    static let maxBodyHeight: CGFloat = 134

    var translateHeight: CGFloat { metrics.panelHeight + model.bodyHeight }

    /// The notch tab tapers inward at the bottom shoulders, so body content has
    /// to sit inside the skew or it spills past the shape — same reasoning and
    /// same number as the archive.
    private var skewInset: CGFloat { metrics.pinnedToTopEdge ? 16 : 0 }

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: translateHeight)
        .clipped()
    }

    // MARK: Layouts

    private var notchLayout: some View {
        GeometryReader { geo in
            let shoulders = (geo.size.width - metrics.notchGap) / 2

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: metrics.gap) {
                        backButton
                        languageMenu
                    }
                    .padding(.leading, metrics.edgeSafe)
                    .frame(width: shoulders, alignment: .leading)

                    Color.clear.frame(width: metrics.notchGap)

                    HStack(spacing: metrics.gap) {
                        copyButton
                        pinButton
                        moreButton
                    }
                    .padding(.trailing, metrics.edgeSafe)
                    .frame(width: shoulders, alignment: .trailing)
                }
                .frame(height: metrics.panelHeight)

                textBody
            }
        }
    }

    private var noNotchLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.gap) {
                backButton
                languageMenu
                Spacer(minLength: metrics.gap)
                copyButton
                pinButton
                moreButton
            }
            .padding(.horizontal, metrics.edgeSafe)
            .frame(height: metrics.panelHeight)

            textBody
        }
    }

    // MARK: Body

    private var textBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Verbatim: a translation is text the user is reading, and a
            // URL-shaped line in it is not something to make tappable.
            Text(verbatim: model.result?.text ?? "")
                .font(.system(size: 13))
                .foregroundStyle(PanelChrome.foreground(0.92, contrast))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Self.textInset)
        }
        // Softened top and bottom — the same thing the archive row does at its
        // left and right edges, turned ninety degrees, and like the archive
        // always on rather than only while there is something to scroll.
        .mask(scrollFade)
        .opacity(model.isReworking ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.15), value: model.isReworking)
        .padding(.horizontal, metrics.edgeSafe + skewInset)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(height: model.bodyHeight)
    }

    /// Height of the softened band at each end of the body.
    ///
    /// Narrow on purpose. The archive softens its row unconditionally and this
    /// does the same, so the panel looks like itself whether or not there is
    /// anything to scroll — but a band as wide as the archive's would eat into
    /// the first and last line of a translation that fits, where the archive
    /// only ever dims the edge of a tile. At 7pt it lands inside the body's
    /// own 10 and 12pt padding, and touches the text only once the text has
    /// grown far enough to reach it.
    static let fadeInset: CGFloat = 7

    /// The stop position of the fade, as a fraction of the body's height.
    ///
    /// Computed from the body height rather than read out of a
    /// `GeometryReader` inside the mask: a mask is handed a size by the view
    /// it masks, and getting a different one than expected puts the softened
    /// band somewhere other than the edges — or, at a reported height of zero,
    /// turns the whole gradient into a fade. The height is already known here.
    private var fadeStop: CGFloat { Self.fadeStop(bodyHeight: model.bodyHeight) }

    /// Split out as a function of the height so it can be pinned by a test.
    /// The gradient itself is not: measuring a 7pt ramp across 17pt lines
    /// means sampling bands that land between them as often as on them, and a
    /// pixel assertion that passes for the wrong reason is worse than none.
    static func fadeStop(bodyHeight: CGFloat) -> CGFloat {
        let scrollHeight = max(1, bodyHeight - bodyPadding)
        return min(0.5, fadeInset / scrollHeight)
    }

    private var scrollFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fadeStop),
                .init(color: .black, location: 1 - fadeStop),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Controls

    private var backButton: some View {
        PanelIconButton(systemName: "chevron.left", size: 14, weight: .semibold, action: onBack)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .help("Back to panel")
            .accessibilityLabel("Back to panel")
    }

    /// Icon only: the right shoulder is the narrow one, and "copy" is the one
    /// verb a document icon has never needed spelling out.
    private var copyButton: some View {
        PanelIconButton(
            systemName: didCopy ? "checkmark" : "doc.on.doc",
            size: 13,
            weight: .semibold,
            isActive: didCopy,
            action: copy
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help("Copy translation")
        .accessibilityLabel("Copy translation")
    }

    /// The same two controls the archive carries, in the same order and the
    /// same place. Pinning matters more here than anywhere: reading a
    /// translated paragraph is exactly when the panel must not close because
    /// the pointer wandered off it.
    private var pinButton: some View {
        PanelIconButton(
            systemName: isPinned ? "pin.fill" : "pin",
            size: 14,
            weight: .semibold,
            isActive: isPinned,
            imageOffset: 1,
            action: onTogglePin
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help(isPinned ? "Unpin panel" : "Pin panel")
        .accessibilityLabel(isPinned ? "Unpin panel" : "Pin panel")
    }

    private var moreButton: some View {
        // No route commands of its own: copying is a button of its own, and
        // the translation is already in the archive, which has the rest.
        PanelMoreMenuButton(metrics: metrics)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .help("Settings and quit")
    }

    private var languageMenu: some View {
        TranslateLanguageMenuButton(
            // The language on show, so the menu's tick marks where the
            // reader is rather than where they might go.
            language: model.result?.language ?? TranslationLanguages.shared.destination,
            // Read here, in a view body, rather than inside the AppKit wrapper:
            // that is what makes the menu rebuild when the user's list changes
            // in Settings.
            languages: TranslationLanguages.shared.favourites,
            metrics: metrics,
            onSelect: pickLanguage,
            onAddLanguage: {
                NotificationCenter.default.post(
                    name: .requestOpenSettings,
                    object: nil,
                    userInfo: [SettingsWindowController.tabUserInfoKey: SettingsTab.archive.rawValue])
            }
        )
        .help("Translation language")
        .accessibilityLabel("Translation language")
    }

    private func pickLanguage(_ language: Locale.Language) {
        guard let current = model.result,
              current.language.languageCode != language.languageCode
        else {
            // Already reading it in that language. Said out loud rather than
            // ignored: the tick is on the item they just pressed.
            ArchiveTranslate.report(.translationUnchanged, on: NSScreen.main)
            return
        }
        model.beginRework()
        onPickLanguage(current.text, language)
    }

    private func copy() {
        guard let text = model.result?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeInOut(duration: 0.12)) { didCopy = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.12)) { didCopy = false }
        }
    }
}

// MARK: - TranslateLanguageMenuButton

/// Target-language chooser, built like the archive's colour-format menu so the
/// two headers read as one control set.
///
/// It names the destination, not the pair: "EN → RU" would not fit the 90pt
/// the left shoulder has left after the back button, and the source is not a
/// choice anyway — it is whatever the text turned out to be.
private struct TranslateLanguageMenuButton: View {
    let language: Locale.Language
    let languages: [Locale.Language]
    let metrics: NotchMetrics
    let onSelect: (Locale.Language) -> Void
    let onAddLanguage: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: TranslationService.displayName(language))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanelChrome.foreground(isHovered || isMenuOpen ? 1 : 0.75, contrast))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PanelChrome.foreground(0.55, contrast))
        }
        .padding(.horizontal, 8)
        .frame(height: metrics.buttonHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                .fill(PanelChrome.fill(isMenuOpen ? 0.28 : (isHovered ? 0.16 : 0.08), contrast))
        )
        .overlay {
            PopUpLanguageButtonWrapper(
                language: language,
                languages: languages,
                onSelect: onSelect,
                onAddLanguage: onAddLanguage,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
        }
        .fixedSize()
        .scaleEffect(isPressed ? 0.88 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        .contentShape(Rectangle())
        .clipped()
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true  }
                .onEnded   { _ in isPressed = false }
        )
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isMenuOpen)
    }
}

// MARK: - TranslateLanguageMenu

/// Where a click in the panel's language pop-up lands.
///
/// Its own type because the arithmetic is the one part of that menu that can
/// be quietly wrong: a pull-down hides its first item as the title, a separator
/// takes an index of its own, and the row past it is not a language at all.
/// An off-by-one here does not crash — it translates into the language next to
/// the one that was pressed.
enum TranslateLanguageMenu {

    /// `nil` means the "Add language…" row: everything past the languages and
    /// the separator leaves for Settings.
    ///
    /// `itemIndex` is `NSPopUpButton.indexOfSelectedItem`, so index 0 is the
    /// pull-down's hidden title and the languages start at 1.
    static func selection(atItemIndex itemIndex: Int,
                          in languages: [Locale.Language]) -> Locale.Language? {
        let index = itemIndex - 1
        guard index >= 0, index < languages.count else { return nil }
        return languages[index]
    }
}

// MARK: - PopUpLanguageButtonWrapper

private struct PopUpLanguageButtonWrapper: NSViewRepresentable {
    let language: Locale.Language
    /// The user's own languages, in their own order. Their order, not one this
    /// menu invents: a list that reordered itself by which language was
    /// current would move the item out from under the pointer.
    let languages: [Locale.Language]
    let onSelect: (Locale.Language) -> Void
    let onAddLanguage: () -> Void
    var onOpen:  () -> Void
    var onClose: () -> Void
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PanelPopUpButton()
        button.isBordered       = false
        button.isTransparent    = true
        button.pullsDown        = true
        button.autoresizingMask = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        // pullsDown = true makes the first item the hidden title, so an empty
        // placeholder goes in front to keep the real first language visible.
        button.addItem(withTitle: "")
        rebuildItems(button)

        button.target = context.coordinator
        button.action = #selector(Coordinator.languageChanged(_:))
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        rebuildItems(button)
    }

    private func rebuildItems(_ button: NSPopUpButton) {
        while button.numberOfItems > 1 { button.removeItem(at: 1) }
        for language in languages {
            button.addItem(withTitle: TranslationService.displayName(language))
            button.lastItem?.state = language.baseCode == self.language.baseCode ? .on : .off
        }
        // Below the languages and behind a separator, because it is not one of
        // them: it installs rather than translates, and it leaves the panel for
        // the settings window — the only surface the system's install sheet
        // will attach to.
        button.menu?.addItem(.separator())
        button.addItem(withTitle: LocaleManager.shared.string("Add language…"))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpLanguageButtonWrapper
        weak var button: NSPopUpButton?
        private var observers: [NSObjectProtocol] = []

        init(_ parent: PopUpLanguageButtonWrapper) {
            self.parent = parent
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let menu = note.object as? NSMenu, menu === self.button?.menu else { return }
                MainActor.assumeIsolated { self.parent.onOpen() }
            })
            observers.append(center.addObserver(
                forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let menu = note.object as? NSMenu, menu === self.button?.menu else { return }
                MainActor.assumeIsolated { self.parent.onClose() }
            })
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        @objc func languageChanged(_ sender: NSPopUpButton) {
            guard let language = TranslateLanguageMenu.selection(
                atItemIndex: sender.indexOfSelectedItem, in: parent.languages)
            else {
                DispatchQueue.main.async { self.parent.onAddLanguage() }
                return
            }
            DispatchQueue.main.async { self.parent.onSelect(language) }
        }
    }
}
