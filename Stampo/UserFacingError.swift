import AppKit

// MARK: - UserFacingError

/// Central presenter for user-facing errors: a small, throttled NSAlert layer
/// so background failures (screencapture, SCShareableContent, security scope)
/// surface to the user once — instead of dying silently in `print(...)` — while
/// still avoiding alert storms when a failure repeats on every mouse move or
/// every rapid capture.
///
/// All strings are in English as the primary language per the iteration-5
/// localization direction; they will be moved to a String Catalog later.
///
/// `present(_:)` is nonisolated: call sites can be on any queue. The presenter
/// hops to the main thread internally before touching NSAlert / shared state.
enum UserFacingError {

    // MARK: Kinds

    enum Kind {
        /// `/usr/sbin/screencapture` returned non-zero or produced no output file.
        case screenCaptureFailed(reason: String?)

        /// ScreenCaptureKit could not enumerate or sample a display.
        case colorPickerUnavailable(reason: String?)

        /// Security-scoped bookmark for the user-chosen save directory could
        /// not be resolved or access was denied.
        case saveDirectoryInaccessible(url: URL)

        /// CGEvent.tapCreate returned nil — the user hasn't granted
        /// Input Monitoring permission in Privacy & Security settings.
        case notchClickUnavailable

        /// Stable key used for throttling; identical kinds share the same cooldown.
        var throttleKey: String {
            switch self {
            case .screenCaptureFailed:       return "screenCaptureFailed"
            case .colorPickerUnavailable:    return "colorPickerUnavailable"
            case .saveDirectoryInaccessible: return "saveDirectoryInaccessible"
            case .notchClickUnavailable:     return "notchClickUnavailable"
            }
        }

        var title: String {
            switch self {
            case .screenCaptureFailed:
                return String(localized: "Screenshot failed")
            case .colorPickerUnavailable:
                return String(localized: "Color picker unavailable")
            case .saveDirectoryInaccessible:
                return String(localized: "Save folder is not accessible")
            case .notchClickUnavailable:
                return String(localized: "Notch click unavailable")
            }
        }

        var message: String {
            switch self {
            case .screenCaptureFailed(let reason):
                let base = String(localized: "macOS couldn't capture the screen. This usually means Screen Recording permission is missing or was revoked.")
                if let r = reason {
                    return base + "\n\n" + String(format: String(localized: "Details: %@"), r)
                }
                return base
            case .colorPickerUnavailable(let reason):
                let base = String(localized: "The color picker can't read pixel data. Grant Screen Recording permission to Stampo so it can sample colors from the screen.")
                if let r = reason {
                    return base + "\n\n" + String(format: String(localized: "Details: %@"), r)
                }
                return base
            case .saveDirectoryInaccessible(let url):
                return String(format: String(localized: "Stampo can't write screenshots to \"%@\". The folder may have been moved, renamed, or access was revoked. Choose a new save folder in Settings \u{2192} Capture."), url.lastPathComponent)
            case .notchClickUnavailable:
                return String(localized: "Clicking the notch area to open the panel requires Input Monitoring permission. Grant it in System Settings \u{2192} Privacy & Security \u{2192} Input Monitoring.")
            }
        }

        /// If non-nil, an "Open…" button is shown that routes the user to the
        /// relevant remediation surface.
        var remediation: Remediation? {
            switch self {
            case .screenCaptureFailed, .colorPickerUnavailable:
                return .openScreenRecordingSettings
            case .notchClickUnavailable:
                return .openInputMonitoringSettings
            case .saveDirectoryInaccessible:
                return .openAppSettings
            }
        }
    }

    enum Remediation {
        case openScreenRecordingSettings
        case openInputMonitoringSettings
        case openAppSettings

        var buttonTitle: String {
            switch self {
            case .openScreenRecordingSettings: return String(localized: "Open Privacy Settings")
            case .openInputMonitoringSettings: return String(localized: "Open Privacy Settings")
            case .openAppSettings:             return String(localized: "Open Stampo Settings")
            }
        }

        func perform() {
            switch self {
            case .openScreenRecordingSettings:
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                {
                    NSWorkspace.shared.open(url)
                }
            case .openInputMonitoringSettings:
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                {
                    NSWorkspace.shared.open(url)
                }
            case .openAppSettings:
                NotificationCenter.default.post(name: .requestOpenSettings, object: nil)
            }
        }
    }

    // MARK: Throttle state

    private static var lastShown: [String: Date] = [:]
    /// How long to suppress repeated alerts of the same kind. One minute is
    /// long enough to avoid spam from tight loops (SCShareableContent on every
    /// mouse move) yet short enough to re-notify after the user takes action.
    private static let throttleInterval: TimeInterval = 60

    // MARK: Entry points

    /// Present the alert. Safe to call from any queue — dispatches to main.
    static func present(_ kind: Kind) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { presentOnMain(kind) }
        }
    }

    private static func presentOnMain(_ kind: Kind) {
        let key = kind.throttleKey
        let now = Date()
        if let last = lastShown[key], now.timeIntervalSince(last) < throttleInterval {
            return
        }
        lastShown[key] = now

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = kind.title
        alert.informativeText = kind.message

        if let remediation = kind.remediation {
            alert.addButton(withTitle: remediation.buttonTitle)
            alert.addButton(withTitle: String(localized: "Dismiss"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                remediation.perform()
            }
        } else {
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }
}

// MARK: - Notification for app-settings routing

extension Notification.Name {
    /// Posted when a remediation action needs the app's Settings window opened.
    /// `AppDelegate` should observe this and forward to `SettingsWindowController`.
    static let requestOpenSettings = Notification.Name("Stampo.requestOpenSettings")
}
