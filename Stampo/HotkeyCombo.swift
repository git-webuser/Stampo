import AppKit
import Carbon.HIToolbox

/// A global hotkey combination: a virtual key code plus a Carbon modifier mask
/// (the form `RegisterEventHotKey` consumes directly). Display glyphs are derived
/// from the same values, so the model is the single source of truth.
struct HotkeyCombo: Codable, Equatable, Hashable {
    /// Virtual key code (kVK_*), e.g. `kVK_ANSI_N`.
    let keyCode: UInt16
    /// Carbon modifier mask: `cmdKey | optionKey | controlKey | shiftKey`.
    let carbonModifiers: UInt32

    init(keyCode: UInt16, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Build from a captured AppKit key event.
    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.carbonModifiers = Self.carbonMask(from: modifierFlags)
    }

    // MARK: Modifier conversion

    static func carbonMask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }

    var hasCommand: Bool { carbonModifiers & UInt32(cmdKey)     != 0 }
    var hasOption:  Bool { carbonModifiers & UInt32(optionKey)  != 0 }
    var hasControl: Bool { carbonModifiers & UInt32(controlKey) != 0 }
    var hasShift:   Bool { carbonModifiers & UInt32(shiftKey)   != 0 }

    /// At least one of ⌘/⌃/⌥ — the "strong" modifiers that prevent the combo
    /// from hijacking ordinary typing. Bare ⇧ does not count.
    var hasStrongModifier: Bool { hasCommand || hasOption || hasControl }

    // MARK: Display

    /// Modifier glyphs in Apple's canonical order, then the key label.
    /// e.g. `["⌃", "⌥", "⌘", "N"]` — each is one cap in the recorder.
    var displayCaps: [String] {
        var caps: [String] = []
        if hasControl { caps.append("⌃") }
        if hasOption  { caps.append("⌥") }
        if hasShift   { caps.append("⇧") }
        if hasCommand { caps.append("⌘") }
        caps.append(Self.keyLabel(for: keyCode))
        return caps
    }

    /// Single-string form for compact display (e.g. menus): `⌃⌥⌘N`.
    var displayString: String { displayCaps.joined() }

    /// Human-readable label for a virtual key code.
    static func keyLabel(for code: UInt16) -> String {
        if let named = namedKeys[code] { return named }
        return "?"
    }

    /// Virtual-key-code → display label for keys a user can bind.
    private static let namedKeys: [UInt16: String] = {
        var m: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
            UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
            UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
            UInt16(kVK_ANSI_9): "9",
            UInt16(kVK_ANSI_Minus): "-", UInt16(kVK_ANSI_Equal): "=",
            UInt16(kVK_ANSI_LeftBracket): "[", UInt16(kVK_ANSI_RightBracket): "]",
            UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Semicolon): ";",
            UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
            UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/",
            UInt16(kVK_ANSI_Grave): "`",
            UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "␣",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
            UInt16(kVK_Escape): "⎋", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
            UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        ]
        let fkeys: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fkeys.enumerated() { m[UInt16(code)] = "F\(i + 1)" }
        return m
    }()
}
