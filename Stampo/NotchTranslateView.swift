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

    struct Result: Equatable {
        var source: String
        var translated: String
        var pair: TranslationPair
    }

    private(set) var result: Result?
    /// True while a re-translation into another language is in flight, so the
    /// text can dim rather than vanish and come back.
    private(set) var isReworking = false

    /// Height the translation needs, clamped to what the panel can be.
    ///
    /// A short translation should not hang a wall of empty black off the
    /// notch, and a long one should not push the panel down the screen — so
    /// the body fits its text up to a ceiling and scrolls past it.
    private(set) var bodyHeight: CGFloat = NotchTranslateView.minBodyHeight

    /// Width the body was last measured at, so a re-translation into another
    /// language can be measured without asking the view again.
    private var bodyWidth: CGFloat = 0

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
        self.bodyWidth = bodyWidth
        isReworking = false
        bodyHeight = Self.height(of: result.translated, width: bodyWidth)
    }

    func clear() {
        result = nil
        isReworking = false
    }

    /// Re-runs the original text into `language`.
    ///
    /// The source is translated again rather than the translation being
    /// translated onward: passing a machine translation back through the
    /// machine compounds its mistakes, and the original is right here.
    func retranslate(to language: Locale.Language) {
        guard let current = result, !isReworking else { return }
        let pair = TranslationService.route(for: current.source, target: language)
        guard pair != current.pair else { return }

        isReworking = true
        Task { @MainActor in
            defer { isReworking = false }
            guard let translated = try? await TranslationService.shared.translate(
                current.source, from: pair.source, to: pair.target)
            else { return }
            result = Result(source: current.source, translated: translated, pair: pair)
            bodyHeight = Self.height(of: translated, width: bodyWidth)
        }
    }
}

extension Notification.Name {
    /// Posted with a `TranslationPanelModel.Result` once a translation lands,
    /// so the panel can bring the Translator route up over whatever it was
    /// showing. A notification rather than a callback because the three entry
    /// points reach the translator from three different places in the view
    /// tree, and only one of them can see the controller.
    static let translationDidFinish = Notification.Name("Stampo.translationDidFinish")
}

// MARK: - NotchTranslateView

/// The Translator route: the same panel as the Archive, grown downward, with
/// the translated text in the body and two controls in the notch strip.
struct NotchTranslateView: View {
    let metrics: NotchMetrics
    var model: TranslationPanelModel

    let isPinned: Bool
    let onBack: () -> Void
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
            Text(verbatim: model.result?.translated ?? "")
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
    private static let fadeInset: CGFloat = 7

    /// The stop position of the fade, as a fraction of the body's height.
    ///
    /// Computed from the body height rather than read out of a
    /// `GeometryReader` inside the mask: a mask is handed a size by the view
    /// it masks, and getting a different one than expected puts the softened
    /// band somewhere other than the edges — or, at a reported height of zero,
    /// turns the whole gradient into a fade. The height is already known here.
    private var fadeStop: CGFloat {
        let scrollHeight = max(1, model.bodyHeight - Self.bodyPadding)
        return min(0.5, Self.fadeInset / scrollHeight)
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
            language: model.result?.pair.target ?? Locale.Language(identifier: "ru"),
            metrics: metrics,
            onSelect: { model.retranslate(to: $0) }
        )
        .help("Translation language")
        .accessibilityLabel("Translation language")
    }

    private func copy() {
        guard let text = model.result?.translated, !text.isEmpty else { return }
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
    let metrics: NotchMetrics
    let onSelect: (Locale.Language) -> Void

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
                onSelect: onSelect,
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

// MARK: - PopUpLanguageButtonWrapper

private struct PopUpLanguageButtonWrapper: NSViewRepresentable {
    let language: Locale.Language
    let onSelect: (Locale.Language) -> Void
    var onOpen:  () -> Void
    var onClose: () -> Void
    @Environment(\.locale) private var locale

    /// The pair the app handles. Listed rather than derived so the menu order
    /// is stable — a list that reordered itself by which language was current
    /// would move the item under the pointer.
    static let languages = [
        Locale.Language(identifier: "en"),
        Locale.Language(identifier: "ru"),
    ]

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
        for language in Self.languages {
            button.addItem(withTitle: TranslationService.displayName(language))
            button.lastItem?.state = language.languageCode == self.language.languageCode ? .on : .off
        }
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
            // Index 0 is the pull-down placeholder.
            let index = sender.indexOfSelectedItem - 1
            guard index >= 0, index < PopUpLanguageButtonWrapper.languages.count else { return }
            let language = PopUpLanguageButtonWrapper.languages[index]
            DispatchQueue.main.async { self.parent.onSelect(language) }
        }
    }
}
