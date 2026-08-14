import AppKit
import SwiftUI

/// Toolbar button that opens the system share sheet.
///
/// `NSSharingServicePicker` rather than SwiftUI's `ShareLink`: the shared item
/// is the freshly rendered composite (base image + annotations), which must be
/// produced when the button is clicked, not on every view update the way a
/// `ShareLink` payload would be. The picker is also the real AppKit popover —
/// same anchoring, same service list — instead of a menu that imitates it.
/// The anchor plumbing itself lives in SharePicker.swift; the archive's context
/// menus share it.
@MainActor
struct EditorShareButton<Label: View>: View {
    /// Prepared at click time. Rendering/encoding happens off the MainActor;
    /// an empty result silently does nothing (there is no share sheet to show).
    let prepareItems: @MainActor () async -> PreparedSharePayload?
    @ViewBuilder var label: () -> Label

    /// Holds the AppKit view the popover hangs off. A reference type so the
    /// representable can hand the view back to a re-created `EditorShareButton`.
    @State private var anchor = SharePickerAnchor()
    @State private var isPreparing = false

    var body: some View {
        Button {
            guard !isPreparing else { return }
            isPreparing = true
            Task { @MainActor in
                defer { isPreparing = false }
                guard let payload = await prepareItems() else { return }
                if let fileURL = payload.fileURL {
                    anchor.present([fileURL])
                } else if let data = payload.data,
                          let image = NSImage(data: data) {
                    anchor.present([image])
                }
            }
        } label: { label() }
            .disabled(isPreparing)
            .sharePickerAnchor(anchor)
    }
}
