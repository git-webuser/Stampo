import SwiftUI
import AppKit
import Combine

// MARK: - Shared types

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
    case off
    case s3
    case s5
    case s10

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

/// Состояние панели, чтобы контроллер мог динамически менять ширину (особенно на экранах без челки).
final class NotchPanelModel: ObservableObject {
    @Published var mode: CaptureMode = .selection
    @Published var delay: CaptureDelay = .off
}

struct NotchPanelView: View {
    let cornerRadius: CGFloat
    let hasNotch: Bool
    let notchGap: CGFloat
    let edgeSafe: CGFloat
    let leftMinToNotch: CGFloat
    let rightMinFromNotch: CGFloat

    @ObservedObject var interaction: NotchPanelInteractionState
    @ObservedObject var model: NotchPanelModel

    let onClose: () -> Void
    let onCapture: (_ mode: CaptureMode, _ delay: CaptureDelay) -> Void
    let onToggleTray: () -> Void
    let onPickColor: () -> Void
    let onModeDelayChanged: () -> Void

    // Figma sizes
    private let height: CGFloat = 34
    private let cellWidth: CGFloat = 28
    private let iconSize: CGFloat = 24
    private let gap: CGFloat = 8
    private let captureButtonSize = CGSize(width: 71, height: 24)

    private let timerIconToValueGap: CGFloat = 6
    private let timerTrailingInsetWithValue: CGFloat = 8

    var body: some View {
        Group {
            if hasNotch { notchLayout } else { noNotchLayout }
        }
        .frame(height: height)
        .allowsHitTesting(interaction.isEnabled)
        .animation(nil, value: interaction.isEnabled)
        .onChange(of: model.delay) { _ in onModeDelayChanged() }
        .onChange(of: model.mode) { _ in onModeDelayChanged() }
    }

    // MARK: - Layouts

    private var notchLayout: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shoulders = max(0, (w - notchGap) / 2)

            ZStack {
                NotchShape()
                    .fill(.black)
                    .scaleEffect(panelScale)
                    .animation(panelSpring, value: interaction.contentVisibility)

                HStack(spacing: 0) {
                    // LEFT
                    HStack(spacing: gap) { closeCell; modeMenuCell; timerMenuCell }
                        .padding(.leading, edgeSafe)
                        .padding(.trailing, leftMinToNotch)
                        .frame(width: shoulders, alignment: .leading)

                    Color.clear.frame(width: notchGap)

                    // RIGHT
                    HStack(spacing: gap) { trayButtonCell; moreCell; captureButton }
                        .padding(.leading, rightMinFromNotch)
                        .padding(.trailing, edgeSafe)
                        .frame(width: shoulders, alignment: .trailing)
                }
                .opacity(contentOpacity)
                .animation(contentFade, value: interaction.contentVisibility)
                .frame(height: height)
            }
        }
    }

    private var noNotchLayout: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black)
                .scaleEffect(panelScale)
                .animation(panelSpring, value: interaction.contentVisibility)

            HStack(spacing: gap) {
                closeCell
                modeMenuCell
                timerMenuCell
                trayButtonCell
                moreCell
                captureButton
            }
            .padding(.horizontal, edgeSafe)
            .opacity(contentOpacity)
                .animation(contentFade, value: interaction.contentVisibility)
                .frame(height: height)
        }
        .animation(nil, value: model.delay)
        .animation(nil, value: model.mode)
    }

    // MARK: - Cells

    private var closeCell: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: iconSize, height: iconSize)
        }
        .buttonStyle(.plain)
        .frame(width: cellWidth, height: iconSize)
        .contentShape(Rectangle())
    }

    /// Требование: именно Menu (не Submenu), пункты с иконками, плюс Separator и Pick Color.
    private var modeMenuCell: some View {
        Menu {
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
        } label: {
            Image(systemName: model.mode.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: iconSize, height: iconSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: cellWidth, height: iconSize)
    }

    /// Требование: убрать неприятный зазор на no-notch → ширина таймера должна быть динамической,
    /// и trailing inset добавлять только когда есть цифры.
    private var timerMenuCell: some View {
        // Важно: чтобы не было "дёргания" при смене значения таймера,
        // мы НЕ создаём/удаляем Text (он всегда в иерархии),
        // но делаем ширину под цифры 3-состояний:
        // 0 символов (off), 1 символ (3/5), 2 символа (10).
        let digitCount = timerDigitCount
        let digitsWidth = timerDigitsWidth(for: digitCount)
        let hasValue = (digitCount > 0)

        return Menu {
            ForEach(CaptureDelay.allCases, id: \.self) { d in
                Button(d.title) { model.delay = d }
            }
        } label: {
            HStack(spacing: timerIconToValueGap) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: iconSize, height: iconSize)

                // Всегда присутствует в иерархии → нет layout-jump.
                Text(model.delay.shortLabel ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: digitsWidth, height: 12, alignment: .leading)
                    .opacity(hasValue ? 1 : 0)
                    // не даём SwiftUI "переигрывать" метрики текста
                    .transaction { $0.animation = nil }
            }
            .padding(.trailing, hasValue ? timerTrailingInsetWithValue : 0)
            .frame(width: timerCellWidth(digitsWidth: digitsWidth, hasValue: hasValue), alignment: .leading)
            .contentShape(Rectangle())
            // выключаем неявные анимации именно для изменения ширины/паддинга этой ячейки
            .transaction { $0.animation = nil }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: iconSize)
        // и здесь тоже — чтобы смена delay не "тянула" панель
        .animation(nil, value: model.delay)
    }


    /// ВАЖНО: эта кнопка ТЕПЕРЬ не делает скрин — она открывает трей.
    private var trayButtonCell: some View {
        Button(action: onToggleTray) {
            Image(systemName: "photo.stack")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: iconSize, height: iconSize)
        }
        .buttonStyle(.plain)
        .frame(width: cellWidth, height: iconSize)
        .contentShape(Rectangle())
    }

    private var moreCell: some View {
        Menu {
            Button("Settings") {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: iconSize, height: iconSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: cellWidth, height: iconSize)
    }

    private var captureButton: some View {
        Button { onCapture(model.mode, model.delay) } label: {
            Text("Capture")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: captureButtonSize.width, height: captureButtonSize.height)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    // MARK: - Dynamic sizing

    /// 0/1/2 "моноширинных" символа под цифры.
    /// Значения подобраны под SF Pro 12 + monospacedDigit().
    private func timerDigitsWidth(for digitCount: Int) -> CGFloat {
        switch digitCount {
        case 0: return 0
        case 1: return 8
        default: return 16
        }
    }

    private var timerDigitCount: Int {
        guard let label = model.delay.shortLabel else { return 0 }
        return label.count
    }

    private func timerCellWidth(digitsWidth: CGFloat, hasValue: Bool) -> CGFloat {
        // Базовое состояние (off): только иконка в стандартной cellWidth.
        guard hasValue else { return cellWidth }
        // icon + gap + digitsWidth + trailingInset
        return iconSize + timerIconToValueGap + digitsWidth + timerTrailingInsetWithValue
    }

    /// Совместимость со старым именем: "расширенная" ширина (2 символа).
    private var timerCellWidthExpanded: CGFloat {
        timerCellWidth(digitsWidth: timerDigitsWidth(for: 2), hasValue: true)
    }


    // MARK: - Content animation (driven by controller)

    private var contentOpacity: Double {
        let t = interaction.contentVisibility
        if t <= 0 { return 0.0 }
        if t >= 1 { return 1.0 }
        let held = max(0.0, (t - 0.15) / 0.85)
        return held
    }

    // MARK: - Panel animation (background only)

    private var panelScale: CGFloat {
        let t = interaction.contentVisibility
        // Subtle "pop" like macOS: background grows a bit while content fades in.
        return CGFloat(0.97 + 0.03 * t)
    }

    private var panelSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0.0)
    }

    private var contentFade: Animation {
        .easeOut(duration: 0.16)
    }

}
