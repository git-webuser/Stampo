import AppKit
import Carbon.HIToolbox

/// Result of checking a candidate combo. `.valid` means it can be saved;
/// every other case carries a localization key explaining the rejection.
enum HotkeyValidation: Equatable {
    case valid
    case noStrongModifier
    case systemReserved
    case duplicate(HotkeyAction)
    case registrationFailed

    /// Localized reason shown inline under the row (nil when valid).
    var reasonKey: String? {
        switch self {
        case .valid:              return nil
        case .noStrongModifier:   return "Add ⌘, ⌃ or ⌥ to the shortcut"
        case .systemReserved:     return "This shortcut is reserved by macOS"
        case .duplicate:          return "Already used by another Stampo action"
        case .registrationFailed: return "This shortcut is already in use"
        }
    }
}

enum HotkeyValidator {

    /// Validate a candidate combo for a given action.
    static func validate(_ combo: HotkeyCombo, for action: HotkeyAction) -> HotkeyValidation {
        // Re-recording the action's current combo is a no-op — always valid
        // (and would otherwise fail the probe, since we already hold it live).
        if combo == action.combo { return .valid }

        guard combo.hasStrongModifier else { return .noStrongModifier }

        if systemReserved.contains(combo) { return .systemReserved }

        for other in HotkeyAction.allCases where other != action {
            if other.combo == combo { return .duplicate(other) }
        }

        guard canRegister(combo) else { return .registrationFailed }

        return .valid
    }

    // MARK: - Probe registration

    /// Tries to register `combo`, then immediately releases it. Catches combos
    /// already claimed by other apps that use RegisterEventHotKey (Xcode, etc.).
    /// Does NOT catch OS-consumed combos — those are covered by `systemReserved`.
    private static func canRegister(_ combo: HotkeyCombo) -> Bool {
        var ref: EventHotKeyRef?
        let probeSig = (OSType("S".utf8.first!) << 24) | (OSType("T".utf8.first!) << 16)
                     | (OSType("p".utf8.first!) << 8)  |  OSType("b".utf8.first!)
        let id = EventHotKeyID(signature: probeSig, id: 0xFFFF)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.carbonModifiers,
                                         id, GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    // MARK: - System blocklist

    private static func c(_ key: Int, _ mods: Int) -> HotkeyCombo {
        HotkeyCombo(keyCode: UInt16(key), carbonModifiers: UInt32(mods))
    }

    /// macOS-reserved global shortcuts the system consumes before any app hotkey
    /// fires — registration "succeeds" but the hotkey never triggers, so these
    /// must be rejected up front. Curated from Apple's default keyboard shortcuts.
    private static let systemReserved: Set<HotkeyCombo> = {
        let cmd = cmdKey, shift = shiftKey, ctrl = controlKey, opt = optionKey
        return [
            // Spotlight / search / input
            c(kVK_Space, cmd),                 // Spotlight
            c(kVK_Space, ctrl | cmd),          // Character viewer / emoji
            c(kVK_Space, opt | cmd),           // Finder search
            c(kVK_Space, ctrl),                // Previous input source
            c(kVK_Space, ctrl | opt),          // Next input source
            // App / window switching
            c(kVK_Tab, cmd),                   // App switcher
            c(kVK_ANSI_Grave, cmd),            // Cycle windows
            c(kVK_ANSI_Q, cmd),                // Quit
            c(kVK_ANSI_W, cmd),                // Close window
            c(kVK_ANSI_H, cmd),                // Hide
            c(kVK_ANSI_M, cmd),                // Minimize
            c(kVK_ANSI_Q, ctrl | cmd),         // Lock screen
            c(kVK_Escape, opt | cmd),          // Force Quit
            // Screenshots (these are exactly Stampo's domain — protect them)
            c(kVK_ANSI_3, shift | cmd),
            c(kVK_ANSI_4, shift | cmd),
            c(kVK_ANSI_5, shift | cmd),
            c(kVK_ANSI_3, ctrl | shift | cmd),
            c(kVK_ANSI_4, ctrl | shift | cmd),
            // Mission Control / Spaces
            c(kVK_UpArrow, ctrl),              // Mission Control
            c(kVK_DownArrow, ctrl),            // App Exposé
            c(kVK_LeftArrow, ctrl),            // Move left a space
            c(kVK_RightArrow, ctrl),           // Move right a space
            c(kVK_ANSI_F, ctrl | cmd),         // Toggle full screen
        ]
    }()
}
