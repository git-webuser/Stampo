import SwiftUI
import AppKit
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - Tray Item

enum TrayItem: Identifiable, Equatable {
    case color(TrayColor)
    case screenshot(TrayScreenshot)

    var id: UUID {
        switch self {
        case .color(let c): return c.id
        case .screenshot(let s): return s.id
        }
    }
}

struct TrayColor: Identifiable, Equatable {
    let id = UUID()
    let color: NSColor
    let hex: String
}

struct TrayScreenshot: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

// MARK: - Tray Model

final class NotchTrayModel: ObservableObject {
    @Published private(set) var items: [TrayItem] = []

    /// Backward-compat: цвета (используется в Controller)
    var colors: [TrayColor] {
        items.compactMap {
            if case .color(let c) = $0 { return c } else { return nil }
        }
    }

    func add(color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let hex = c.hexString

        // Дедуп по hex
        items.removeAll {
            if case .color(let existing) = $0 { return existing.hex == hex }
            return false
        }
        items.insert(.color(TrayColor(color: c, hex: hex)), at: 0)
        trim()
    }

    func add(screenshotURL url: URL) {
        // Дедуп по URL
        items.removeAll {
            if case .screenshot(let s) = $0 { return s.url == url }
            return false
        }
        items.insert(.screenshot(TrayScreenshot(url: url)), at: 0)
        trim()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    private func trim() {
        if items.count > 12 { items = Array(items.prefix(12)) }
    }
}

// MARK: - Color Scheme

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
        case .hex: return c.hexString
        case .rgb: return c.rgbString
        }
    }
}

// MARK: - NotchTrayView

struct NotchTrayView: View {
    let metrics: NotchMetrics
    @ObservedObject var trayModel: NotchTrayModel
    let isTrayActive: Bool
    let onBack: () -> Void

    @State private var scheme: ColorSchemeType = .hex

    // Figma viewBox: 536×89. Верхняя часть (нотч) = 34pt, нижняя = 55pt.
    private var scrollPadH:   CGFloat { 16 }
    private var scrollPadTop: CGFloat { 8  }
    private var scrollPadBot: CGFloat { 16 }
    private var cellH:        CGFloat { 36 }
    private var bottomRadius: CGFloat { 16 }

    // Высота нижней части = 89 - 34 = 55pt (из Figma)
    var scrollRowHeight: CGFloat { 55 }
    var trayHeight:      CGFloat { metrics.panelHeight + scrollRowHeight }

    var body: some View {
        Group {
            if metrics.hasNotch {
                notchLayout
            } else {
                noNotchLayout
            }
        }
        .frame(height: trayHeight)
    }

    // MARK: - Notch layout

    private var notchLayout: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let shoulders  = (totalWidth - metrics.notchGap) / 2

            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // Верхний ряд — кнопки
                    HStack(spacing: 0) {
                        HStack(spacing: metrics.gap) {
                            backButton
                            schemeMenu
                        }
                        .padding(.leading, metrics.edgeSafe)
                        .frame(width: shoulders, alignment: .leading)

                        Color.clear.frame(width: metrics.notchGap)

                        HStack(spacing: metrics.gap) {
                            trayIconButton
                            moreButton
                        }
                        .padding(.trailing, metrics.edgeSafe)
                        .frame(width: shoulders, alignment: .trailing)
                    }
                    .frame(height: metrics.panelHeight)

                    // Нижний ряд — скролл
                    unifiedScrollView
                        .padding(.horizontal, scrollPadH)
                        .padding(.top, scrollPadTop)
                        .padding(.bottom, scrollPadBot)
                }
            }
        }
    }

    // MARK: - No-notch layout

    private var noNotchLayout: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: metrics.gap) {
                    backButton
                    schemeMenu
                    Spacer()
                    trayIconButton
                    moreButton
                }
                .padding(.horizontal, scrollPadH)
                .frame(height: metrics.panelHeight)

                unifiedScrollView
                    .padding(.horizontal, scrollPadH)
                    .padding(.top, scrollPadTop)
                    .padding(.bottom, scrollPadBot)
            }
        }
    }

    // MARK: - Buttons

    private var backButton: some View {
        PanelIconButton(systemName: "chevron.left", size: 14, weight: .semibold, action: onBack)
            .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var trayIconButton: some View {
        PanelIconButton(
            systemName: "photo.on.rectangle.angled",
            size: 13,
            weight: .regular,
            isActive: true,
            action: {}
        )
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    private var moreButton: some View {
        PanelMenuButton(
            systemName: "ellipsis.circle",
            size: 14,
            weight: .semibold
        ) {
            Button("Settings") {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            Divider()
            Button("Quit NotchShot") { NSApp.terminate(nil) }
        }
        .frame(width: metrics.cellWidth, height: metrics.iconSize)
    }

    // MARK: - Scheme menu

    private var schemeMenuWidth: CGFloat { 68 }

    private var schemeMenu: some View {
        Menu {
            ForEach(ColorSchemeType.allCases, id: \.self) { s in
                Button(s.title) { scheme = s }
            }
        } label: {
            HStack(spacing: 5) {
                Text(scheme.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
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
        .frame(width: schemeMenuWidth)
    }

    // MARK: - Scroll

    private var unifiedScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(trayModel.items) { item in
                    switch item {
                    case .screenshot(let shot):
                        TrayScreenshotCell(
                            shot: shot,
                            height: cellH,
                            cornerRadius: metrics.buttonRadius,
                            onRemove: { trayModel.remove(id: shot.id) }
                        )
                    case .color(let c):
                        TrayColorCell(
                            item: c,
                            scheme: scheme,
                            height: cellH,
                            cornerRadius: metrics.buttonRadius
                        )
                    }
                }
            }
        }
    }
}

private struct TrayBackgroundShape: Shape {
    let notchGap:     CGFloat
    let notchHeight:  CGFloat
    let scrollHeight: CGFloat
    let bottomRadius: CGFloat
    let pixel:        CGFloat

    func path(in rect: CGRect) -> Path {
        let sx = rect.width  / 536
        let sy = (notchHeight + scrollHeight) / 89

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY - pixel + y * sy)
        }

        var path = Path()
        path.move(to: p(0, 0))
        path.addCurve(to: p(8.827, 0.761),   control1: p(4.659, 0),    control2: p(6.989, 0))
        path.addCurve(to: p(14.239, 6.173),  control1: p(11.277, 1.776), control2: p(13.224, 3.723))
        path.addCurve(to: p(15, 15),         control1: p(15, 8.011),   control2: p(15, 10.341))
        path.addLine(to:  p(15, 63.4))
        path.addCurve(to: p(16.744, 80.264), control1: p(15, 72.361),  control2: p(15, 76.841))
        path.addCurve(to: p(23.736, 87.256), control1: p(18.278, 83.274), control2: p(20.726, 85.722))
        path.addCurve(to: p(40.6, 89),       control1: p(27.159, 89),  control2: p(31.639, 89))
        path.addLine(to:  p(495.4, 89))
        path.addCurve(to: p(512.264, 87.256), control1: p(504.361, 89), control2: p(508.841, 89))
        path.addCurve(to: p(519.256, 80.264), control1: p(515.274, 85.722), control2: p(517.722, 83.274))
        path.addCurve(to: p(521, 63.4),      control1: p(521, 76.841), control2: p(521, 72.361))
        path.addLine(to:  p(521, 15))
        path.addCurve(to: p(521.761, 6.173), control1: p(521, 10.341), control2: p(521, 8.011))
        path.addCurve(to: p(527.173, 0.761), control1: p(522.776, 3.723), control2: p(524.723, 1.776))
        path.addCurve(to: p(536, 0),         control1: p(529.011, 0),  control2: p(531.341, 0))
        path.addLine(to:  p(0, 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Tray Color Cell

private struct TrayColorCell: View {
    let item: TrayColor
    let scheme: ColorSchemeType
    let height: CGFloat
    let cornerRadius: CGFloat

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: item.color))
            .frame(width: height, height: height)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.88 : (isHovered ? 1.06 : 1.0))
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
            .onHover { isHovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in
                        isPressed = false
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(scheme.convert(item.color), forType: .string)
                    }
            )
    }
}

// MARK: - Tray Screenshot Cell

private struct TrayScreenshotCell: View {
    let shot: TrayScreenshot
    let height: CGFloat
    let cornerRadius: CGFloat
    let onRemove: () -> Void

    @StateObject private var loader = ScreenshotThumbnailLoader()
    @State private var isHovered = false
    @State private var isPressed = false

    private var width: CGFloat { height * 1.6 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.12), lineWidth: 1)
                )

            if let img = loader.image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: width, height: height)
        .scaleEffect(isPressed ? 0.88 : (isHovered ? 1.04 : 1.0))
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.15, dampingFraction: 0.7), value: isPressed)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    isPressed = false
                    // Tap: открыть файл (не папку)
                    NSWorkspace.shared.open(shot.url)
                }
        )
        .onDrag {
            NSItemProvider(contentsOf: shot.url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open") {
                NSWorkspace.shared.open(shot.url)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([shot.url])
            }
            Button("Copy") {
                Task.detached(priority: .userInitiated) {
                    let image: NSImage? = autoreleasepool {
                        guard
                            let src = CGImageSourceCreateWithURL(shot.url as CFURL, nil),
                            let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
                        else { return nil }
                        return NSImage(cgImage: cg, size: .zero)
                    }
                    await MainActor.run {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        if let img = image { pb.writeObjects([img, shot.url as NSURL]) }
                        else { pb.writeObjects([shot.url as NSURL]) }
                    }
                }
            }
            Divider()
            Button("Remove from Tray") { onRemove() }
        }
        .task(id: shot.url) {
            loader.load(imageURL: shot.url)
        }
    }
}

// MARK: - Thumbnail Loader (shared, lightweight)

@MainActor
final class ScreenshotThumbnailLoader: ObservableObject {
    @Published var image: NSImage?

    private var loadedURL: URL?
    private var loadTask: Task<Void, Never>?

    deinit { loadTask?.cancel() }

    func load(imageURL: URL, maxPixelSize: CGFloat = 200) {
        guard loadedURL != imageURL else { return }
        image = nil
        loadedURL = imageURL
        loadTask?.cancel()
        let url = imageURL

        loadTask = Task { @MainActor in
            let result: NSImage? = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    guard
                        let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                        let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
                        ] as CFDictionary)
                    else { return nil }
                    return NSImage(cgImage: cg, size: .zero)
                }
            }.value

            guard !Task.isCancelled, self.loadedURL == url else { return }
            image = result
        }
    }
}

// MARK: - PanelIconButton (shared hover/active style)

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
        if isActive { return .white }
        if isPressed { return .white.opacity(1.0) }
        if isHovered { return .white.opacity(1.0) }
        return .white.opacity(0.8)
    }

    private var backgroundFill: Color {
        if isActive { return .white.opacity(0.22) }
        if isPressed { return .white.opacity(0.20) }
        if isHovered { return .white.opacity(0.10) }
        return .clear
    }
}

// MARK: - PanelButtonStyle

/// Кастомный ButtonStyle — перехватывает hover и press без отменя стандартного поведения кнопки.
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
