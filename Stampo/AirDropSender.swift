import AppKit
import OSLog

/// The one place that talks to AirDrop.
///
/// `NSSharingService(named:)` has been deprecated since macOS 13 and has no
/// replacement: `NSSharingServicePicker` can only offer AirDrop as one choice
/// among many, which is exactly the extra step this drop zone exists to remove.
/// Kept in a single file, behind a deprecated declaration (which is also what
/// silences the warning at the call site), so the day a real API appears there
/// is one function to rewrite.
///
/// Folders are sent as they are — AirDrop transfers a directory natively, so
/// unlike the share sheet path this must NOT pre-zip them.
enum AirDropSender {

    /// Shows the AirDrop device picker for `urls`. Returns false when AirDrop
    /// can't take them, in which case the caller still owns the files.
    @discardableResult
    @MainActor
    static func send(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let items = urls.map { $0 as NSURL }
        guard let service = service(for: items) else {
            Log.share.error("AirDrop unavailable for \(urls.count) item(s)")
            feedbackHUD.show(.airDropUnavailable, on: nil)
            return false
        }
        // Accessory app: the AirDrop window belongs to us, and without
        // activating it opens behind whatever the user was working in.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: items)
        return true
    }

    /// nil when AirDrop is off or can't take these items.
    ///
    /// The one deprecation warning the project carries lives on the next line
    /// and is deliberate: marking this function deprecated would silence it but
    /// push the warning onto every caller, and marking it available-anyway
    /// would hide the fact that this needs revisiting if Apple ships a
    /// replacement.
    @MainActor
    private static func service(for items: [NSURL]) -> NSSharingService? {
        guard let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: items)
        else { return nil }
        return service
    }

    @MainActor private static let feedbackHUD = TextCaptureHUD()
}
