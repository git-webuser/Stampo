import SwiftUI
import AppKit
import Foundation
import Combine

struct NotchTrayView: View {
    let metrics: NotchMetrics

    @ObservedObject var trayModel: NotchTrayModel
    let onBack: () -> Void

    @State private var scheme: ColorSchemeType = .hex

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: metrics.panelHeight)
    }

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders = max(0, (totalWidth - metrics.notchGap) / 2)

            ZStack {
                NotchShape()
                    .fill(Color.black)
                    .compositingGroup()
                    .offset(y: -metrics.pixel)

                HStack(spacing: 0) {
                    leftContent
                        .padding(.leading, metrics.edgeSafe)
                        .padding(.trailing, metrics.leftMinToNotch)
                        .frame(width: shoulders, alignment: .leading)

                    Color.clear.frame(width: metrics.notchGap)

                    rightContent
                        .padding(.leading, metrics.rightMinFromNotch)
                        .padding(.trailing, metrics.edgeSafe)
                        .frame(width: shoulders, alignment: .trailing)
                }
                .frame(height: metrics.panelHeight)
            }
        }
    }

    private var noNotchLayout: some View {
        ZStack {
            RoundedRectangle(cornerRadius: metrics.panelRadius, style: .continuous)
                .fill(Color.black)

            HStack(spacing: metrics.gap) {
                leftContent
                Spacer(minLength: metrics.gap)
                rightContent
            }
            .padding(.horizontal, metrics.outerSideInset)
            .frame(height: metrics.panelHeight)
        }
    }

    private var leftContent: some View {
        HStack(spacing: metrics.gap) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
            .contentShape(Rectangle())

            schemeMenu
        }
    }

    private var schemeMenu: some View {
        Menu {
            ForEach(ColorSchemeType.allCases, id: \.self) { s in
                Button(s.title) { scheme = s }
            }
        } label: {
            HStack(spacing: 6) {
                Text(scheme.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 8)
            .frame(height: metrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                    .fill(Color.white.opacity(0.14))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var rightContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(trayModel.colors) { item in
                    RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                        .fill(Color(nsColor: item.color))
                        .frame(width: metrics.buttonHeight + 2, height: metrics.buttonHeight + 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: metrics.buttonRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .onTapGesture {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                scheme.convert(item.color),
                                forType: .string
                            )
                        }
                }
            }
        }
        .frame(height: metrics.buttonHeight + 4)
    }
}

enum ColorSchemeType: CaseIterable, Equatable {
    case hex
    case rgb

    var title: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        }
    }

    func convert(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        switch self {
        case .hex:
            return c.hexString
        case .rgb:
            return c.rgbString
        }
    }
}



final class NotchTrayModel: ObservableObject {
    @Published private(set) var colors: [TrayColor] = []

    func add(color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let hex = c.hexString

        colors.removeAll { $0.hex == hex }
        colors.insert(TrayColor(color: c, hex: hex), at: 0)

        if colors.count > 8 { colors = Array(colors.prefix(8)) }
    }
}

struct TrayColor: Identifiable, Equatable {
    let id = UUID()
    let color: NSColor
    let hex: String
}
