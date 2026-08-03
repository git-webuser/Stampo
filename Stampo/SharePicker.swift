import AppKit
import OSLog
import SwiftUI

extension Notification.Name {
    /// Bracket the lifetime of a share picker. The notch panel auto-hides on
    /// mouse-exit, and the picker's own window is not a child of the panel — so
    /// without this the sheet would outlive the panel it was opened from (and,
    /// for a service that opens more UI like AirDrop, leave the user staring at
    /// a sheet whose origin has vanished). NotchPanelController holds the panel
    /// open between the two.
    static let sharePickerDidOpen  = Notification.Name("StampoSharePickerDidOpen")
    static let sharePickerDidClose = Notification.Name("StampoSharePickerDidClose")
}

/// The share popover's anchor view, kept outside the SwiftUI value graph.
///
/// `NSSharingServicePicker` needs a live `NSView` to hang off, and the items to
/// share are built at click time — so the picker cannot be a `ShareLink`, whose
/// payload would be re-evaluated on every view update. A reference type so the
/// representable can hand the view back to a re-created SwiftUI view.
@MainActor final class SharePickerAnchor: NSObject {
    weak var view: NSView?
    /// The picker and the chosen service both have to outlive `present`, and
    /// the service has to outlive the *picker*: a share extension reads the
    /// items lazily, so dropping the service the moment the user picks it
    /// cancels transfers that hadn't finished reading yet. Held until the
    /// service reports back through `NSSharingServiceDelegate`.
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?
    /// Closes the session if the chosen service never reports back — see
    /// `armSilenceTimeout`.
    private var silenceTimeout: DispatchWorkItem?
    /// The scheduled "preparing…" toast for a share slow enough to look dead.
    /// Held here rather than as a local in `present` so the preparation running
    /// on a background queue doesn't have to carry it across: `DispatchWorkItem`
    /// is not `Sendable`, and captured into a `@Sendable` closure it warns, with
    /// reason — the cancel and the schedule would be on different threads.
    private var preparationHint: DispatchWorkItem?
    /// Toast for a folder that couldn't be zipped (unreadable, or a location
    /// the app has no permission for).
    ///
    /// Lazy because most anchors never say anything. Every draggable archive
    /// cell holds one of these in `@State`, and SwiftUI evaluates a `@State`
    /// default on every re-init of the struct — so a hover that redraws the row
    /// builds an anchor per cell and throws them all away. Nothing to lose sleep
    /// over, but there is no reason for each of those to drag a HUD along.
    private lazy var feedbackHUD = TextCaptureHUD()

    func present(_ items: [Any]) {
        guard view != nil, !items.isEmpty else { return }
        // Every call site funnels through the same boxing, so a Swift URL and
        // an NSURL reach the service identically.
        let boxed = items.map { item -> Any in (item as? URL).map { $0 as NSURL } ?? item }
        // Hold the panel open across preparation too — zipping a big folder can
        // take a moment, and the panel must still be there to anchor the sheet.
        NotificationCenter.default.post(name: .sharePickerDidOpen, object: nil)

        guard boxed.contains(where: { ShareItemPreparer.isDirectory($0) }) else {
            show(boxed)  // plain files and strings: no preparation, no delay
            return
        }
        // A package of icons zips instantly; a folder of gigabytes does not,
        // and until the sheet appears nothing on screen says the click landed.
        // The toast is scheduled rather than shown outright so the common,
        // instant case stays silent.
        let hint = DispatchWorkItem { [weak self] in
            self?.feedbackHUD.show(.preparingShare, on: nil, autoHideAfter: 30)
        }
        preparationHint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.preparationHintDelay, execute: hint)

        // `self` strongly on purpose: preparation ends by either showing the
        // sheet or, if the anchor's view went away meanwhile, calling `finish`
        // — and letting the anchor die here would skip both, leaving the panel
        // held open by a bracket nothing will ever close.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShareItemPreparer.prepare(boxed)
            DispatchQueue.main.async {
                self.cancelPreparationHint()
                self.feedbackHUD.hide(animated: false)
                self.show(result.items)
                // An item that couldn't be staged is still handed over as the
                // bare folder, which most services drop on the floor. Say so —
                // silence here is the exact failure mode this whole step exists
                // to remove.
                if result.hasFailures { self.feedbackHUD.show(.shareNotPrepared, on: nil) }
            }
        }
    }

    /// Long enough that zipping a package never flashes a toast, short enough
    /// that a slow folder doesn't feel like a dead click.
    private static let preparationHintDelay: TimeInterval = 0.5

    private func show(_ items: [Any]) {
        guard let view else {
            finish()  // the panel went away while we were preparing
            return
        }
        // Accessory app: without activating, a service that opens its own
        // window or sheet (Telegram, Mail) has nowhere to come forward to.
        NSApp.activate(ignoringOtherApps: true)
        // AppKit resolves the edge in the anchor view's own coordinate space,
        // and SwiftUI's hosting views are flipped — so "below the button" is
        // maxY there and minY in a conventional view.
        let below: NSRectEdge = view.isFlipped ? .maxY : .minY
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: below)
    }

    private func cancelPreparationHint() {
        preparationHint?.cancel()
        preparationHint = nil
    }

    fileprivate func finish() {
        cancelPreparationHint()
        silenceTimeout?.cancel()
        silenceTimeout = nil
        picker = nil
        service = nil
        NotificationCenter.default.post(name: .sharePickerDidClose, object: nil)
    }

    /// Ends the session by the clock if the service never says a word.
    ///
    /// Both ways out of a chosen service are delegate callbacks, and a service
    /// is under no obligation to make either — one that opens its own window
    /// and is then quit, or an extension that crashes, simply goes quiet. The
    /// open bracket it left behind holds the notch panel through
    /// `suppressesGlobalAutoHide`, so the panel stops hiding on mouse-exit and
    /// only Esc or the hotkey clears it. Not a dead end, but a mystery, and the
    /// kind that is never reported.
    ///
    /// Long enough to be sure it is silence and not work: a share that is
    /// genuinely still uploading calls back when it lands, and cancelling this
    /// is the first thing `finish` does.
    private func armSilenceTimeout() {
        silenceTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.service != nil else { return }
            Log.share.error("share service reported neither success nor failure; releasing the panel")
            self.finish()
        }
        silenceTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceTimeoutDelay, execute: timeout)
    }

    private static let silenceTimeoutDelay: TimeInterval = 5 * 60
}

// @preconcurrency: neither delegate protocol is main-actor annotated, but
// AppKit only ever calls them on the main thread.
extension SharePickerAnchor: @preconcurrency NSSharingServicePickerDelegate {
    /// Called with the chosen service, or nil when the user dismissed the
    /// picker without choosing. Only the dismissal ends the session here — a
    /// chosen service is still working, and closing the bracket now would both
    /// release it and let the panel slide away mid-transfer.
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        guard let service else {
            finish()
            return
        }
        self.service = service
        armSilenceTimeout()
    }

    /// The documented hook for supplying the service's delegate — set here
    /// rather than on the service directly, which the picker would overwrite.
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }
}

extension SharePickerAnchor: NSSharingServiceDelegate {
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    /// Also fires on a cancelled compose sheet (NSUserCancelledError) — that is
    /// a normal outcome, not something to surface. Anything else is logged: a
    /// share that silently does nothing is otherwise invisible from the outside.
    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any], error: any Error) {
        let nsError = error as NSError
        if !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) {
            Log.share.error("""
                share via \(sharingService.title, privacy: .public) failed: \
                \(nsError.domain, privacy: .public) \(nsError.code) \
                \(nsError.localizedDescription, privacy: .public)
                """)
        }
        finish()
    }
}

// MARK: - Folder → zip

/// Turns anything the share sheet can't carry into something it can.
///
/// Dropped items are whatever the user dragged in, and a "file" on macOS is
/// routinely a *directory*: `.icon`, `.app`, `.rtfd`, Xcode projects, plain
/// folders. Services take the URL either way, but most extensions (Telegram
/// among them) read it as a file, find a directory, and attach nothing —
/// silently. `NSFileCoordinator`'s `.forUploading` is the system's own answer:
/// it hands back a zipped copy for directories and the original for everything
/// else, which is exactly what Mail does with a package attachment.
enum ShareItemPreparer {

    /// True for anything that needs staging. `.isDirectoryKey` describes the
    /// link itself, not its target, so a symlink pointing at a folder would
    /// otherwise slip through and fail the same silent way a package does.
    static func isDirectory(_ item: Any) -> Bool {
        directoryURL(item) != nil
    }

    /// The directory this item ultimately refers to, or nil if it isn't one.
    private static func directoryURL(_ item: Any) -> URL? {
        guard let url = fileURL(item) else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        guard (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        return resolved
    }

    /// Called off the main thread — zipping is proportional to folder size.
    /// `hasFailures` marks a directory that could not be staged (unreadable,
    /// or a location the app has no permission for); it is passed through
    /// unchanged, which the caller surfaces rather than swallowing.
    static func prepare(_ items: [Any]) -> (items: [Any], hasFailures: Bool) {
        let scratch = freshScratchDirectory()
        var hasFailures = false
        let prepared = items.map { item -> Any in
            guard let directory = directoryURL(item) else { return item }
            guard let scratch, let zip = zipped(directory, into: scratch) else {
                hasFailures = true
                return item
            }
            return zip as NSURL
        }
        return (prepared, hasFailures)
    }

    private static func fileURL(_ item: Any) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, (url as URL).isFileURL { return url as URL }
        return nil
    }

    /// The zip `.forUploading` produces is only valid inside the coordination
    /// block, so it is copied out to a directory we own.
    private static func zipped(_ url: URL, into scratch: URL) -> URL? {
        var coordinationError: NSError?
        var result: URL?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .forUploading,
                                       error: &coordinationError) { temporary in
            let destination = scratch.appendingPathComponent(temporary.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: temporary, to: destination)
                result = destination
            } catch {
                Log.share.error("could not stage \(url.lastPathComponent, privacy: .public) for sharing: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let coordinationError {
            Log.share.error("could not zip \(url.lastPathComponent, privacy: .public): \(coordinationError.localizedDescription, privacy: .public)")
        }
        return result
    }

    /// One directory per share, cleared by age rather than by count.
    ///
    /// This used to wipe the whole parent on the way in, on the reasoning that
    /// the previous share's picker had closed by then. It hasn't: a service
    /// reads the items lazily and a zipped folder of any size is still
    /// uploading long after the sheet is gone, so a second share deleted the
    /// first one's file out from under a transfer in progress. Age is the only
    /// thing that can be known here — see `TemporaryStaging`.
    private static func freshScratchDirectory() -> URL? {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StampoShare", isDirectory: true)
        do {
            return try TemporaryStaging.makeDirectory(in: root)
        } catch {
            Log.share.error("could not create the share staging directory: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Zero-content AppKit view laid out behind the content purely to give the
/// picker something to point at. It never takes clicks — whatever SwiftUI draws
/// on top of it stays the only hit target.
struct SharePickerAnchorView: NSViewRepresentable {
    let anchor: SharePickerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Installs `anchor`'s AppKit view behind this view, so a context-menu or
    /// button action can open the share picker pointing at it.
    func sharePickerAnchor(_ anchor: SharePickerAnchor) -> some View {
        background(SharePickerAnchorView(anchor: anchor))
    }
}
