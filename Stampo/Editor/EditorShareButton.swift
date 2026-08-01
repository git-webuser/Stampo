import AppKit
import SwiftUI

/// Toolbar button that opens the system share sheet.
///
/// `NSSharingServicePicker` rather than SwiftUI's `ShareLink`: the shared item
/// is the freshly rendered composite (base image + annotations), which must be
/// produced when the button is clicked, not on every view update the way a
/// `ShareLink` payload would be. The picker is also the real AppKit popover —
/// same anchoring, same service list — instead of a menu that imitates it.
/// The anchor plumbing itself lives in SharePicker.swift; the tray's context
/// menus share it.
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
            .sharePickerAnchor(anchor)
    }
}
