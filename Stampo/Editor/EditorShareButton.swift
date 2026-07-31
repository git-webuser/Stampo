import AppKit
import SwiftUI

/// Toolbar button that opens the system share sheet.
///
/// `NSSharingServicePicker` rather than SwiftUI's `ShareLink`: the shared item
/// is the freshly rendered composite (base image + annotations), which must be
/// produced when the button is clicked, not on every view update the way a
/// `ShareLink` payload would be. The picker is also the real AppKit popover —
/// same anchoring, same service list — instead of a menu that imitates it.
struct EditorShareButton<Label: View>: View {
    /// Built at click time; an empty result silently does nothing (a render
    /// failure has no share sheet to show).
    let items: () -> [Any]
    @ViewBuilder var label: () -> Label

    /// Holds the AppKit view the popover hangs off. A reference type so the
    /// representable can hand the view back to a re-created `EditorShareButton`.
    @State private var anchor = SharePickerAnchor()

    var body: some View {
        Button { anchor.present(items()) } label: { label() }
            .background(SharePickerAnchorView(anchor: anchor))
    }
}

/// The popover's anchor view, kept outside the SwiftUI value graph.
@MainActor final class SharePickerAnchor {
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
        self.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: below)
    }
}

/// Zero-content AppKit view laid out behind the button purely to give the
/// picker something to point at. It never takes clicks — the SwiftUI button on
/// top of it stays the only hit target.
private struct SharePickerAnchorView: NSViewRepresentable {
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
