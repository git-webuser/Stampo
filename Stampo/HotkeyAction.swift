import Foundation
import Carbon.HIToolbox

nonisolated enum HotkeyRegistrationStatus: Equatable, Sendable {
    case registered
    case disabled
    case conflict(OSStatus)
    case handlerUnavailable

    var message: String? {
        switch self {
        case .registered: return nil
        case .disabled: return "Shortcut disabled"
        case .conflict(let status): return "Shortcut unavailable (Carbon status \(status))"
        case .handlerUnavailable: return "Shortcuts unavailable in this app session"
        }
    }

    var isError: Bool {
        switch self {
        case .conflict, .handlerUnavailable: return true
        case .registered, .disabled: return false
        }
    }
}

@MainActor
final class HotkeyRegistrationCenter {
    static let shared = HotkeyRegistrationCenter()

    private(set) var statuses: [HotkeyAction: HotkeyRegistrationStatus] = [:]

    func status(for action: HotkeyAction) -> HotkeyRegistrationStatus {
        statuses[action] ?? .disabled
    }

    func snapshot() -> [HotkeyAction: HotkeyRegistrationStatus] {
        statuses
    }

    func update(_ status: HotkeyRegistrationStatus, for action: HotkeyAction) {
        statuses[action] = status
        NotificationCenter.default.post(name: .hotkeyRegistrationChanged, object: nil)
    }

    func update(_ statuses: [HotkeyAction: HotkeyRegistrationStatus]) {
        self.statuses = statuses
        NotificationCenter.default.post(name: .hotkeyRegistrationChanged, object: nil)
    }
}

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
    case translateClipboard = 11

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
        case .color, .scan, .translateClipboard:
            return .tools
        }
    }

    /// A second line for the settings row: whatever the shortcut does that
    /// pressing it would not reveal. Modifiers it honours, or — for Translate —
    /// what it expects to already be there. Nil for actions that do exactly one
    /// thing to something already on screen.
    var hintKey: String? {
        switch self {
        case .scan:
            return "Press ⌥ to keep line breaks, ⌃ to translate"
        case .translateClipboard:
            // The one shortcut with a prerequisite. Pressed on its own it can
            // only report an empty clipboard, and a shortcut that answers "no"
            // until you know its unwritten half is a shortcut nobody keeps.
            return "Translates text copied with ⌘C"
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
        case .pinLastCapture: return "Pin Latest Capture"
        // Named for what it does, not for the flow it was added for: the
        // hotkey opens the archive pinned, which is the same state as the
        // pin button in the archive header.
        case .collectFiles: return "Pin Panel"
        case .shareLastItem: return "Share Last Item"
        case .translateClipboard: return "Translate"
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
        // Two different pins, told apart by shape rather than by a detail:
        // bare `pin` is the panel everywhere in the app (the archive header
        // button this hotkey presses), so the floating capture takes the
        // picture-over-a-surface glyph instead. At 14pt in a settings list,
        // `pin` against `pin.circle` two rows apart is no difference at all.
        case .pinLastCapture: return "inset.filled.topright.rectangle"
        case .collectFiles: return "pin"
        case .shareLastItem: return "square.and.arrow.up"
        case .translateClipboard: return "translate"
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
        // L for "latest"; P went to the panel pin, which is what the word
        // means everywhere else in the app.
        case .pinLastCapture: key = kVK_ANSI_L
        case .collectFiles: key = kVK_ANSI_P
        // S (Scan) is taken; D is free and unreserved by macOS under ⌃⌥⌘.
        case .shareLastItem: key = kVK_ANSI_D
        // T was the retired Capture Text action, so the muscle memory it
        // carries is "text" — which is what this one operates on.
        case .translateClipboard: key = kVK_ANSI_T
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
        // Added long after the combo migration; nothing ever wrote this.
        case .translateClipboard: return "hotkeyTranslateClipboardEnabled"
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

    // MARK: - Pin reshuffle

    private static let pinReshuffleKey = "hotkeysReshuffledPins"

    /// One-time move of two defaults, freeing ⌃⌥⌘T for Translate:
    ///
    ///     Pin Latest Capture   ⌃⌥⌘P → ⌃⌥⌘L
    ///     Pin Panel            ⌃⌥⌘T → ⌃⌥⌘P
    ///
    /// Users who never touched their shortcuts need nothing done: `combo`
    /// falls back to `defaultCombo`, so a changed default reaches them on its
    /// own. This exists for the ones who do have something stored — where the
    /// rule is that an explicit choice always outranks a factory one.
    ///
    /// The hazard worth the whole function is that two actions can end up on
    /// one combo. `HotkeyValidator` rejects duplicates while recording, but it
    /// never inspects what is already in storage, and Carbon simply refuses the
    /// second registration — so a collision here would silently kill one of the
    /// two shortcuts with nothing in the UI to explain it. The plan is
    /// therefore resolved in full before a single value is written, and a
    /// loser is disabled outright: an empty row in Settings is something the
    /// user can see and fix, a shadowed one is not.
    ///
    /// `defaults` is injectable for tests only.
    static func migratePinReshuffleIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: pinReshuffleKey) else { return }
        defaults.set(true, forKey: pinReshuffleKey)

        let mods = UInt32(controlKey | optionKey | cmdKey)
        func legacy(_ key: Int) -> HotkeyCombo {
            HotkeyCombo(keyCode: UInt16(key), carbonModifiers: mods)
        }
        let moves: [(action: HotkeyAction, from: HotkeyCombo)] = [
            (.pinLastCapture, legacy(kVK_ANSI_P)),
            (.collectFiles,   legacy(kVK_ANSI_T)),
        ]

        func stored(_ action: HotkeyAction) -> Stored? {
            guard let data = defaults.data(forKey: action.storageKey) else { return nil }
            return try? JSONDecoder().decode(Stored.self, from: data)
        }

        // Where every action stands before anything moves. An action with
        // nothing stored is already following the new default.
        var enabled: [HotkeyAction: HotkeyCombo] = [:]
        for action in allCases {
            if let box = stored(action) {
                if let combo = box.combo { enabled[action] = combo }
            } else {
                enabled[action] = action.defaultCombo
            }
        }

        // The moves themselves: only an action still sitting on its old
        // factory combo follows. Anything the user chose stays put.
        for move in moves where enabled[move.action] == move.from {
            guard stored(move.action) != nil else { continue }
            enabled[move.action] = move.action.defaultCombo
        }

        // Resolve collisions. Deterministic order, and an explicitly stored
        // combo beats one that is merely the factory value.
        var claimed: [HotkeyCombo: HotkeyAction] = [:]
        for action in allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let combo = enabled[action] else { continue }
            guard let holder = claimed[combo] else {
                claimed[combo] = action
                continue
            }
            let holderChosen = stored(holder)?.combo != nil
            let actionChosen = stored(action)?.combo != nil
            if actionChosen && !holderChosen {
                enabled[holder] = nil
                claimed[combo] = action
            } else {
                enabled[action] = nil
            }
        }

        // Write only what actually differs from what storage already says, so
        // actions left at their factory value keep following future defaults
        // instead of being frozen by this migration.
        for action in allCases {
            let resolved = enabled[action]
            let current: HotkeyCombo? = stored(action).map(\.combo) ?? action.defaultCombo
            guard resolved != current else { continue }
            if let data = try? JSONEncoder().encode(Stored(combo: resolved)) {
                defaults.set(data, forKey: action.storageKey)
            }
        }
    }
}
