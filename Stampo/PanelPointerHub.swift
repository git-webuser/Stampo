import AppKit
import SwiftUI

/// Tells every panel button where the pointer is, by position.
///
/// A button used to learn it from SwiftUI's hover reports, and those come late
/// here. The panel is a non-activating window of an app that is not active, and
/// most of its mouse-moved events go to the global monitor instead (359 heard
/// there against 131 by the panel's own monitor in one 30 s run). SwiftUI picks
/// the button under the pointer on each event it does get, so between two
/// neighbouring buttons — one hosting view, one hit test per event — the old one
/// stayed lit for 0.5–1.8 s, until the next event the panel got.
///
/// The controller already listens to both monitors for the panel's mouse
/// region. It hands each event's position to the hub, and the hub asks each
/// button's anchor whether the pointer is over it. The global monitor hears the
/// motion densely, so the answer is as fresh as the pointer. There is no timer:
/// nothing runs while the pointer is still.
@MainActor
final class PanelPointerHub {
    static let shared = PanelPointerHub()

    /// Where the pointer is when a button asks outright — when its route comes
    /// back, when a menu closes — rather than being told. A property so a test
    /// can park the pointer; the real one is the system's.
    var location: () -> NSPoint = { NSEvent.mouseLocation }

    /// Weak: an anchor goes with its button, and nothing here has to hear of it.
    private let anchors = NSHashTable<PanelHoverAnchor>.weakObjects()

    func add(_ anchor: PanelHoverAnchor) { anchors.add(anchor) }
    func remove(_ anchor: PanelHoverAnchor) { anchors.remove(anchor) }

    /// Whether the pointer is over this anchor now.
    func contains(_ anchor: PanelHoverAnchor) -> Bool {
        anchor.covers(screenPoint: location())
    }

    /// The pointer moved, or a button went up or down.
    ///
    /// Nothing is told while a button is held: a press is on one button, and a
    /// cell dragged out of the archive over the header is not hovering it. The
    /// release comes through here and settles it.
    func pointerMoved(to location: NSPoint, buttonsDown: Bool) {
        guard !buttonsDown else { return }
        for anchor in anchors.allObjects {
            anchor.report(anchor.covers(screenPoint: location))
        }
    }

    /// The panel is going away with the pointer wherever it was. Its views stay
    /// mounted and no exit would ever arrive.
    func pointerGone() {
        for anchor in anchors.allObjects { anchor.report(false) }
    }
}

/// One per panel button, drawn behind it: an empty view that knows its frame on
/// the screen. AppKit's geometry, not SwiftUI's, so a panel scaled to fit a
/// notch-less menu bar is measured where it is drawn.
final class PanelHoverAnchor: NSView {
    var onPointer: (Bool) -> Void = { _ in }

    func report(_ inside: Bool) { onPointer(inside) }

    /// Never the view a click lands on: the button behind it takes the click as
    /// it did before.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            PanelPointerHub.shared.remove(self)
            return
        }
        PanelPointerHub.shared.add(self)
        // A button mounted under a pointer that is already parked there. Not
        // synchronously: this runs while SwiftUI is still updating the view.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.report(PanelPointerHub.shared.contains(self))
        }
    }
}
