import SwiftUI

// MARK: - AppearanceModePicker
//
// Visual thumbnail picker for app theme — System (split), Light, Dark.
// Inspired by Snapzy (BSD 3-Clause), adapted for Stampo's SettingsAppearance type.

struct AppearanceModePicker: View {
    @Binding var selection: SettingsAppearance

    var body: some View {
        HStack(spacing: 14) {
            ForEach(SettingsAppearance.allCases, id: \.self) { mode in
                AppearanceThumbnailView(mode: mode, isSelected: selection == mode) {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AppearanceThumbnailView: View {
    let mode: SettingsAppearance
    let isSelected: Bool
    let action: () -> Void

    /// Localized display name as a key — resolved via environment locale injected by managedLocale().
    private var modeTitleKey: LocalizedStringKey {
        switch mode {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnailPreview
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)

                Text(modeTitleKey)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailPreview: some View {
        if mode == .system {
            // Split: left half light, right half dark
            HStack(spacing: 0) {
                windowPreview(isDark: false)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 8, bottomLeadingRadius: 8,
                        bottomTrailingRadius: 0, topTrailingRadius: 0))
                windowPreview(isDark: true)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 0,
                        bottomTrailingRadius: 8, topTrailingRadius: 8))
            }
            .frame(width: 72, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            windowPreview(isDark: mode == .dark)
                .frame(width: 72, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func windowPreview(isDark: Bool) -> some View {
        VStack(spacing: 0) {
            // Title bar with traffic lights
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.9)).frame(width: 6, height: 6)
                Circle().fill(Color.yellow.opacity(0.9)).frame(width: 6, height: 6)
                Circle().fill(Color.green.opacity(0.9)).frame(width: 6, height: 6)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(isDark ? Color(white: 0.22) : Color(white: 0.92))

            // Sidebar + content
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.08))
                            .frame(height: 4)
                    }
                    Spacer()
                }
                .padding(4).frame(width: 22)
                .background(isDark ? Color(white: 0.18) : Color(white: 0.95))

                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                        .frame(height: 4)
                    Spacer()
                }
                .padding(6).frame(maxWidth: .infinity)
                .background(isDark ? Color(white: 0.14) : Color.white)
            }
        }
        .background(isDark ? Color(white: 0.14) : Color.white)
    }
}

// MARK: - SettingsStylePicker
//
// Visual thumbnail picker for settings window layout — Toolbar (icons at top) vs Sidebar.

struct SettingsStylePicker: View {
    @Binding var selection: SettingsStyle

    var body: some View {
        HStack(spacing: 14) {
            ForEach(SettingsStyle.allCases, id: \.self) { style in
                SettingsStyleThumbnailView(style: style, isSelected: selection == style) {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = style }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsStyleThumbnailView: View {
    let style: SettingsStyle
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    /// Localized display name as a key — resolved via environment locale injected by managedLocale().
    private var styleTitleKey: LocalizedStringKey {
        switch style {
        case .toolbar: return "Toolbar"
        case .sidebar: return "Sidebar"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                styleThumbnail
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)

                Text(styleTitleKey)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var styleThumbnail: some View {
        switch style {
        case .toolbar: toolbarPreview
        case .sidebar: sidebarPreview
        }
    }

    // Toolbar style: row of icon tiles below the titlebar (like macOS Preferences)
    private var toolbarPreview: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.9)).frame(width: 5, height: 5)
                Circle().fill(Color.yellow.opacity(0.9)).frame(width: 5, height: 5)
                Circle().fill(Color.green.opacity(0.9)).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(isDark ? Color(white: 0.22) : Color(white: 0.92))

            // Toolbar row — 3 icon tiles centred
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == 0
                                  ? Color.accentColor.opacity(0.75)
                                  : (isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.12)))
                            .frame(width: 10, height: 10)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.09))
                            .frame(width: 14, height: 3)
                    }
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(isDark ? Color(white: 0.20) : Color(white: 0.96))

            // Content area
            Rectangle()
                .fill(isDark ? Color(white: 0.14) : Color.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 72, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // Sidebar style: left nav panel + main content
    private var sidebarPreview: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 4) {
                Circle().fill(Color.red.opacity(0.9)).frame(width: 5, height: 5)
                Circle().fill(Color.yellow.opacity(0.9)).frame(width: 5, height: 5)
                Circle().fill(Color.green.opacity(0.9)).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
            .background(isDark ? Color(white: 0.22) : Color(white: 0.92))

            // Sidebar + content
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        HStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(i == 0 ? Color.accentColor.opacity(0.75) : (isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.08)))
                                .frame(width: 6, height: 6)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i == 0 ? Color.accentColor.opacity(0.5) : (isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.08)))
                                .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                        }
                    }
                    Spacer()
                }
                .padding(5).frame(width: 26)
                .background(isDark ? Color(white: 0.18) : Color(white: 0.95))

                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06))
                        .frame(height: 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                        .frame(height: 4)
                    Spacer()
                }
                .padding(6).frame(maxWidth: .infinity)
                .background(isDark ? Color(white: 0.14) : Color.white)
            }
        }
        .frame(width: 72, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - CaptureModePicker
//
// Icon tile picker for capture mode — CaptureMode already carries .icon and .title.

struct CaptureModePicker: View {
    @Binding var selection: CaptureMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                CaptureModeTile(mode: mode, isSelected: selection == mode) {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = mode }
                }
            }
        }
    }
}

private struct CaptureModeTile: View {
    let mode: CaptureMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: mode.icon)
                    .font(.system(size: 18))
                Text(mode.title)
                    .font(.system(size: 10))
            }
            .frame(width: 68, height: 50)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07))
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("AppearanceModePicker") {
    VStack(spacing: 20) {
        AppearanceModePicker(selection: .constant(.system))
        AppearanceModePicker(selection: .constant(.light))
        AppearanceModePicker(selection: .constant(.dark))
    }
    .padding()
    .frame(width: 400)
}

#Preview("SettingsStylePicker") {
    VStack(spacing: 20) {
        SettingsStylePicker(selection: .constant(.toolbar))
        SettingsStylePicker(selection: .constant(.sidebar))
    }
    .padding()
    .frame(width: 300)
}

#Preview("CaptureModePicker") {
    VStack(spacing: 20) {
        CaptureModePicker(selection: .constant(.selection))
        CaptureModePicker(selection: .constant(.window))
    }
    .padding()
    .frame(width: 350)
}
