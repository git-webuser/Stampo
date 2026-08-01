import Foundation
import Carbon.HIToolbox

/// Settings sections for the global shortcuts, in display order.
enum HotkeyGroup: CaseIterable {
    case panel
    case capture
    case tools

    /// Localization key for the section header.
    var titleKey: String {
        switch self {
        case .panel:   return "Panel and Archive"
        // Not "Capture" — that key is the panel's shutter button ("Снять").
        case .capture: return "Screen Capture"
        case .tools:   return "Tools"
        }
    }

    var actions: [HotkeyAction] { HotkeyAction.allCases.filter { $0.group == self } }
}

/// The global, user-rebindable hotkey actions. The raw value is the Carbon
/// `EventHotKeyID.id` used when registering and dispatching.
enum HotkeyAction: UInt32, CaseIterable {
    case togglePanel = 1
    case selection   = 2
    case fullscreen  = 3
    case window      = 4
    case color       = 5
    // 6 was the separate Capture Text (OCR) action, merged into `scan` —
    // see `migrateScanMergeIfNeeded`. The ID stays retired.
    case scan        = 7
    case pinLastCapture = 8
    case collectFiles = 9
    case shareLastItem = 10

    /// Settings grouping. Nine editable shortcuts in one flat list stopped
    /// being scannable; the split follows what the action does rather than
    /// when it was added — bring the panel up, take a picture, run an overlay
    /// tool. Section order below is the order of `HotkeyGroup.allCases`.
    var group: HotkeyGroup {
        switch self {
        case .togglePanel, .collectFiles, .pinLastCapture, .shareLastItem:
            return .panel
        case .selection, .fullscreen, .window:
            return .capture
        case .color, .scan:
            return .tools
        }
    }

    /// Extra modifier the action honors, described for the settings row. Only
    /// behaviour the user cannot discover from the shortcut itself belongs
    /// here — nil for actions that do exactly one thing.
    var modifierHintKey: String? {
        switch self {
        case .scan:
            return "Hold ⌥ when releasing the selection to keep line breaks"
        default:
            return nil
        }
    }

    /// Localization key for the row label.
    var labelKey: String {
        switch self {
        case .togglePanel: return "Toggle Panel"
        case .selection:   return "Selection Screenshot"
        case .fullscreen:  return "Fullscreen Screenshot"
        case .window:      return "Window Screenshot"
        case .color:       return "Pick Color"
        case .scan:        return "Scan"
        case .pinLastCapture: return "Pin Last Screenshot"
        case .collectFiles: return "Collect Files"
        case .shareLastItem: return "Share Last Item"
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
        case .scan:        return "doc.viewfinder"
        case .pinLastCapture: return "pin"
        case .collectFiles: return "arrow.down.document"
        case .shareLastItem: return "square.and.arrow.up"
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
        case .scan:        key = kVK_ANSI_S
        case .pinLastCapture: key = kVK_ANSI_P
        case .collectFiles: key = kVK_ANSI_T
        // S (Scan) and P (Pin) are taken; D is free and unreserved by macOS
        // under ⌃⌥⌘.
        case .shareLastItem: key = kVK_ANSI_D
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
        case .scan:        return "hotkeyScanCodeEnabled"
        case .pinLastCapture: return "hotkeyPinLastCaptureEnabled"
        // Added after the combo migration — no legacy key was ever written;
        // migrateIfNeeded reads nil and treats the action as enabled.
        case .collectFiles: return "hotkeyCollectFilesEnabled"
        // Storage key predates the rename from "Share Last Screenshot"; only
        // pre-migration installs ever read it, so it stays as written.
        case .shareLastItem: return "hotkeyShareLastCaptureEnabled"
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

    private static let scanMergeKey = "hotkeysMergedScanHotkey"
    /// Storage key of the retired Capture Text action (raw value 6).
    private static let retiredOcrComboKey = "hotkey.combo.6"

    /// One-time merge of the former Capture Text (6) and Scan Code (7) hotkeys
    /// into the single Scan action. A combo the user customized survives:
    /// Scan Code's wins outright, Capture Text's is adopted when Scan Code was
    /// still at its factory state. With both at factory state the unified
    /// default applies, enabled unless both actions were disabled. Runs after
    /// `migrateIfNeeded`; the retired storage is removed either way.
    /// `defaults` is injectable for tests only.
    static func migrateScanMergeIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: scanMergeKey) else { return }
        defaults.set(true, forKey: scanMergeKey)

        func decode(_ key: String) -> Stored? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }
        func storeScan(_ combo: HotkeyCombo?) {
            if let data = try? JSONEncoder().encode(Stored(combo: combo)) {
                defaults.set(data, forKey: HotkeyAction.scan.storageKey)
            }
        }

        let scanStored = decode(HotkeyAction.scan.storageKey)
        let ocrStored = decode(retiredOcrComboKey)
        defaults.removeObject(forKey: retiredOcrComboKey)

        guard let ocrStored else {
            // Pre-combo installs never stored the OCR combo; honor the legacy
            // enable bool so an OCR-only user still gets a working Scan hotkey.
            if defaults.object(forKey: "hotkeyOcrEnabled") as? Bool == true,
               let scanStored, scanStored.combo == nil {
                storeScan(HotkeyAction.scan.defaultCombo)
            }
            return
        }

        // Nothing stored for Scan Code means its factory default was in
        // effect; a stored nil combo means the user disabled the action.
        let scanCombo: HotkeyCombo?
        if let scanStored {
            scanCombo = scanStored.combo
        } else {
            scanCombo = HotkeyAction.scan.defaultCombo
        }
        let retiredOcrDefault = HotkeyCombo(
            keyCode: UInt16(kVK_ANSI_T),
            carbonModifiers: UInt32(controlKey | optionKey | cmdKey)
        )

        if let scanCombo, scanCombo != HotkeyAction.scan.defaultCombo {
            return // user's Scan Code bind wins
        }
        if let ocrCombo = ocrStored.combo, ocrCombo != retiredOcrDefault {
            storeScan(ocrCombo) // user's Capture Text bind survives
            return
        }
        if scanCombo == nil && ocrStored.combo != nil {
            storeScan(HotkeyAction.scan.defaultCombo)
        }
    }
}
