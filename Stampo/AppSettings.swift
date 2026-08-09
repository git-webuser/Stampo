import AppKit
import OSLog
import ServiceManagement

// MARK: - AppSettings

/// Central namespace for all user-configurable settings.
/// Non-SwiftUI code reads values via static accessors.
/// SwiftUI views use @AppStorage(AppSettings.Keys.xxx) for two-way bindings.
enum AppSettings {

    // MARK: Keys
    enum Keys {
        // General
        static let launchAtLogin         = "launchAtLogin"
        static let showThumbnailHUD      = "showThumbnailHUD"
        static let thumbnailDismissDelay = "thumbnailDismissDelay"
        // Capture
        static let saveDirectory         = "saveDirectory"
        static let saveDirectoryBookmark = "saveDirectoryBookmark"
        static let fileFormat            = "fileFormat"
        static let filenamePreset        = "filenamePreset"
        static let captureCounter        = "captureCounter"
        static let playSound             = "playSound"
        static let copyToClipboard       = "copyToClipboard"
        static let includeCursor         = "includeCursor"
        static let includeWindowShadow   = "includeWindowShadow"
        static let defaultCaptureMode    = "defaultCaptureMode"
        static let defaultTimerDelay     = "defaultTimerDelay"
        // Permissions
        /// true после того как пользователь закрыл onboarding окно при первом запуске.
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        /// true после того как пользователь ушёл выдавать Screen Recording из
        /// настроек. Переживает закрытие окна (его закрывает сам переход в
        /// System Settings) — иначе кнопку перезапуска негде было бы показать.
        /// Сбрасывается, как только preflight увидел выданное разрешение.
        static let screenRecordingSetupRequested = "screenRecordingSetupRequested"
        // Archive. These three keep saying "tray": the literal is what sits in
        // the user's defaults, so renaming it would reset the item limit, turn
        // persistence back off and orphan the saved archive on upgrade. The
        // constants are named after the literals on purpose — a name that
        // disagreed with the string it holds is worse than an outdated word.
        static let trayMaxItems          = "trayMaxItems"
        static let persistTray           = "persistTray"
        static let trayPersistedData     = "trayPersistedData"
        static let defaultColorFormat    = "defaultColorFormat"
        /// Space-to-preview over an archive cell. Off means the key is never
        /// claimed at all — see `TransientHotkeyCenter`.
        static let archiveSpacePreview   = "archiveSpacePreview"
        /// Language codes the user keeps for translation, in their own order.
        /// Absent means "never seeded"; an empty array is a list the user
        /// emptied themselves and must not be re-seeded over.
        static let translationLanguages  = "translationLanguages"
        // Updates
        static let checkForUpdates        = "checkForUpdates"
        static let lastUpdateCheck        = "lastUpdateCheck"
        static let skippedUpdateVersion   = "skippedUpdateVersion"
        // Appearance / Language
        static let settingsAppearance      = "settingsAppearance"
        static let thumbnailClickAction    = "thumbnailClickAction"
        static let settingsStyle           = "settingsStyle"
        static let noNotchPanelStyle       = "noNotchPanelStyle"
        static let noNotchNotchScale       = "noNotchNotchScale"
        static let preferredLanguage       = "preferredLanguage"
        // Hotkeys (the 5 global actions store combos via HotkeyAction; these two
        // are the local color-picker shortcuts, enable/disable only).
        static let hotkeyHUDFormatEnabled  = "hotkeyHUDFormatEnabled"
        static let hotkeyArrowMove1Enabled  = "hotkeyArrowMove1Enabled"
        static let hotkeyArrowMove10Enabled = "hotkeyArrowMove10Enabled"
        static let hotkeyArrowMove50Enabled = "hotkeyArrowMove50Enabled"
    }

    /// Whether the user has been sent to the Screen Recording pane during
    /// *this* run. It exists only because opening that pane closes the
    /// settings window, which would discard view state — so it must outlive a
    /// window, never a launch. A fresh process reads the real grant, so
    /// `AppDelegate` clears it at startup; leaving it set would keep offering
    /// a pointless restart, and claim the user toggled something they never
    /// touched, to anyone who visited the pane once and walked away.
    static var screenRecordingSetupRequested: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.screenRecordingSetupRequested) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.screenRecordingSetupRequested) }
    }

    // MARK: General
    static var settingsStyle: SettingsStyle {
        let raw = UserDefaults.standard.string(forKey: Keys.settingsStyle) ?? "toolbar"
        return SettingsStyle(rawValue: raw) ?? .toolbar
    }

    static var settingsAppearance: SettingsAppearance {
        let raw = UserDefaults.standard.string(forKey: Keys.settingsAppearance) ?? "system"
        return SettingsAppearance(rawValue: raw) ?? .system
    }

    /// What a click on the post-capture thumbnail HUD opens.
    static var thumbnailClickAction: ThumbnailClickAction {
        let raw = UserDefaults.standard.string(forKey: Keys.thumbnailClickAction)
            ?? ThumbnailClickAction.editor.rawValue
        return ThumbnailClickAction(rawValue: raw) ?? .editor
    }

    /// Panel shape used on displays without a physical notch.
    static var noNotchPanelStyle: NoNotchPanelStyle {
        let raw = UserDefaults.standard.string(forKey: Keys.noNotchPanelStyle)
            ?? NoNotchPanelStyle.rounded.rawValue
        return NoNotchPanelStyle(rawValue: raw) ?? .rounded
    }

    /// User multiplier applied on top of the automatic notch-style scale
    /// (menuBarHeight / 34). 1.0 = auto only. Clamped to a sane range.
    static var noNotchNotchScale: Double {
        let v = UserDefaults.standard.object(forKey: Keys.noNotchNotchScale) as? Double ?? 1.0
        return min(1.5, max(0.5, v))
    }

    static var showThumbnailHUD: Bool {
        UserDefaults.standard.object(forKey: Keys.showThumbnailHUD) as? Bool ?? true
    }
    static var thumbnailDismissDelay: Double {
        let v = UserDefaults.standard.object(forKey: Keys.thumbnailDismissDelay) as? Double ?? 3.0
        return v > 0 ? v : 3.0
    }

    // MARK: Capture
    static var saveDirectoryURL: URL {
        if let data = UserDefaults.standard.data(forKey: Keys.saveDirectoryBookmark) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: [],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                if isStale, let fresh = try? url.bookmarkData(options: [],
                                                               includingResourceValuesForKeys: nil,
                                                               relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: Keys.saveDirectoryBookmark)
                }
                return url
            }
            // Bookmark data exists but can’t be resolved — folder was likely
            // moved, deleted, or on an unmounted volume. Surface once via the
            // centralized presenter (throttled) so the user gets a remediation
            // path instead of silently writing to Downloads.
            let fallback = defaultSaveURL()
            UserFacingError.present(.saveDirectoryInaccessible(url: fallback))
            return fallback
        }
        return defaultSaveURL()
    }

    /// One-time migration: if a legacy plain-path saveDirectory exists but no
    /// security-scoped bookmark does, attempt to create the bookmark now.
    /// Should be called once at app launch before any capture/archive access.
    static func migrateLegacySaveDirectoryIfNeeded() {
        guard UserDefaults.standard.data(forKey: Keys.saveDirectoryBookmark) == nil,
              let path = UserDefaults.standard.string(forKey: Keys.saveDirectory),
              !path.isEmpty
        else { return }

        let url = URL(fileURLWithPath: path)
        guard (try? url.checkResourceIsReachable()) == true else { return }

        if let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: Keys.saveDirectoryBookmark)
            UserDefaults.standard.removeObject(forKey: Keys.saveDirectory)
            Log.settings.debug("Migrated legacy saveDirectory to bookmark.")
        }
    }

    /// Fallback resolution when no (resolvable) bookmark exists: prefer the
    /// legacy plain-string path if present, otherwise the default ~/Pictures/Stampo.
    /// ~/Pictures is outside the TCC-protected set (Desktop/Documents/Downloads/
    /// iCloud), so this default needs no permission prompt — unlike the old
    /// Downloads default. Users with an explicitly chosen path/bookmark keep it;
    /// only never-configured (default) users migrate to Pictures.
    private static func defaultSaveURL() -> URL {
        let path = UserDefaults.standard.string(forKey: Keys.saveDirectory) ?? ""
        if !path.isEmpty { return URL(fileURLWithPath: path) }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("Stampo", isDirectory: true)
    }

    static func withSaveDirectoryAccess<T>(_ block: (URL) throws -> T) throws -> T {
        let url = saveDirectoryURL
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try block(url)
    }

    /// True until the welcome flow is completed once. System permission state
    /// is intentionally independent: resetting Screen Recording must not send
    /// a returning user through onboarding again.
    static var onboardingPending: Bool {
        !UserDefaults.standard.bool(forKey: Keys.hasCompletedOnboarding)
    }
    static var filenamePreset: FilenamePreset {
        let raw = UserDefaults.standard.string(forKey: Keys.filenamePreset) ?? "compact"
        return FilenamePreset(rawValue: raw) ?? .compact
    }

    /// Returns the current counter value without incrementing — for settings preview.
    static var captureCounter: Int {
        UserDefaults.standard.integer(forKey: Keys.captureCounter)
    }

    /// Atomically increments and returns the counter — call only on an actual capture.
    static func nextCaptureCounter() -> Int {
        let n = UserDefaults.standard.integer(forKey: Keys.captureCounter) + 1
        UserDefaults.standard.set(n, forKey: Keys.captureCounter)
        return n
    }

    static var fileFormat: String {
        UserDefaults.standard.string(forKey: Keys.fileFormat) ?? "png"
    }
    static var playSound: Bool {
        UserDefaults.standard.object(forKey: Keys.playSound) as? Bool ?? true
    }
    static var copyToClipboard: Bool {
        UserDefaults.standard.object(forKey: Keys.copyToClipboard) as? Bool ?? true
    }
    static var includeCursor: Bool {
        UserDefaults.standard.object(forKey: Keys.includeCursor) as? Bool ?? false
    }
    static var includeWindowShadow: Bool {
        UserDefaults.standard.object(forKey: Keys.includeWindowShadow) as? Bool ?? true
    }
    static var defaultCaptureMode: CaptureMode {
        let raw = UserDefaults.standard.string(forKey: Keys.defaultCaptureMode) ?? "selection"
        return CaptureMode(rawValue: raw) ?? .selection
    }
    static var defaultTimerDelay: CaptureDelay {
        let raw = UserDefaults.standard.integer(forKey: Keys.defaultTimerDelay)
        return CaptureDelay(rawValue: raw) ?? .off
    }

    // MARK: Archive
    static var trayMaxItems: Int {
        let v = UserDefaults.standard.object(forKey: Keys.trayMaxItems) as? Int ?? 20
        return max(5, min(50, v))
    }
    static var persistTray: Bool {
        UserDefaults.standard.object(forKey: Keys.persistTray) as? Bool ?? false
    }
    static var defaultColorFormat: ColorSchemeType {
        let raw = UserDefaults.standard.string(forKey: Keys.defaultColorFormat) ?? "HEX"
        return ColorSchemeType(rawValue: raw) ?? .hex
    }
    /// On by default: previewing what the pointer rests on is the reason the
    /// archive shows files at all, and the key is only claimed while the
    /// pointer is parked on one of its cells. The switch exists because that
    /// claim is system-wide — a user who would rather Space always be a space
    /// should not have to take the archive's word for when it lets go.
    static var archiveSpacePreview: Bool {
        UserDefaults.standard.object(forKey: Keys.archiveSpacePreview) as? Bool ?? true
    }

    // MARK: Hotkeys
    static var hotkeyHUDFormatEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyHUDFormatEnabled) as? Bool ?? true
    }
    static var hotkeyArrowMove1Enabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyArrowMove1Enabled) as? Bool ?? true
    }
    static var hotkeyArrowMove10Enabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyArrowMove10Enabled) as? Bool ?? true
    }
    static var hotkeyArrowMove50Enabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyArrowMove50Enabled) as? Bool ?? true
    }

    // MARK: Launch at Login
    static func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                UserDefaults.standard.set(enabled, forKey: Keys.launchAtLogin)
            } catch {
                // Silently fail — toggle reverts to actual state via launchAtLoginEnabled
            }
        }
    }

    static var launchAtLoginEnabled: Bool {
        if #available(macOS 13, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? false
    }

    // MARK: Filename resolver

    static func resolveFilename(preset: FilenamePreset, date: Date, counter: Int, format: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let d   = cal.dateComponents(in: .current, from: date)
        let months = ["Jan","Feb","Mar","Apr","May","Jun",
                      "Jul","Aug","Sep","Oct","Nov","Dec"]
        let mon  = months[max(0, min((d.month ?? 1) - 1, 11))]
        let yyyy = String(format: "%04d", d.year ?? 2024)
        let mm   = String(format: "%02d", d.month ?? 1)
        let dd   = String(format: "%02d", d.day ?? 1)
        let hh   = String(format: "%02d", d.hour ?? 0)
        let min  = String(format: "%02d", d.minute ?? 0)
        let ss   = String(format: "%02d", d.second ?? 0)
        let ext  = format == "jpg" ? "jpg" : (format == "tiff" ? "tiff" : "png")

        let base: String
        switch preset {
        case .compact:  base = "\(mon)·\(dd)-\(hh)·\(min)·\(ss)"
        case .iso:      base = "\(yyyy)-\(mm)-\(dd) \(hh)-\(min)-\(ss)"
        case .numbered: base = "\(yyyy)-\(mm)-\(dd) #\(counter)"
        case .dense:    base = "\(yyyy)\(mm)\(dd)-\(hh)\(min)\(ss)"
        }
        return base + ".\(ext)"
    }
}

// MARK: - CaptureMode: RawRepresentable (for @AppStorage)
extension CaptureMode: RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: String) {
        switch rawValue {
        case "selection": self = .selection
        case "window":    self = .window
        case "screen":    self = .screen
        default:          return nil
        }
    }
    public var rawValue: String {
        switch self {
        case .selection: return "selection"
        case .window:    return "window"
        case .screen:    return "screen"
        }
    }
}

// MARK: - CaptureDelay: RawRepresentable (for @AppStorage)
extension CaptureDelay: RawRepresentable {
    public typealias RawValue = Int
    public init?(rawValue: Int) {
        switch rawValue {
        case 0:  self = .off
        case 3:  self = .s3
        case 5:  self = .s5
        case 10: self = .s10
        default: return nil
        }
    }
    public var rawValue: Int { seconds }
}

// MARK: - SettingsAppearance

enum SettingsAppearance: String, CaseIterable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var title: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - ThumbnailClickAction

/// What clicking the post-capture thumbnail opens.
/// (Display titles live in the settings Picker as localized literals.)
enum ThumbnailClickAction: String, CaseIterable {
    /// Stampo's built-in annotation editor.
    case editor  = "editor"
    /// The system default app (previous behavior).
    case preview = "preview"
}

// MARK: - NoNotchPanelStyle

/// Panel shape on displays without a physical notch.
/// (Display titles live in the settings Picker as localized literals.)
enum NoNotchPanelStyle: String, CaseIterable {
    /// Floating rounded rectangle sitting just below the menu bar.
    case rounded = "rounded"
    /// Mimics a notched Mac: the notch shape pinned flush to the top screen edge.
    case notch   = "notch"
}

// MARK: - SettingsStyle

enum SettingsStyle: String, CaseIterable {
    case toolbar = "toolbar"
    case sidebar = "sidebar"

    var title: String {
        switch self {
        case .toolbar: return String(localized: "Toolbar")
        case .sidebar: return String(localized: "Sidebar")
        }
    }
}

// MARK: - ColorSchemeType ↔ HUDColorFormat
extension ColorSchemeType {
    var hudFormat: HUDColorFormat {
        switch self {
        case .hex:  return .hex
        case .rgb:  return .rgb
        case .hsl:  return .hsl
        case .hsb:  return .hsb
        case .cmyk: return .cmyk
        }
    }
}

// MARK: - ColorSchemeType: RawRepresentable (for @AppStorage)
extension ColorSchemeType: RawRepresentable {
    public typealias RawValue = String
    public init?(rawValue: String) {
        switch rawValue {
        case "HEX":  self = .hex
        case "RGB":  self = .rgb
        case "HSL":  self = .hsl
        case "HSB":  self = .hsb
        case "CMYK": self = .cmyk
        default:     return nil
        }
    }
    public var rawValue: String { title }
}

// MARK: - FilenamePreset

enum FilenamePreset: String, CaseIterable {
    case compact  = "compact"   // Apr·12-14·30·05
    case iso      = "iso"       // 2024-04-12 14-30-05
    case numbered = "numbered"  // 2024-04-12 #98
    case dense    = "dense"     // 20240412-143005

    /// Example string shown in the helper caption.
    var title: String {
        switch self {
        case .compact:  return "Apr·12 — 14·30·05"
        case .iso:      return "2024-04-12 14-30-05"
        case .numbered: return "2024-04-12 #98"
        case .dense:    return "20240412-143005"
        }
    }

    /// Short display name (localization key) for the dropdown menu.
    var name: String {
        switch self {
        case .compact:  return "Compact"
        case .iso:      return "ISO 8601"
        case .numbered: return "Numbered"
        case .dense:    return "Dense"
        }
    }
}


// MARK: - NSColor hex init (for archive restore)
extension NSColor {
    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat(value         & 0xFF) / 255
        // sRGB, not calibrated RGB: `hexString` and every other formatter read
        // components through `usingColorSpace(.sRGB)`, so a calibrated color
        // built here came back out as a different hex — a restored #FF0000
        // displayed and copied as #FF2600.
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
