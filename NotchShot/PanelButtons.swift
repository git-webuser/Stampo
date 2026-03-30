import SwiftUI

// MARK: - PanelIconButton

/// Единая кнопка-иконка для панели с hover и active состояниями.
struct PanelIconButton: View {
    let systemName: String
    let size: CGFloat
    let weight: Font.Weight
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        systemName: String,
        size: CGFloat = 14,
        weight: Font.Weight = .semibold,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.size = size
        self.weight = weight
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
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

// MARK: - PanelMenuButton

struct PanelMenuButton<MenuContent: View>: View {
    let systemName: String
    let size: CGFloat
    let weight: Font.Weight
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        Menu {
            menuContent()
                .onAppear    { isMenuOpen = true  }
                .onDisappear { isMenuOpen = false }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(foregroundColor)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundFill)
                )
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
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

    private var backgroundFill: Color {
        if isMenuOpen { return .white.opacity(0.22) }
        if isPressed  { return .white.opacity(0.20) }
        if isHovered  { return .white.opacity(0.10) }
        return .clear
    }
}

// MARK: - PanelMoreMenuButton

struct PopUpMoreButtonWrapper: NSViewRepresentable {
    var onOpen:  () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.isBordered       = false
        button.isTransparent    = true
        button.pullsDown        = false
        button.autoresizingMask = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(Coordinator.settingsTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(settingsItem)
        button.menu?.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit NotchShot",
            action: #selector(Coordinator.quitTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(quitItem)

        // Disable selection tracking — this is an action menu, not a picker
        button.menu?.autoenablesItems = false
        settingsItem.state = .off
        quitItem.state     = .off

        button.target = context.coordinator
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
        button.selectItem(at: -1)
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpMoreButtonWrapper

        init(_ parent: PopUpMoreButtonWrapper) { self.parent = parent }

        @objc func settingsTapped() {
            NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil)
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
                        .padding(.vertical, (metrics.iconSize - 24) / 2)
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
        if isPressed  { return .white.opacity(0.20) }
        if isHovered  { return .white.opacity(0.10) }
        return .clear
    }
}

// MARK: - PanelButtonStyle

/// Кастомный ButtonStyle — перехватывает hover и press без отмены стандартного поведения кнопки.
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
