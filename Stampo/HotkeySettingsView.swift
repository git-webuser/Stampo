import SwiftUI

// MARK: - HotkeySettingsView

struct HotkeySettingsView: View {
    @AppStorage(AppSettings.Keys.hotkeyPanelEnabled)      private var panelEnabled      = true
    @AppStorage(AppSettings.Keys.hotkeySelectionEnabled)  private var selectionEnabled  = true
    @AppStorage(AppSettings.Keys.hotkeyFullscreenEnabled) private var fullscreenEnabled = true
    @AppStorage(AppSettings.Keys.hotkeyWindowEnabled)     private var windowEnabled     = true
    @AppStorage(AppSettings.Keys.hotkeyColorEnabled)      private var colorEnabled      = true
    @AppStorage(AppSettings.Keys.hotkeyHUDFormatEnabled)  private var hudFormatEnabled  = true

    var body: some View {
        Form {
            Section {
                HotkeyRow(action: "Toggle Panel",          combo: "⌃⌥⌘N", isEnabled: $panelEnabled)
                HotkeyRow(action: "Selection Screenshot",  combo: "⌃⌥⌘R", isEnabled: $selectionEnabled)
                HotkeyRow(action: "Fullscreen Screenshot", combo: "⌃⌥⌘B", isEnabled: $fullscreenEnabled)
                HotkeyRow(action: "Window Screenshot",     combo: "⌃⌥⌘G", isEnabled: $windowEnabled)
                HotkeyRow(action: "Pick Color",            combo: "⌃⌥⌘C", isEnabled: $colorEnabled)
            }
            Section("Color HUD") {
                HotkeyRow(action: "Cycle Color Format",    combo: "F",     isEnabled: $hudFormatEnabled)
            }
            Section {
                HotkeyArrowRow(action: "Move 1 pt",  modifiers: [])
                HotkeyArrowRow(action: "Move 10 pt", modifiers: ["⇧"])
                HotkeyArrowRow(action: "Move 50 pt", modifiers: ["⇧", "⌥"])
            } header: {
                Text("Color Picker Movement")
            } footer: {
                Text("Arrow keys nudge the cursor while the color picker is active.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout constants

/// arrowSize * 2 + arrowGap == capHeight so modifier keys and the arrow cluster align.
private enum KC {
    static let capHeight:  CGFloat = 36
    static let arrowSize:  CGFloat = 17   // (17 + 2 + 17 = 36)
    static let arrowGap:   CGFloat = 2
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

    private var regularCap: some View {
        Text(key)
            .font(.system(size: 13, weight: .regular))
            .frame(minWidth: 26, maxWidth: 34, minHeight: KC.capHeight)
            .padding(.horizontal, 7)
            .keyCap()
    }

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
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        // maxWidth caps growth when placed inside a flexible LabeledContent trailing slot
        .frame(minWidth: 44, maxWidth: 48, minHeight: KC.capHeight)
        .keyCap()
    }
}

// MARK: - KeyComboView

/// Splits a combo string (e.g. "⌃⌥⌘N") into individual KeyCapViews.
public struct KeyComboView: View {
    public let combo: String
    public var dimmed: Bool = false

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.map(String.init).enumerated()), id: \.offset) { _, key in
                KeyCapView(key: key, dimmed: dimmed)
            }
        }
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

// MARK: - HotkeyArrowRow

/// Movement row: modifier key caps (shown once) + T-shaped arrow cluster.
/// Spacer() prevents LabeledContent from stretching the HStack to fill available width.
private struct HotkeyArrowRow: View {
    let action: String
    let modifiers: [String]

    var body: some View {
        LabeledContent(LocalizedStringKey(action)) {
            HStack(alignment: .center, spacing: 6) {
                ForEach(modifiers, id: \.self) { mod in
                    KeyCapView(key: mod)
                }
                ArrowClusterView()
            }
            .fixedSize()
        }
    }
}

// MARK: - HotkeyRow

private struct HotkeyRow: View {
    let action: String
    let combo: String
    @Binding var isEnabled: Bool

    var body: some View {
        LabeledContent(LocalizedStringKey(action)) {
            HStack(spacing: 12) {
                KeyComboView(combo: combo, dimmed: !isEnabled)
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}
