import AppKit
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
    /// The live picker outlives `present` — it stays up until the user picks a
    /// service or dismisses it, so it can't be a local.
    private var picker: NSSharingServicePicker?

    func present(_ items: [Any]) {
        guard let view, !items.isEmpty else { return }
        // AppKit resolves the edge in the anchor view's own coordinate space,
        // and SwiftUI's hosting views are flipped — so "below the button" is
        // maxY there and minY in a conventional view.
        let below: NSRectEdge = view.isFlipped ? .maxY : .minY
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        NotificationCenter.default.post(name: .sharePickerDidOpen, object: nil)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: below)
    }

    fileprivate func pickerFinished() {
        picker = nil
        NotificationCenter.default.post(name: .sharePickerDidClose, object: nil)
    }
}

// @preconcurrency: the delegate protocol is not main-actor annotated, but AppKit
// only ever calls it on the main thread.
extension SharePickerAnchor: @preconcurrency NSSharingServicePickerDelegate {
    /// Called with the chosen service, or nil when the user dismissed the
    /// picker without choosing — either way the picker is gone, so this is the
    /// close half of the notification bracket.
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        pickerFinished()
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
