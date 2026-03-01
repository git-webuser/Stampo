import SwiftUI
import AppKit
import CoreGraphics
import Combine

// MARK: - Shared state (used by controller)

enum CaptureMode: CaseIterable {
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

enum CaptureDelay: CaseIterable {
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

struct NotchPanelView: View {
    let cornerRadius: CGFloat
    let hasNotch: Bool
    let notchGap: CGFloat
    let edgeSafe: CGFloat
    let leftMinToNotch: CGFloat
    let rightMinFromNotch: CGFloat

    @ObservedObject var interaction: NotchPanelInteractionState
    let onClose: () -> Void
    let onCapture: (_ mode: CaptureMode, _ delay: CaptureDelay) -> Void

    // Figma sizes
    private let height: CGFloat = 34
    private let cellWidth: CGFloat = 28
    private let iconSize: CGFloat = 24
    private let gap: CGFloat = 8
    private let captureButtonSize = CGSize(width: 71, height: 24)

    private let timerTrailingInset: CGFloat = 8
    private let timerIconToValueGap: CGFloat = 6

    @State private var mode: CaptureMode = .selection
    /// Системное поведение: по умолчанию без задержки.
    @State private var delay: CaptureDelay = .off

    var body: some View {
        Group {
            if hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: height)
        .allowsHitTesting(interaction.isEnabled)
        .animation(nil, value: interaction.isEnabled)
    }

    private var notchLayout: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shoulders = max(0, (w - notchGap) / 2)

            ZStack {
                NotchShape().fill(.black)

                HStack(spacing: 0) {
                    // LEFT
                    HStack(spacing: gap) { closeCell; modeCell; timerCell }
                        .padding(.leading, edgeSafe)
                        .padding(.trailing, leftMinToNotch)
                        .frame(width: shoulders, alignment: .leading)

                    Color.clear.frame(width: notchGap)

                    // RIGHT
                    HStack(spacing: gap) { photoCell; moreCell; captureButton }
                        .padding(.leading, rightMinFromNotch)
                        .padding(.trailing, edgeSafe)
                        .frame(width: shoulders, alignment: .trailing)
                }
                .opacity(contentOpacity)
                .blur(radius: contentBlur)
                .scaleEffect(contentScale)
                .frame(height: height)
            }
        }
    }

    private var noNotchLayout: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black)

            HStack(spacing: gap) {
                closeCell
                modeCell
                timerCell
                photoCell
                moreCell
                captureButton
            }
            .padding(.horizontal, edgeSafe)
            .opacity(contentOpacity)
            .blur(radius: contentBlur)
            .scaleEffect(contentScale)
            .frame(height: height)
        }
    }

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

    private var modeCell: some View {
        Menu {
            ForEach(CaptureMode.allCases, id: \.self) { m in
                Button(m.title) { mode = m }
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: iconSize, height: iconSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: cellWidth, height: iconSize)
    }

    private var timerCell: some View {
        Menu {
            ForEach(CaptureDelay.allCases, id: \.self) { d in
                Button(d.title) { delay = d }
            }
        } label: {
            HStack(spacing: timerIconToValueGap) {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: iconSize, height: iconSize)

                if let label = delay.shortLabel {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(height: 12)
                }
            }
            .padding(.trailing, timerTrailingInset)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(height: iconSize)
    }

    private var photoCell: some View {
        // Быстрый "сделать скрин" (дублирует Capture)
        Button { onCapture(mode, delay) } label: {
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
        Button {
            onCapture(mode, delay)
        } label: {
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

    // MARK: - “Native-ish” content appearance during panel expand/collapse

    private var contentOpacity: Double {
        interaction.contentVisibility
    }

    private var contentBlur: CGFloat {
        // чуть блюра, пока панель “едет”
        let t = CGFloat(1.0 - interaction.contentVisibility)
        return 3.0 * t
    }

    private var contentScale: CGFloat {
        // лёгкий scale, как у системных popover-ish анимаций
        let t = CGFloat(1.0 - interaction.contentVisibility)
        return 1.0 - 0.03 * t
    }
}
