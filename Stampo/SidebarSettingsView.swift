import SwiftUI

// MARK: - SettingsTab

enum SettingsTab: Int, CaseIterable, Identifiable, Hashable {
    case general, capture, archive, hotkeys, about

    var id: Int { rawValue }

    var labelKey: String {
        switch self {
        case .general:  return "General"
        // Distinct from the panel's "Capture" button key: both read "Capture"
        // in English, but Russian names the pane (Съёмка) and the action
        // (Снять) differently, and one catalog key can't carry two values.
        case .capture:  return "Capture Settings"
        case .archive:  return "Archive"
        case .hotkeys:  return "Hotkeys"
        case .about:    return "About"
        }
    }

    /// SF Symbol for the toolbar (.preference) style window.
    var toolbarIcon: String {
        switch self {
        case .general:  return "gearshape"
        case .capture:  return "camera"
        case .archive:  return "archivebox"
        case .hotkeys:  return "keyboard"
        case .about:    return "info.circle"
        }
    }

    /// Colorful sidebar icon asset (Icon Composer export, System Settings style).
    var sidebarImage: String {
        switch self {
        case .general:  return "tab-general"
        case .capture:  return "tab-capture"
        case .archive:  return "tab-archive"
        case .hotkeys:  return "tab-hotkeys"
        case .about:    return "tab-about"
        }
    }

    @ViewBuilder var contentView: some View {
        switch self {
        case .general:  GeneralSettingsView()
        case .capture:  CaptureSettingsView()
        case .archive:  ArchiveSettingsView()
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

    /// Plain columns rather than a NavigationSplitView.
    ///
    /// The split view's column minimum is not a floor: drag the divider past
    /// it and the sidebar collapses outright. That is fine in a document
    /// window, which keeps a toolbar button to bring the sidebar back — this
    /// window has none, its toolbar belonging to the tabbed style, so the
    /// sidebar took the only way to change tabs with it. Watching
    /// `columnVisibility` did not help: a drag never changes it, and the
    /// divider ignores being repositioned in code, so there was no way to
    /// undo the collapse or even to reproduce it in a test.
    ///
    /// Without a divider there is nothing to drag and nothing to collapse.
    /// The cost is that the sidebar no longer resizes — five fixed rows that
    /// never needed to.
    private static let sidebarWidth: CGFloat = 210

    var body: some View {
        HStack(spacing: 0) {
            // Use id: \.self so the List matches selections by enum value directly.
            // Do NOT use .tag() here — that is for Picker, not List.
            List(SettingsTab.allCases, id: \.self, selection: $navigation.selectedTab) { tab in
                HStack(spacing: 12) {
                    Image(tab.sidebarImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                    Text(LocalizedStringKey(tab.labelKey))
                        .font(.body)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.sidebar)
            .frame(width: Self.sidebarWidth)

            Divider()

            (selectedTab ?? .general).contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
