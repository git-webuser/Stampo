import AppKit

// MARK: - UserFacingError

/// Central presenter for user-facing errors: a small, throttled NSAlert layer
/// so background failures (screencapture, SCShareableContent, security scope)
/// surface to the user once — instead of dying silently in `print(...)` — while
/// still avoiding alert storms when a failure repeats on every mouse move or
/// every rapid capture.
///
/// Strings are looked up through LocaleManager so alerts follow the in-app
/// language selection instantly (String(localized:) would use the process
/// locale and ignore the App language setting).
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

        /// Permission-onboarding kinds: while the First-Launch window is the
        /// active surface, these are suppressed so the user isn't buried under
        /// stacked modal alerts about permissions they're already granting.
        var isPermissionKind: Bool {
            switch self {
            case .screenCaptureFailed, .colorPickerUnavailable:
                return true
            case .saveDirectoryInaccessible:
                return false
            }
        }

        /// Stable key used for throttling; identical kinds share the same cooldown.
        var throttleKey: String {
            switch self {
            case .screenCaptureFailed:       return "screenCaptureFailed"
            case .colorPickerUnavailable:    return "colorPickerUnavailable"
            case .saveDirectoryInaccessible: return "saveDirectoryInaccessible"
            }
        }

        var title: String {
            let lm = LocaleManager.shared
            switch self {
            case .screenCaptureFailed:
                return lm.string("Screenshot failed")
            case .colorPickerUnavailable:
                return lm.string("Color picker unavailable")
            case .saveDirectoryInaccessible:
                return lm.string("Save folder is not accessible")
            }
        }

        var message: String {
            let lm = LocaleManager.shared
            switch self {
            case .screenCaptureFailed(let reason):
                let base = lm.string("macOS couldn't capture the screen. This usually means Screen Recording permission is missing or was revoked.")
                if let r = reason {
                    return base + "\n\n" + String(format: lm.string("Details: %@"), r)
                }
                return base
            case .colorPickerUnavailable(let reason):
                let base = lm.string("The color picker can't read pixel data. Grant Screen Recording permission to Stampo so it can sample colors from the screen.")
                if let r = reason {
                    return base + "\n\n" + String(format: lm.string("Details: %@"), r)
                }
                return base
            case .saveDirectoryInaccessible(let url):
                return String(format: lm.string("Stampo can't write screenshots to \"%@\". The folder may have been moved, renamed, or access was revoked. Choose a new save folder in Settings \u{2192} Capture."), url.lastPathComponent)
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
            case .openScreenRecordingSettings: return LocaleManager.shared.string("Open Privacy Settings")
            case .openAppSettings:             return LocaleManager.shared.string("Open Stampo Settings")
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
                // Save-folder problems are fixed in Settings → Capture; deep-link there.
                NotificationCenter.default.post(
                    name: .requestOpenSettings,
                    object: nil,
                    userInfo: [SettingsWindowController.tabUserInfoKey: SettingsTab.capture.rawValue]
                )
            }
        }
    }

    // MARK: Onboarding suppression

    /// Set while the First-Launch permissions window owns the flow (including
    /// the brief window between launch and the window appearing). Permission
    /// alerts are the window's job then, so standalone modals — which would
    /// otherwise stack on top of System Settings — are suppressed.
    ///
    /// This stored flag only needs to cover the launch→show gap; once the
    /// wizard window exists, its presence (isWindowOpen, checked in
    /// presentOnMain) is the authoritative signal, so no dismissal path can
    /// leave alerts muted for the rest of the session.
    @MainActor static var suppressPermissionAlerts = false

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

    @MainActor
    private static func presentOnMain(_ kind: Kind) {
        if kind.isPermissionKind
            && (suppressPermissionAlerts || FirstLaunchWindowController.shared.isWindowOpen) {
            return
        }

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
            alert.addButton(withTitle: LocaleManager.shared.string("Dismiss"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                remediation.perform()
            }
        } else {
            alert.addButton(withTitle: LocaleManager.shared.string("OK"))
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
