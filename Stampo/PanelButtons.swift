import SwiftUI

// MARK: - PanelPopUpButton

/// NSPopUpButton opens its menu on mouseDown without checking where the click
/// actually landed. During rapid open/close cycles (spam-clicking one popup,
/// then immediately clicking a neighbour) NSHostingView can deliver the next
/// mouseDown to the popup that was tracking last — which then pops the wrong
/// menu. Guard: only accept mouse-downs whose location falls inside our bounds.
final class PanelPopUpButton: NSPopUpButton {
    override func mouseDown(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        super.mouseDown(with: event)
    }
}

// MARK: - PanelIconButton

/// Unified icon button for the panel with hover and active states.
struct PanelIconButton: View {
    let systemName: String
    let size: CGFloat
    let weight: Font.Weight
    let isActive: Bool
    let imageOffset: CGFloat
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        systemName: String,
        size: CGFloat = 14,
        weight: Font.Weight = .semibold,
        isActive: Bool = false,
        imageOffset: CGFloat = 0,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.size = size
        self.weight = weight
        self.isActive = isActive
        self.imageOffset = imageOffset
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(foregroundColor)
                .offset(y: imageOffset)
                .frame(width: 24, height: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundFill)
                )
        }
        .buttonStyle(PanelButtonStyle(isHovered: $isHovered, isPressed: $isPressed))
        .contentShape(Rectangle())
    }

    private var foregroundColor: Color {
        if isPressed { return .white }
        if isHovered { return .white }
        if isActive  { return .white }
        return .white.opacity(0.8)
    }

    private var backgroundFill: Color {
        if isPressed             { return .white.opacity(0.28) }
        if isActive && isHovered { return .white.opacity(0.32) }
        if isHovered             { return .white.opacity(0.16) }
        if isActive              { return .white.opacity(0.22) }
        return .clear
    }
}

// MARK: - PanelMoreMenuButton

/// A caller-supplied command in the "⋯" menu, rendered above Settings/Quit.
/// The archive uses these for its whole-archive actions; the main panel passes none.
struct PanelMenuCommand {
    /// Localization key, also the item's identity for the rebuild check.
    let titleKey: String
    /// The glyph from the app's shared vocabulary. The same verbs appear in the
    /// cells' context menus, and a command that wears one symbol there and none
    /// here reads as a different command.
    var icon: MenuIcon? = nil
    var isEnabled: Bool = true
    /// Puts a separator above this item — how a destructive row is set apart
    /// from the ones above it, as in every context menu in the app.
    var startsSection: Bool = false
    let action: () -> Void
}

/// Renders a command list as SwiftUI menu rows.
///
/// The same list can then be shown two ways: by the AppKit popup a header
/// button opens, and by a cell's context menu. They used to be written twice
/// and drifted exactly as you would expect — the same four verbs carried icons
/// and a divider in a cell, and neither on the button.
@ViewBuilder
func panelMenuRows(_ commands: [PanelMenuCommand]) -> some View {
    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
        if command.startsSection, index > 0 { Divider() }
        if let icon = command.icon {
            MenuCommandButton(LocalizedStringKey(command.titleKey),
                              icon: icon, action: command.action)
                .disabled(!command.isEnabled)
        } else {
            Button(action: command.action) {
                Text(LocalizedStringKey(command.titleKey))
            }
            .disabled(!command.isEnabled)
        }
    }
}

struct PopUpMoreButtonWrapper: NSViewRepresentable {
    var extraCommands: [PanelMenuCommand] = []
    /// Whether Settings and Quit are tacked on below the extras. The "⋯" is the
    /// app's only menu and has to carry them; a button that opens one specific
    /// set of commands — the archive's selection verbs — must not.
    var includesAppCommands: Bool = true
    /// Localization key for the button VoiceOver focuses (the NSPopUpButton is
    /// what it lands on — a SwiftUI label on the wrapping ZStack does not
    /// reliably reach it).
    var accessibilityKey: String = "Settings and quit"
    /// Already-localized value spoken after the label — the selection button's
    /// count. nil for a menu that is a list of commands rather than a choice,
    /// which is what the "⋯" is.
    var accessibilityValue: String? = nil
    var onOpen:  () -> Void
    var onClose: () -> Void
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PanelPopUpButton()
        button.isBordered       = false
        button.isTransparent    = true
        button.pullsDown        = false
        button.autoresizingMask = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        button.menu?.autoenablesItems = false
        button.target = context.coordinator
        context.coordinator.includesAppCommands = includesAppCommands
        context.coordinator.rebuildMenu(in: button, commands: extraCommands, locale: locale)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.menuWillOpen(_:)),
            name: NSPopUpButton.willPopUpNotification,
            object: button
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.menuDidClose(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: button.menu
        )

        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        // Closures capture caller state, so always refresh them; the item list
        // itself is only rebuilt when its shape actually changed (see
        // rebuildMenu) — replacing items under an open menu would flicker.
        context.coordinator.commands = extraCommands
        context.coordinator.includesAppCommands = includesAppCommands
        context.coordinator.rebuildMenu(in: button, commands: extraCommands, locale: locale)
        // The NSPopUpButton is what VoiceOver focuses; a SwiftUI label on the
        // ZStack that wraps it doesn't reliably reach it, so both halves are set
        // from here. The "⋯" passes no value: it is a list of commands rather
        // than a choice, and nothing in it is ever selected (see the
        // selectItem(at: -1) below).
        button.setAccessibilityLabel(LocaleManager.string(accessibilityKey, locale: locale))
        button.setAccessibilityValue(accessibilityValue)
        button.selectItem(at: -1)
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpMoreButtonWrapper
        /// Live commands, re-assigned on every update so a menu item always
        /// runs the current closure.
        var commands: [PanelMenuCommand] = []
        var includesAppCommands = true
        /// Shape of the menu as last built: titles + enablement + language.
        private var menuSignature: String?

        init(_ parent: PopUpMoreButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        /// Rebuilds `[extras…] [separator] Settings [separator] Quit`, but only
        /// when the shape changed — the same NSMenu instance is kept throughout
        /// so the didEndTracking observer registered against it stays valid.
        func rebuildMenu(in button: NSPopUpButton, commands: [PanelMenuCommand], locale: Locale) {
            self.commands = commands
            let signature = commands
                .map { "\($0.titleKey)|\($0.isEnabled)|\($0.icon?.rawValue ?? "")|\($0.startsSection)" }
                .joined(separator: ",") + "#\(locale.identifier)#\(includesAppCommands)"
            guard signature != menuSignature, let menu = button.menu else { return }
            menuSignature = signature

            menu.removeAllItems()
            for (index, command) in commands.enumerated() {
                if command.startsSection, index > 0 { menu.addItem(.separator()) }
                let item = NSMenuItem(
                    title: LocaleManager.string(command.titleKey, locale: locale),
                    action: #selector(extraCommandTapped(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.isEnabled = command.isEnabled
                item.tag = index
                item.state = .off
                item.image = Self.menuImage(command.icon)
                menu.addItem(item)
            }
            guard includesAppCommands else { return }
            if !commands.isEmpty { menu.addItem(.separator()) }

            for (titleKey, icon, selector) in [
                ("Settings", MenuIcon.settings, #selector(settingsTapped)),
                ("Quit Stampo", MenuIcon.quit, #selector(quitTapped))
            ] {
                if titleKey == "Quit Stampo" { menu.addItem(.separator()) }
                let item = NSMenuItem(
                    title: LocaleManager.string(titleKey, locale: locale),
                    action: selector,
                    keyEquivalent: ""
                )
                item.target = self
                item.state = .off
                item.image = Self.menuImage(icon)
                menu.addItem(item)
            }
        }

        /// A menu row's glyph, asked for by point size and left at whatever
        /// size it comes back.
        ///
        /// The sizes differ between symbols — `doc.on.doc` returns 16×18 where
        /// `xmark.circle` returns 15×15 — and that is deliberate on Apple's
        /// side, not something to correct: SF Symbols are balanced optically
        /// rather than geometrically, so a round glyph is drawn smaller than a
        /// square one to carry the same weight beside it. Pinning them all to
        /// one square makes the bounding boxes agree and the glyphs stop
        /// agreeing, which is the half a reader actually sees.
        ///
        /// A row with no icon gets a blank instead, for the reason
        /// `MenuCommandLabel(indented:)` draws one: without it the title slides
        /// left, out of the column every other row keeps.
        private static func menuImage(_ icon: MenuIcon?) -> NSImage {
            guard let icon,
                  let image = NSImage(systemSymbolName: icon.rawValue,
                                      accessibilityDescription: nil)?
                      .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            else { return NSImage(size: NSSize(width: 14, height: 14)) }
            image.isTemplate = true
            return image
        }

        @objc func extraCommandTapped(_ sender: NSMenuItem) {
            guard commands.indices.contains(sender.tag) else { return }
            commands[sender.tag].action()
        }

        @objc func settingsTapped() {
            SettingsWindowController.shared.open()
        }

        @objc func quitTapped() {
            NSApp.terminate(nil)
        }

        @objc func menuWillOpen(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onOpen() }
        }

        @objc func menuDidClose(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onClose() }
        }
    }
}

struct PanelMoreMenuButton: View {
    let metrics: NotchMetrics
    /// Route-specific commands shown above Settings/Quit (the archive's
    /// whole-archive actions); empty on the main panel.
    var extraCommands: [PanelMenuCommand] = []

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        ZStack {
            PopUpMoreButtonWrapper(
                extraCommands: extraCommands,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
            .frame(width: metrics.cellWidth, height: metrics.iconSize)

            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
                .frame(width: metrics.cellWidth, height: metrics.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
                .allowsHitTesting(false)
        }
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
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

    private var foregroundColor: Color {
        if isMenuOpen { return .white }
        if isPressed  { return .white }
        if isHovered  { return .white }
        return .white.opacity(0.8)
    }

    private var backgroundColor: Color {
        if isMenuOpen { return .white.opacity(0.22) }
        if isPressed  { return .white.opacity(0.28) }
        if isHovered  { return .white.opacity(0.16) }
        return .clear
    }
}

// MARK: - PanelButtonStyle

/// Custom ButtonStyle that tracks hover and press without cancelling standard button behaviour.
struct PanelButtonStyle: ButtonStyle {
    @Binding var isHovered: Bool
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
            .onHover { isHovered = $0 }
            .onChange(of: configuration.isPressed) { _, v in isPressed = v }
    }
}
