import SwiftUI

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

struct PopUpMoreButtonWrapper: NSViewRepresentable {
    var onOpen:  () -> Void
    var onClose: () -> Void
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.isBordered       = false
        button.isTransparent    = true
        button.pullsDown        = false
        button.autoresizingMask = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        let settingsItem = NSMenuItem(
            title: LocaleManager.string("Settings", locale: locale),
            action: #selector(Coordinator.settingsTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(settingsItem)
        button.menu?.addItem(.separator())
        let quitItem = NSMenuItem(
            title: LocaleManager.string("Quit Stampo", locale: locale),
            action: #selector(Coordinator.quitTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(quitItem)

        button.menu?.autoenablesItems = false
        settingsItem.state = .off
        quitItem.state     = .off

        button.target       = context.coordinator
        settingsItem.target = context.coordinator
        quitItem.target     = context.coordinator

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
        // item(at:) order: 0 = Settings, 1 = separator, 2 = Quit Stampo.
        button.item(at: 0)?.title = LocaleManager.string("Settings",      locale: locale)
        button.item(at: 2)?.title = LocaleManager.string("Quit Stampo", locale: locale)
        button.selectItem(at: -1)
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpMoreButtonWrapper

        init(_ parent: PopUpMoreButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

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

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        ZStack {
            PopUpMoreButtonWrapper(
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
