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

        /// Stable key used for throttling; identical kinds share the same cooldown.
        var throttleKey: String {
            switch self {
            case .screenCaptureFailed:       return "screenCaptureFailed"
            case .colorPickerUnavailable:    return "colorPickerUnavailable"
            case .saveDirectoryInaccessible: return "saveDirectoryInaccessible"
            }
        }

        var title: String {
            switch self {
            case .screenCaptureFailed:
                return "Screenshot failed"
            case .colorPickerUnavailable:
                return "Color picker unavailable"
            case .saveDirectoryInaccessible:
                return "Save folder is not accessible"
            }
        }

        var message: String {
            switch self {
            case .screenCaptureFailed(let reason):
                let base = "macOS couldn’t capture the screen. This usually means Screen Recording permission is missing or was revoked."
                return reason.map { "\(base)\n\nDetails: \($0)" } ?? base
            case .colorPickerUnavailable(let reason):
                let base = "The color picker can’t read pixel data. Grant Screen Recording permission to NotchShot so it can sample colors from the screen."
                return reason.map { "\(base)\n\nDetails: \($0)" } ?? base
            case .saveDirectoryInaccessible(let url):
                return "NotchShot can’t write screenshots to “\(url.lastPathComponent)”. The folder may have been moved, renamed, or access was revoked. Choose a new save folder in Settings → Capture."
            }
        }

        /// If non-nil, an "Open…" button is shown that routes the user to the
        /// relevant remediation surface.
        var remediation: Remediation? {
            switch self {
            case .screenCaptureFailed, .colorPickerUnavailable:
                return .openScreenRecordingSettings
            case .saveDirectoryInaccessible:
                return .openAppSettings
            }
        }
    }

    enum Remediation {
        case openScreenRecordingSettings
        case openAppSettings

        var buttonTitle: String {
            switch self {
            case .openScreenRecordingSettings: return "Open Privacy Settings"
            case .openAppSettings:             return "Open NotchShot Settings"
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
            alert.addButton(withTitle: "Dismiss")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                remediation.perform()
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Notification for app-settings routing

extension Notification.Name {
    /// Posted when a remediation action needs the app's Settings window opened.
    /// `AppDelegate` should observe this and forward to `SettingsWindowController`.
    static let requestOpenSettings = Notification.Name("NotchShot.requestOpenSettings")
}
