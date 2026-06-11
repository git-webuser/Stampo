import SwiftUI

// MARK: - SettingsTab

enum SettingsTab: Int, CaseIterable, Identifiable, Hashable {
    case general, capture, tray, hotkeys, about

    var id: Int { rawValue }

    var labelKey: String {
        switch self {
        case .general:  return "General"
        case .capture:  return "Capture"
        case .tray:     return "Tray"
        case .hotkeys:  return "Hotkeys"
        case .about:    return "About"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape.fill"
        case .capture:  return "camera.fill"
        case .tray:     return "tray.fill"
        case .hotkeys:  return "keyboard.fill"
        case .about:    return "info.circle.fill"
        }
    }

    /// Outline variant for the toolbar (.preference) style window.
    var toolbarIcon: String {
        switch self {
        case .general:  return "gearshape"
        case .capture:  return "camera"
        case .tray:     return "tray"
        case .hotkeys:  return "keyboard"
        case .about:    return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .general:  return Color(nsColor: .systemGray)
        case .capture:  return .blue
        case .tray:     return .green
        case .hotkeys:  return .orange
        case .about:    return .indigo
        }
    }

    @ViewBuilder var contentView: some View {
        switch self {
        case .general:  GeneralSettingsView()
        case .capture:  CaptureSettingsView()
        case .tray:     TraySettingsView()
        case .hotkeys:  HotkeySettingsView()
        case .about:    AboutSettingsView()
        }
    }
}

// MARK: - SettingsNavigation

/// Shared selection state so deep-links (errors, menu items) can route to a
/// specific tab regardless of which settings layout style is active.
@Observable final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general
    private init() {}
}

// MARK: - SidebarSettingsView

struct SidebarSettingsView: View {
    @Bindable private var navigation = SettingsNavigation.shared
    private var selectedTab: SettingsTab? { navigation.selectedTab }
    // Keep sidebar always visible — this is a settings window, not a navigation stack.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Use id: \.self so the List matches selections by enum value directly.
            // Do NOT use .tag() here — that is for Picker, not List.
            List(SettingsTab.allCases, id: \.self, selection: $navigation.selectedTab) { tab in
                HStack(spacing: 12) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(tab.color)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(LocalizedStringKey(tab.labelKey))
                        .font(.body)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            (selectedTab ?? .general).contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
