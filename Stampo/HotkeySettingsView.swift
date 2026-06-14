import SwiftUI

// MARK: - HotkeySettingsView

struct HotkeySettingsView: View {
    @AppStorage(AppSettings.Keys.hotkeyHUDFormatEnabled) private var hudFormatEnabled = true
    @AppStorage(AppSettings.Keys.hotkeyArrowMoveEnabled) private var arrowMoveEnabled = true

    /// Live mirror of each action's stored combo, so recorder edits redraw the row.
    @State private var combos: [HotkeyAction: HotkeyCombo?] = HotkeyAction.allCases
        .reduce(into: [:]) { $0[$1] = $1.combo }

    var body: some View {
        Form {
            // MARK: Global shortcuts (editable)
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    EditableHotkeyRow(action: action, combo: combos[action] ?? nil) { newCombo in
                        action.setCombo(newCombo)        // persists → controller reinstalls
                        combos[action] = newCombo
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                HStack {
                    Spacer()
                    Button("Reset") { restoreDefaults() }
                        .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }

            // MARK: Color picker (fixed, toggleable)
            Section {
                FixedHotkeyRow(icon: "arrow.2.squarepath",
                               action: "Cycle Color Format",
                               caps: ["F"],
                               isEnabled: $hudFormatEnabled)
                FixedArrowRow(isEnabled: $arrowMoveEnabled)
            } header: {
                Text("Color Picker")
            } footer: {
                Text("These shortcuts work only while the color picker is active and can't be changed")
            }
        }
        .formStyle(.grouped)
    }

    private func restoreDefaults() {
        for action in HotkeyAction.allCases {
            action.setCombo(action.defaultCombo)
            combos[action] = action.defaultCombo
        }
    }
}

// MARK: - Layout constants

/// arrowSize * 2 + arrowGap == capHeight so modifier keys and the arrow cluster align.
private enum KC {
    static let capHeight:    CGFloat = 32          // every cap is exactly this tall
    static let modifierWidth: CGFloat = 44         // rectangular modifier caps
    static let arrowSize:    CGFloat = 15           // (15 + 2 + 15 = 32)
    static let arrowGap:     CGFloat = 2
}

// MARK: - Key cap background

private extension View {
    func keyCap() -> some View {
        background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
        )
    }
}

// MARK: - KeyCapView

/// Single keyboard key cap.
/// Modifier keys (⌃ ⇧ ⌥ ⌘) show a small symbol at top-left and an abbreviated label at bottom-right,
/// matching the engraving style of a physical Mac keyboard.
/// All other keys show the character centred.
public struct KeyCapView: View {
    public let key: String
    public var dimmed: Bool = false

    // symbol → (top-left glyph, bottom-right label)
    private static let modifiers: [Character: (String, String)] = [
        "⌃": ("⌃", "ctrl"),
        "⇧": ("⇧", "shift"),
        "⌥": ("⌥", "opt"),
        "⌘": ("⌘", "cmd"),
    ]

    public var body: some View {
        Group {
            if let ch = key.first, let (sym, lbl) = Self.modifiers[ch], key.count == 1 {
                modifierCap(symbol: sym, label: lbl)
            } else {
                regularCap
            }
        }
        .opacity(dimmed ? 0.4 : 1)
    }

    /// Single key — square (widens only for multi-char labels like F12).
    private var regularCap: some View {
        Text(key)
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 4)
            .frame(minWidth: KC.capHeight, minHeight: KC.capHeight, maxHeight: KC.capHeight)
            .keyCap()
    }

    /// Modifier — rectangular, engraved glyph top-left + label bottom-right.
    private func modifierCap(symbol: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(symbol)
                .font(.system(size: 11, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text(label)
                .font(.system(size: 9, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(width: KC.modifierWidth, height: KC.capHeight)
        .keyCap()
    }
}

// MARK: - ArrowClusterView

/// T-shaped arrow cluster that mirrors the physical layout: ↑ centred above ←↓→.
/// Total height == KC.capHeight so it aligns with adjacent modifier key caps.
private struct ArrowClusterView: View {
    var body: some View {
        VStack(spacing: KC.arrowGap) {
            HStack(spacing: KC.arrowGap) {
                // transparent placeholders keep ↑ centred over ↓
                Color.clear.frame(width: KC.arrowSize, height: KC.arrowSize)
                arrowTile("arrowtriangle.up.fill")
                Color.clear.frame(width: KC.arrowSize, height: KC.arrowSize)
            }
            HStack(spacing: KC.arrowGap) {
                arrowTile("arrowtriangle.left.fill")
                arrowTile("arrowtriangle.down.fill")
                arrowTile("arrowtriangle.right.fill")
            }
        }
    }

    private func arrowTile(_ symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 7, weight: .regular))
            .frame(width: KC.arrowSize, height: KC.arrowSize)
            .keyCap()
    }
}

// MARK: - EditableHotkeyRow

/// Global shortcut row, built on the shared SettingRow: icon + label +
/// click-to-record field (which carries its own × and inline rejection reason).
private struct EditableHotkeyRow: View {
    let action: HotkeyAction
    let combo: HotkeyCombo?
    let onChange: (HotkeyCombo?) -> Void

    var body: some View {
        SettingRow(icon: action.icon, title: LocalizedStringKey(action.labelKey)) {
            ShortcutRecorderView(action: action, combo: combo, onChange: onChange)
        }
    }
}

// MARK: - FixedHotkeyRow

/// Non-editable local shortcut: fixed key caps + enable toggle.
private struct FixedHotkeyRow: View {
    let icon: String
    let action: String
    let caps: [String]
    @Binding var isEnabled: Bool

    var body: some View {
        SettingRow(icon: icon, title: LocalizedStringKey(action)) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(caps, id: \.self) { KeyCapView(key: $0, dimmed: !isEnabled) }
                }
                Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

// MARK: - FixedArrowRow

/// Arrow-key movement row: T-cluster + enable toggle (non-editable).
private struct FixedArrowRow: View {
    @Binding var isEnabled: Bool

    var body: some View {
        SettingRow(icon: "arrow.up.and.down.and.arrow.left.and.right",
                   title: "Arrow key movement") {
            HStack(spacing: 8) {
                ArrowClusterView().opacity(isEnabled ? 1 : 0.4)
                Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}
