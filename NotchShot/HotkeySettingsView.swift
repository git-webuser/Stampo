import SwiftUI

struct HotkeySettingsView: View {
    @AppStorage(AppSettings.Keys.hotkeyPanelEnabled)      private var panelEnabled      = true
    @AppStorage(AppSettings.Keys.hotkeySelectionEnabled)  private var selectionEnabled  = true
    @AppStorage(AppSettings.Keys.hotkeyFullscreenEnabled) private var fullscreenEnabled = true
    @AppStorage(AppSettings.Keys.hotkeyWindowEnabled)     private var windowEnabled     = true
    @AppStorage(AppSettings.Keys.hotkeyColorEnabled)      private var colorEnabled      = true

    var body: some View {
        Form {
            Section {
                HotkeyRow(action: "Toggle Panel",         combo: "⌃⌥⌘N", isEnabled: $panelEnabled)
                HotkeyRow(action: "Selection Screenshot", combo: "⌃⌥⌘R", isEnabled: $selectionEnabled)
                HotkeyRow(action: "Fullscreen Screenshot",combo: "⌃⌥⌘G", isEnabled: $fullscreenEnabled)
                HotkeyRow(action: "Window Screenshot",    combo: "⌃⌥⌘B", isEnabled: $windowEnabled)
                HotkeyRow(action: "Pick Color",           combo: "⌃⌥⌘C", isEnabled: $colorEnabled)
            } footer: {
                Text("Custom key combinations will be available in a future update.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - HotkeyRow

private struct HotkeyRow: View {
    let action: String
    let combo: String
    @Binding var isEnabled: Bool

    var body: some View {
        LabeledContent(action) {
            HStack(spacing: 12) {
                Text(combo)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor))
                            )
                    )
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}
