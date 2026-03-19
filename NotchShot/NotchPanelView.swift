import SwiftUI
import AppKit
import Combine

// MARK: - Capture Mode / Delay (unchanged enums)

enum CaptureMode: CaseIterable, Equatable {
    case selection
    case window
    case screen

    var title: String {
        switch self {
        case .selection: return "Selection"
        case .window: return "Window"
        case .screen: return "Entire Screen"
        }
    }

    var icon: String {
        switch self {
        case .selection: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "menubar.dock.rectangle"
        }
    }
}

enum CaptureDelay: CaseIterable, Equatable {
    case off, s3, s5, s10

    var seconds: Int {
        switch self {
        case .off: return 0
        case .s3: return 3
        case .s5: return 5
        case .s10: return 10
        }
    }

    var title: String {
        switch self {
        case .off: return "No Delay"
        case .s3: return "3 Seconds"
        case .s5: return "5 Seconds"
        case .s10: return "10 Seconds"
        }
    }

    var shortLabel: String? {
        switch self {
        case .off: return nil
        case .s3: return "3"
        case .s5: return "5"
        case .s10: return "10"
        }
    }
}

final class NotchPanelModel: ObservableObject {
    @Published var mode: CaptureMode = .selection
    @Published var delay: CaptureDelay = .off
}

// MARK: - NotchPanelView

struct NotchPanelView: View {
    let metrics: NotchMetrics

    @ObservedObject var interaction: NotchPanelInteractionState
    @ObservedObject var model: NotchPanelModel

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
        .onChange(of: model.mode) { _, _ in onModeDelayChanged() }
    }

    // MARK: Notch layout

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

    // MARK: No-notch layout

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
    }

    private var modeMenuCell: some View {
        PanelMenuButton(
            systemName: model.mode.icon,
            size: 14,
            weight: .semibold
        ) {
            Button {
                model.mode = .selection
            } label: {
                Label("Selection", systemImage: CaptureMode.selection.icon)
            }
            Button {
                model.mode = .window
            } label: {
                Label("Window", systemImage: CaptureMode.window.icon)
            }
            Button {
                model.mode = .screen
            } label: {
                Label("Entire Screen", systemImage: CaptureMode.screen.icon)
            }
            Divider()
            Button {
                onPickColor()
            } label: {
                Label("Pick Color", systemImage: "eyedropper")
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var timerMenuCell: some View {
        let digitCount = timerDigitCount
        let digitsWidth = timerDigitsWidth(for: digitCount)
        let hasValue = digitCount > 0

        return PanelTimerMenuButton(
            model: model,
            metrics: metrics,
            digitsWidth: digitsWidth,
            hasValue: hasValue,
            cellWidth: timerCellWidth(digitsWidth: digitsWidth, hasValue: hasValue)
        )
        .animation(nil, value: model.delay)
    }

    private var trayButtonCell: some View {
        PanelIconButton(
            systemName: "photo.on.rectangle.angled",
            size: 13,
            weight: .regular,
            isActive: isTrayOpen,
            action: onToggleTray
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var moreCell: some View {
        PanelMenuButton(
            systemName: "ellipsis.circle",
            size: 14,
            weight: .semibold
        ) {
            Button("Settings") {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            Divider()
            Button("Quit NotchShot") {
                NSApp.terminate(nil)
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var captureButton: some View {
        PanelCaptureButton(
            metrics: metrics,
            action: { onCapture(model.mode, model.delay) }
        )
    }

    // MARK: - Helpers

    private func timerDigitsWidth(for digitCount: Int) -> CGFloat {
        switch digitCount {
        case 0: return 0
        case 1: return 8
        default: return metrics.timerValueWidth
        }
    }

    private var timerDigitCount: Int {
        model.delay.shortLabel?.count ?? 0
    }

    private func timerCellWidth(digitsWidth: CGFloat, hasValue: Bool) -> CGFloat {
        guard hasValue else { return metrics.cellWidth }
        return metrics.iconSize + metrics.timerIconToValueGap + digitsWidth + metrics.timerTrailingInsetWithValue
    }

    private var contentOpacity: Double {
        let t = interaction.contentVisibility
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return max(0, (t - 0.15) / 0.85)
    }

    private var panelScale: CGFloat { CGFloat(0.97 + 0.03 * interaction.contentVisibility) }
    private var panelSpring: Animation { .spring(response: 0.28, dampingFraction: 0.86) }
    private var contentFade: Animation { .easeOut(duration: 0.16) }
}

// MARK: - PanelMenuButton (Menu + hover/active)

struct PanelMenuButton<MenuContent: View>: View {
    let systemName: String
    let size: CGFloat
    let weight: Font.Weight
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovered    = false
    @State private var isPressed    = false
    @State private var isMenuOpen   = false

    var body: some View {
        Menu {
            menuContent()
                .onAppear  { isMenuOpen = true  }
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
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .scaleEffect(isPressed ? 0.88 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
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

// MARK: - PanelTimerMenuButton

private struct PanelTimerMenuButton: View {
    @ObservedObject var model: NotchPanelModel
    let metrics: NotchMetrics
    let digitsWidth: CGFloat
    let hasValue: Bool
    let cellWidth: CGFloat

    @State private var isHovered  = false
    @State private var isPressed  = false
    @State private var isMenuOpen = false

    var body: some View {
        Menu {
            ForEach(CaptureDelay.allCases, id: \.self) { delay in
                Button(delay.title) { model.delay = delay }
            }
            .onAppear   { isMenuOpen = true  }
            .onDisappear { isMenuOpen = false }
        } label: {
            HStack(spacing: metrics.timerIconToValueGap) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(timerForeground)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)

                Text(model.delay.shortLabel ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: digitsWidth, height: 12, alignment: .leading)
                    .opacity(hasValue ? 1 : 0)
                    .transaction { $0.animation = nil }
            }
            .padding(.trailing, hasValue ? metrics.timerTrailingInsetWithValue : 0)
            .frame(width: cellWidth, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(timerBackground)
                    .frame(width: cellWidth, height: 24)
            )
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: metrics.iconSize)
        .scaleEffect(isPressed ? 0.88 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isPressed)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
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
        if isPressed  { return .white.opacity(0.20) }
        if isHovered  { return .white.opacity(0.10) }
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
