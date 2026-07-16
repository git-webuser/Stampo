import Foundation
import Carbon.HIToolbox

/// The global, user-rebindable hotkey actions. The raw value is the Carbon
/// `EventHotKeyID.id` used when registering and dispatching.
enum HotkeyAction: UInt32, CaseIterable {
    case togglePanel = 1
    case selection   = 2
    case fullscreen  = 3
    case window      = 4
    case color       = 5
    case ocr         = 6
    case scanCode    = 7
    case pinLastCapture = 8

    /// Localization key for the row label.
    var labelKey: String {
        switch self {
        case .togglePanel: return "Toggle Panel"
        case .selection:   return "Selection Screenshot"
        case .fullscreen:  return "Fullscreen Screenshot"
        case .window:      return "Window Screenshot"
        case .color:       return "Pick Color"
        case .ocr:         return "Capture Text"
        case .scanCode:    return "Scan Code"
        case .pinLastCapture: return "Pin Last Screenshot"
        }
    }

    /// Outline SF Symbol, matching the Capture-mode / settings glyph language.
    var icon: String {
        switch self {
        case .togglePanel: return "rectangle.topthird.inset"
        case .selection:   return "rectangle.dashed"
        case .fullscreen:  return "menubar.dock.rectangle"
        case .window:      return "macwindow"
        case .color:       return "eyedropper"
        case .ocr:         return "text.viewfinder"
        case .scanCode:    return "qrcode.viewfinder"
        case .pinLastCapture: return "pin"
        }
    }

    /// Factory default combo (the historical hardcoded `⌃⌥⌘ + key`).
    var defaultCombo: HotkeyCombo {
        let mods = UInt32(controlKey | optionKey | cmdKey)
        let key: Int
        switch self {
        case .togglePanel: key = kVK_ANSI_N
        case .selection:   key = kVK_ANSI_R
        case .fullscreen:  key = kVK_ANSI_B
        case .window:      key = kVK_ANSI_G
        case .color:       key = kVK_ANSI_C
        case .ocr:         key = kVK_ANSI_T
        case .scanCode:    key = kVK_ANSI_S
        case .pinLastCapture: key = kVK_ANSI_P
        }
        return HotkeyCombo(keyCode: UInt16(key), carbonModifiers: mods)
    }

    private var storageKey: String { "hotkey.combo.\(rawValue)" }

    /// Legacy enable/disable key used before combos were customizable.
    /// Actions added after the combo migration have no legacy key;
    /// `migrateIfNeeded` reads nil and treats them as enabled.
    private var legacyEnabledKey: String {
        switch self {
        case .togglePanel: return "hotkeyPanelEnabled"
        case .selection:   return "hotkeySelectionEnabled"
        case .fullscreen:  return "hotkeyFullscreenEnabled"
        case .window:      return "hotkeyWindowEnabled"
        case .color:       return "hotkeyColorEnabled"
        case .ocr:         return "hotkeyOcrEnabled"
        case .scanCode:    return "hotkeyScanCodeEnabled"
        case .pinLastCapture: return "hotkeyPinLastCaptureEnabled"
        }
    }

    /// Box so an explicitly-disabled action (nil combo) is distinguishable from
    /// "never stored" once the key exists in UserDefaults.
    private struct Stored: Codable { let combo: HotkeyCombo? }

    /// Current combo, or nil when the user cleared it (disabled). Falls back to
    /// the default if nothing is stored yet (pre-migration safety).
    var combo: HotkeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return defaultCombo }
        return stored.combo
    }

    /// Persist a new combo (nil = disabled).
    func setCombo(_ combo: HotkeyCombo?) {
        if let data = try? JSONEncoder().encode(Stored(combo: combo)) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Migration

    private static let migratedKey = "hotkeysMigratedToCombos"

    /// One-time migration: seed each action's combo from its hardcoded default,
    /// honoring the old enable/disable bool (a previously-disabled action stays
    /// disabled). Safe to call on every launch.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        for action in allCases {
            let wasEnabled = defaults.object(forKey: action.legacyEnabledKey) as? Bool ?? true
            action.setCombo(wasEnabled ? action.defaultCombo : nil)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
