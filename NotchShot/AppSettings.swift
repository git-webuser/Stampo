import AppKit
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
        static let fileFormat            = "fileFormat"
        static let filenameTemplate      = "filenameTemplate"
        static let playSound             = "playSound"
        static let copyToClipboard       = "copyToClipboard"
        static let includeCursor         = "includeCursor"
        static let includeWindowShadow   = "includeWindowShadow"
        static let defaultCaptureMode    = "defaultCaptureMode"
        static let defaultTimerDelay     = "defaultTimerDelay"
        // Tray
        static let trayMaxItems          = "trayMaxItems"
        static let persistTray           = "persistTray"
        static let trayPersistedData     = "trayPersistedData"
        static let defaultColorFormat    = "defaultColorFormat"
        // Appearance
        static let settingsAppearance      = "settingsAppearance"
        // Hotkeys
        static let hotkeyPanelEnabled      = "hotkeyPanelEnabled"
        static let hotkeySelectionEnabled  = "hotkeySelectionEnabled"
        static let hotkeyFullscreenEnabled = "hotkeyFullscreenEnabled"
        static let hotkeyWindowEnabled     = "hotkeyWindowEnabled"
        static let hotkeyColorEnabled      = "hotkeyColorEnabled"
    }

    // MARK: General
    static var settingsAppearance: SettingsAppearance {
        let raw = UserDefaults.standard.string(forKey: Keys.settingsAppearance) ?? "system"
        return SettingsAppearance(rawValue: raw) ?? .system
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
        let path = UserDefaults.standard.string(forKey: Keys.saveDirectory) ?? ""
        if path.isEmpty {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: path)
    }
    static var fileFormat: String {
        UserDefaults.standard.string(forKey: Keys.fileFormat) ?? "png"
    }
    static var filenameTemplate: String {
        UserDefaults.standard.string(forKey: Keys.filenameTemplate) ?? "{MON}·{DD}-{HH}·{mm}·{ss}"
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

    // MARK: Tray
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

    // MARK: Hotkeys
    static var hotkeyPanelEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyPanelEnabled) as? Bool ?? true
    }
    static var hotkeySelectionEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeySelectionEnabled) as? Bool ?? true
    }
    static var hotkeyFullscreenEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyFullscreenEnabled) as? Bool ?? true
    }
    static var hotkeyWindowEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyWindowEnabled) as? Bool ?? true
    }
    static var hotkeyColorEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.hotkeyColorEnabled) as? Bool ?? true
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
    static func resolveFilename(template: String, date: Date, format: String) -> String {
        let cal = Calendar(identifier: .gregorian)
        let d   = cal.dateComponents(in: .current, from: date)
        let months = ["JAN","FEB","MAR","APR","MAY","JUN",
                      "JUL","AUG","SEP","OCT","NOV","DEC"]
        let mon  = months[max(0, min((d.month ?? 1) - 1, 11))]
        let yyyy = String(format: "%04d", d.year ?? 2024)
        let mm   = String(format: "%02d", d.month ?? 1)
        let dd   = String(format: "%02d", d.day ?? 1)
        let hh   = String(format: "%02d", d.hour ?? 0)
        let min  = String(format: "%02d", d.minute ?? 0)
        let ss   = String(format: "%02d", d.second ?? 0)

        let ext = format == "jpg" ? "jpg" : (format == "tiff" ? "tiff" : "png")

        var name = template
        name = name.replacingOccurrences(of: "{YYYY}", with: yyyy)
        name = name.replacingOccurrences(of: "{MM}",   with: mm)
        name = name.replacingOccurrences(of: "{MON}",  with: mon)
        name = name.replacingOccurrences(of: "{DD}",   with: dd)
        name = name.replacingOccurrences(of: "{HH}",   with: hh)
        name = name.replacingOccurrences(of: "{mm}",   with: min)
        name = name.replacingOccurrences(of: "{ss}",   with: ss)

        // Strip disallowed filename chars
        let allowed = CharacterSet.alphanumerics
            .union(.init(charactersIn: "-_·. "))
        let safe = name.unicodeScalars
            .filter { allowed.contains($0) }
            .map { Character($0) }
        let base = String(safe).trimmingCharacters(in: .whitespaces)
        return (base.isEmpty ? "Screenshot" : base) + ".\(ext)"
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
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
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

// MARK: - NSColor hex init (for tray restore)
extension NSColor {
    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8)  & 0xFF) / 255
        let b = CGFloat(value         & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
