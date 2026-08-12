import SwiftUI

// MARK: - HotkeySettingsView

struct HotkeySettingsView: View {
    @AppStorage(AppSettings.Keys.hotkeyHUDFormatEnabled)  private var hudFormatEnabled = true
    @AppStorage(AppSettings.Keys.hotkeyArrowMove1Enabled)  private var move1Enabled  = true
    @AppStorage(AppSettings.Keys.hotkeyArrowMove10Enabled) private var move10Enabled = true
    @AppStorage(AppSettings.Keys.hotkeyArrowMove50Enabled) private var move50Enabled = true

    /// Live mirror of each action's stored combo, so recorder edits redraw the row.
    @State private var combos: [HotkeyAction: HotkeyCombo?] = HotkeyAction.allCases
        .reduce(into: [:]) { $0[$1] = $1.combo }

    var body: some View {
        Form {
            // MARK: Global shortcuts (editable), one section per group.
            ForEach(HotkeyGroup.allCases, id: \.self) { group in
                Section(LocalizedStringKey(group.titleKey)) {
                    ForEach(group.actions, id: \.self) { action in
                        EditableHotkeyRow(action: action, combo: combos[action] ?? nil) { newCombo in
                            action.setCombo(newCombo)    // persists → controller reinstalls
                            combos[action] = newCombo
                        }
                    }
                }
            }

            // MARK: Reset
            // A section of its own, because Reset covers all three groups above
            // and nothing below. It used to hang in the last group's footer,
            // from when the shortcuts were a single list — once they were split
            // into groups, that put it under "Tools" and made it look like it
            // reset the tools.
            Section {
                SettingRow(
                    icon: "arrow.uturn.backward",
                    title: "Reset shortcuts",
                    // "Every shortcut" without spelling out which: the ones
                    // above are the editable ones, which is the whole reason
                    // the element controls sit apart from them.
                    description: "Restores every shortcut to its default"
                ) {
                    Button("Reset") { restoreDefaults() }
                        .buttonStyle(.bordered)
                }
            }

            // MARK: Color picker (fixed, toggleable)
            Section("Element Controls") {
                // One row because it is one idea — step to the next one —
                // wherever the app offers a list of them. Naming the surfaces
                // rather than the settings key: the key still says
                // "hotkeyHUDFormat" from when the picker was the only place
                // this worked, and renaming it would reset the switch for
                // everyone who has turned it off.
                FixedHotkeyRow(icon: "arrow.2.squarepath",
                               action: "Cycle Color or Language",
                               description: "In the color picker, the archive, the translator and the scanner. ⇧⇥ steps back",
                               caps: ["⇥"],
                               alternative: ["F"],
                               isEnabled: $hudFormatEnabled)
                ArrowStepRow(icon: "1.circle",  title: "Move 1 pt",  modifiers: [],         isEnabled: $move1Enabled)
                ArrowStepRow(icon: "10.circle", title: "Move 10 pt", modifiers: ["⇧"],      isEnabled: $move10Enabled)
                ArrowStepRow(icon: "50.circle", title: "Move 50 pt", modifiers: ["⇧", "⌥"], isEnabled: $move50Enabled)
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
        SettingRow(
            icon: action.icon,
            title: LocalizedStringKey(action.labelKey),
            // Second line for actions with something the shortcut does not
            // say — otherwise it lives only in the release notes.
            description: action.hintKey.map { LocalizedStringKey($0) }
        ) {
            ShortcutRecorderView(action: action, combo: combo, onChange: onChange)
        }
    }
}

// MARK: - FixedHotkeyRow

/// Non-editable local shortcut: fixed key caps + enable toggle.
private struct FixedHotkeyRow: View {
    let icon: String
    let action: String
    /// Second line for what the keys alone do not say — here, the four places
    /// this works and the one modifier that reverses it.
    var description: String? = nil
    let caps: [String]
    /// A second key that does the same thing. Kept apart from `caps` because
    /// caps sit shoulder to shoulder and read as one chord — "F ⇥" that way
    /// would say press both, which is the opposite of what these two are.
    var alternative: [String] = []
    @Binding var isEnabled: Bool

    var body: some View {
        SettingRow(icon: icon,
                   title: LocalizedStringKey(action),
                   description: description.map { LocalizedStringKey($0) }) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(caps, id: \.self) { KeyCapView(key: $0, dimmed: !isEnabled) }
                    if !alternative.isEmpty {
                        // The one thing between them that says "either", and
                        // narrow enough not to look like a key itself.
                        Text(verbatim: "/")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                            .opacity(isEnabled ? 1 : 0.4)
                        ForEach(alternative, id: \.self) { KeyCapView(key: $0, dimmed: !isEnabled) }
                    }
                }
                Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

// MARK: - ArrowStepRow

/// One arrow-movement step: icon + label + modifier caps + arrow cluster, each
/// with its own enable toggle (caps/cluster dim when off).
private struct ArrowStepRow: View {
    let icon: String
    let title: String
    let modifiers: [String]
    @Binding var isEnabled: Bool

    var body: some View {
        SettingRow(icon: icon, title: LocalizedStringKey(title)) {
            HStack(spacing: 8) {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(modifiers, id: \.self) { KeyCapView(key: $0, dimmed: !isEnabled) }
                    ArrowClusterView().opacity(isEnabled ? 1 : 0.4)
                }
                Toggle("", isOn: $isEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}
