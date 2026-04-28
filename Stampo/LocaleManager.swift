import Foundation
import SwiftUI

// MARK: - LocaleManager

/// Single source of truth for the app's current display language.
///
/// Reads `preferredLanguage` from UserDefaults and exposes a SwiftUI-observable
/// `locale` property. Inject it at every NSHostingView / NSHostingController root
/// via `.managedLocale()` so language changes take effect instantly — no restart.
///
/// AppKit strings created via `LocaleManager.string(_:)` or `LocaleManager.string(_:locale:)`
/// also reflect the selected language instantly — they load directly from the `.lproj`
/// sub-bundle, bypassing the process-level locale cache.
@Observable final class LocaleManager {
    static let shared = LocaleManager()

    /// The resolved Locale for the current language preference.
    private(set) var locale: Locale = .autoupdatingCurrent

    private init() {
        refresh()
        // Re-evaluate whenever any UserDefaults key changes (includes @AppStorage writes).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func refresh() {
        let pref = UserDefaults.standard.string(forKey: AppSettings.Keys.preferredLanguage) ?? "system"
        let resolved: Locale
        switch pref {
        case "en": resolved = Locale(identifier: "en")
        case "ru": resolved = Locale(identifier: "ru")
        default:   resolved = .autoupdatingCurrent
        }
        // Only write back if changed to avoid spurious SwiftUI re-renders.
        if resolved.identifier != locale.identifier {
            locale = resolved
        }
    }
}

// MARK: - lproj bundle helper

extension LocaleManager {
    /// Returns the `.lproj` sub-bundle whose language matches `locale`.
    /// For the "system" case (autoupdatingCurrent) returns `Bundle.main`,
    /// which already uses the process-level preferred language.
    static func bundle(for locale: Locale) -> Bundle {
        let id = locale.identifier
        let langCode: String
        if id.hasPrefix("ru")      { langCode = "ru" }
        else if id.hasPrefix("en") { langCode = "en" }
        else                       { return .main }   // system → let the process decide
        return Bundle.main.url(forResource: langCode, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? .main
    }

    /// Looks up `key` from the lproj bundle matching `locale`.
    /// Bypasses the process-level locale cache so language changes
    /// take effect without restarting the app.
    static func string(_ key: String, locale: Locale) -> String {
        bundle(for: locale).localizedString(forKey: key, value: key, table: nil)
    }

    /// Convenience: looks up using the shared manager's current locale.
    func string(_ key: String) -> String {
        Self.string(key, locale: locale)
    }
}

// MARK: - View helper

private struct LocaleAwareWrapper<Content: View>: View {
    let content: Content

    /// Accessing LocaleManager.shared.locale here registers a SwiftUI dependency
    /// on the @Observable property. Any language change triggers a re-render of
    /// this wrapper and propagates the new locale through the content hierarchy.
    var body: some View {
        content.environment(\.locale, LocaleManager.shared.locale)
    }
}

extension View {
    /// Wraps the receiver so its entire subtree uses the locale from LocaleManager.
    /// Call once at each NSHostingView / NSHostingController root — no need to
    /// add it deeper in the hierarchy.
    func managedLocale() -> some View {
        LocaleAwareWrapper(content: self)
    }
}
