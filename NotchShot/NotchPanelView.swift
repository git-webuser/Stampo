import SwiftUI
import AppKit


// MARK: - CaptureMode

enum CaptureMode: CaseIterable, Equatable {
    case selection
    case window
    case screen

    var title: String {
        switch self {
        case .selection: return "Selection"
        case .window:    return "Window"
        case .screen:    return "Entire Screen"
        }
    }

    var icon: String {
        switch self {
        case .selection: return "rectangle.dashed"
        case .window:    return "macwindow"
        case .screen:    return "menubar.dock.rectangle"
        }
    }

    var shortLabel: String {
        switch self {
        case .selection: return "Sel"
        case .window:    return "Win"
        case .screen:    return "Full"
        }
    }
}

// MARK: - CaptureDelay

enum CaptureDelay: CaseIterable, Equatable {
    case off, s3, s5, s10

    var seconds: Int {
        switch self {
        case .off:  return 0
        case .s3:   return 3
        case .s5:   return 5
        case .s10:  return 10
        }
    }

    var title: String {
        switch self {
        case .off:  return "No Delay"
        case .s3:   return "3 Seconds"
        case .s5:   return "5 Seconds"
        case .s10:  return "10 Seconds"
        }
    }

    var shortLabel: String? {
        switch self {
        case .off:  return nil
        case .s3:   return "3"
        case .s5:   return "5"
        case .s10:  return "10"
        }
    }
}

// MARK: - NotchPanelModel

@Observable final class NotchPanelModel {
    var mode: CaptureMode   = AppSettings.defaultCaptureMode
    var delay: CaptureDelay = AppSettings.defaultTimerDelay
}

// MARK: - NotchPanelView

struct NotchPanelView: View {
    let metrics: NotchMetrics

    var interaction: NotchPanelInteractionState
    var model: NotchPanelModel

    let isTrayOpen: Bool

    let onClose: () -> Void
    let onCapture: (_ mode: CaptureMode, _ delay: CaptureDelay) -> Void
    let onToggleTray: () -> Void
    let onPickColor: () -> Void
    let onModeDelayChanged: () -> Void

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: metrics.panelHeight)
        .allowsHitTesting(interaction.isEnabled)
        .animation(nil, value: interaction.isEnabled)
        .onChange(of: model.delay) { _, _ in onModeDelayChanged() }
        .onChange(of: model.mode)  { _, _ in onModeDelayChanged() }
    }

    // MARK: - Notch layout

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders = max(0, (totalWidth - metrics.notchGap) / 2)

            ZStack {
                HStack(spacing: 0) {
                    HStack(spacing: metrics.gap) {
                        closeCell
                        modeMenuCell
                        timerMenuCell
                    }
                    .padding(.leading, metrics.edgeSafe)
                    .padding(.trailing, metrics.leftMinToNotch)
                    .frame(width: shoulders, alignment: .leading)

                    Color.clear.frame(width: metrics.notchGap)

                    HStack(spacing: metrics.gap) {
                        trayButtonCell
                        moreCell
                        captureButton
                    }
                    .padding(.leading, metrics.rightMinFromNotch)
                    .padding(.trailing, metrics.edgeSafe)
                    .frame(width: shoulders, alignment: .trailing)
                }
                .frame(height: metrics.panelHeight)
                .opacity(contentOpacity)
                .animation(contentFade, value: interaction.contentVisibility)
            }
        }
    }

    // MARK: - No-notch layout

    private var noNotchLayout: some View {
        ZStack {
            HStack(spacing: metrics.gap) {
                closeCell
                modeMenuCell
                timerMenuCell
                trayButtonCell
                moreCell
                captureButton
            }
            .padding(.horizontal, metrics.outerSideInset)
            .frame(height: metrics.panelHeight)
            .opacity(contentOpacity)
            .animation(contentFade, value: interaction.contentVisibility)
        }
        .animation(nil, value: model.delay)
        .animation(nil, value: model.mode)
    }

    // MARK: - Cells

    private var closeCell: some View {
        PanelIconButton(
            systemName: "xmark.circle.fill",
            size: 14,
            weight: .semibold,
            action: onClose
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help("Close panel")
        .accessibilityLabel("Close panel")
    }

    private var modeMenuCell: some View {
        PanelModeMenuButton(
            model: model,
            metrics: metrics,
            onPickColor: onPickColor
        )
        .animation(nil, value: model.mode)
        .help("Capture mode")
        .accessibilityLabel("Capture mode: \(model.mode.title)")
    }

    private var timerMenuCell: some View {
        let shortLabel = model.delay.shortLabel
        return PanelTimerMenuButton(
            model: model,
            metrics: metrics,
            digitsWidth: metrics.timerDigitsWidth(for: shortLabel),
            hasValue: shortLabel != nil,
            cellWidth: metrics.timerCellWidth(for: shortLabel)
        )
        .animation(nil, value: model.delay)
        .help("Capture delay")
        .accessibilityLabel(shortLabel == nil ? "No delay" : "Delay: \(shortLabel ?? "") seconds")
    }

    private var trayButtonCell: some View {
        PanelIconButton(
            systemName: "photo.on.rectangle.angled",
            size: 14,
            weight: .semibold,
            isActive: isTrayOpen,
            action: onToggleTray
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
        .help(isTrayOpen ? "Hide tray" : "Show tray")
        .accessibilityLabel(isTrayOpen ? "Hide tray" : "Show tray")
    }

    private var moreCell: some View {
        PanelMoreMenuButton(metrics: metrics)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .help("Settings and quit")
            .accessibilityLabel("Settings and quit")
    }

    private var captureButton: some View {
        PanelCaptureButton(
            metrics: metrics,
            action: { onCapture(model.mode, model.delay) }
        )
        .accessibilityLabel("Take screenshot")
        .accessibilityHint("Capture in \(model.mode.title) mode")
    }

    // MARK: - Helpers

    private var contentOpacity: Double {
        let t = interaction.contentVisibility
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return max(0, (t - 0.15) / 0.85)
    }

    private var contentFade: Animation { .easeOut(duration: 0.16) }
}

// MARK: - PopUpModeButtonWrapper

private struct PopUpModeButtonWrapper: NSViewRepresentable {
    @Binding var selection: CaptureMode
    var onPickColor: () -> Void
    var onOpen:  () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.isBordered        = false
        button.isTransparent     = true
        button.pullsDown         = false
        button.autoresizingMask  = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.setAccessibilityLabel("Capture mode")

        for mode in CaptureMode.allCases {
            button.addItem(withTitle: mode.title)
        }
        button.menu?.addItem(.separator())
        let pickItem = NSMenuItem(
            title: "Pick Color",
            action: #selector(Coordinator.pickColorTapped),
            keyEquivalent: ""
        )
        button.menu?.addItem(pickItem)

        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        pickItem.target = context.coordinator

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
        let idx = CaptureMode.allCases.firstIndex(of: selection) ?? 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            button.selectItem(at: idx)
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpModeButtonWrapper

        init(_ parent: PopUpModeButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let cases = CaptureMode.allCases
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < cases.count else { return }
            DispatchQueue.main.async { self.parent.selection = cases[idx] }
        }

        @objc func pickColorTapped() {
            DispatchQueue.main.async { self.parent.onPickColor() }
        }

        @objc func menuWillOpen(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onOpen() }
        }

        @objc func menuDidClose(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onClose() }
        }
    }
}

// MARK: - PopUpButtonWrapper

private struct PopUpButtonWrapper: NSViewRepresentable {
    @Binding var selection: CaptureDelay
    var onOpen:  () -> Void
    var onClose: () -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton()
        button.isBordered        = false
        button.isTransparent     = true
        button.pullsDown         = false
        button.autoresizingMask  = []
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.setAccessibilityLabel("Capture delay")

        for delay in CaptureDelay.allCases {
            button.addItem(withTitle: delay.title)
        }

        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))

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
        let idx = CaptureDelay.allCases.firstIndex(of: selection) ?? 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            button.selectItem(at: idx)
        }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpButtonWrapper

        init(_ parent: PopUpButtonWrapper) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let cases = CaptureDelay.allCases
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < cases.count else { return }
            DispatchQueue.main.async { self.parent.selection = cases[idx] }
        }

        @objc func menuWillOpen(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onOpen() }
        }

        @objc func menuDidClose(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onClose() }
        }
    }
}

// MARK: - PanelModeMenuButton

private struct PanelModeMenuButton: View {
    var model: NotchPanelModel
    let metrics: NotchMetrics
    let onPickColor: () -> Void

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        @Bindable var model = model
        return ZStack {
            PopUpModeButtonWrapper(
                selection: $model.mode,
                onPickColor: onPickColor,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
            .frame(width: metrics.cellWidth, height: metrics.iconSize)

            Image(systemName: model.mode.icon)
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

// MARK: - PanelTimerMenuButton

private struct PanelTimerMenuButton: View {
    var model: NotchPanelModel
    let metrics: NotchMetrics
    let digitsWidth: CGFloat
    let hasValue: Bool
    let cellWidth: CGFloat

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        @Bindable var model = model
        return ZStack {
            PopUpButtonWrapper(
                selection: $model.delay,
                onOpen:  { isMenuOpen = true  },
                onClose: { isMenuOpen = false }
            )
            .frame(width: cellWidth, height: metrics.iconSize)

            HStack(spacing: metrics.timerIconToValueGap) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(timerForeground)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)

                if hasValue {
                    Text(model.delay.shortLabel ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: digitsWidth, height: 12, alignment: .leading)
                }
            }
            .padding(.leading,  hasValue ? metrics.timerLeadingInsetWithValue  : 0)
            .padding(.trailing, hasValue ? metrics.timerTrailingInsetWithValue : 0)
            .frame(width: cellWidth, height: metrics.iconSize, alignment: hasValue ? .leading : .center)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(timerBackground)
            )
            .scaleEffect(isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
            .allowsHitTesting(false)
        }
        .frame(width: cellWidth, height: metrics.iconSize)
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

    private var timerForeground: Color {
        if isMenuOpen { return .white }
        if isPressed  { return .white }
        if isHovered  { return .white }
        return .white.opacity(0.8)
    }

    private var timerBackground: Color {
        if isMenuOpen { return .white.opacity(0.22) }
        if isPressed  { return .white.opacity(0.28) }
        if isHovered  { return .white.opacity(0.16) }
        return .clear
    }
}

// MARK: - PanelCaptureButton

private struct PanelCaptureButton: View {
    let metrics: NotchMetrics
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text("Capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPressed ? .white : isHovered ? .white : .white.opacity(0.8))
                .frame(width: metrics.captureButtonWidth, height: metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                        .fill(captureBackground)
                )
        }
        .buttonStyle(PanelButtonStyle(isHovered: $isHovered, isPressed: $isPressed))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private var captureBackground: Color {
        if isPressed { return .white.opacity(0.28) }
        if isHovered { return .white.opacity(0.22) }
        return .white.opacity(0.14)
    }
}

// MARK: - CountdownView

struct CountdownView: View {
    let metrics: NotchMetrics
    var interaction: NotchPanelInteractionState
    let secondsRemaining: Int
    let totalSeconds: Int
    let onStop: () -> Void
    let onCaptureNow: () -> Void

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: metrics.panelHeight)
        .allowsHitTesting(interaction.isEnabled)
        .animation(nil, value: interaction.isEnabled)
    }

    // MARK: - Notch layout

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders = max(0, (totalWidth - metrics.notchGap) / 2)

            HStack(spacing: 0) {
                HStack(spacing: metrics.gap) {
                    stopCell
                    arcIndicator
                }
                .padding(.leading, metrics.edgeSafe)
                .padding(.trailing, metrics.leftMinToNotch)
                .frame(width: shoulders, alignment: .leading)

                Color.clear.frame(width: metrics.notchGap)

                HStack(spacing: metrics.gap) {
                    captureNowCell
                }
                .padding(.leading, metrics.rightMinFromNotch)
                .padding(.trailing, metrics.edgeSafe)
                .frame(width: shoulders, alignment: .trailing)
            }
            .frame(height: metrics.panelHeight)
            .opacity(contentOpacity)
            .animation(contentFade, value: interaction.contentVisibility)
        }
    }

    // MARK: - No-notch layout

    private var noNotchLayout: some View {
        HStack(spacing: metrics.gap) {
            stopCell
            arcIndicator
            Spacer()
            captureNowCell
        }
        .padding(.horizontal, metrics.outerSideInset)
        .frame(height: metrics.panelHeight)
        .opacity(contentOpacity)
        .animation(contentFade, value: interaction.contentVisibility)
    }

    // MARK: - Cells

    private var stopCell: some View {
        PanelIconButton(
            systemName: "xmark.circle.fill",
            size: 14,
            weight: .semibold,
            action: onStop
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var arcIndicator: some View {
        HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 2)
                    .frame(width: 14, height: 14)

                Circle()
                    .trim(from: 0, to: arcProgress)
                    .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1.0), value: arcProgress)
            }
            .frame(width: 24, height: 24)

            Text("\(secondsRemaining)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: metrics.timerValueWidth, alignment: .leading)
                .animation(nil, value: secondsRemaining)
        }
    }

    private var captureNowCell: some View {
        PanelCaptureButton(metrics: metrics, action: onCaptureNow)
    }

    // MARK: - Helpers

    /// Elapsed fraction: 0 at start, approaches 1 as countdown ends.
    private var arcProgress: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSeconds - secondsRemaining) / Double(totalSeconds)
    }

    private var contentOpacity: Double {
        let t = interaction.contentVisibility
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return max(0, (t - 0.15) / 0.85)
    }

    private var contentFade: Animation { .easeOut(duration: 0.16) }
}
