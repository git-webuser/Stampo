import AppKit
import Testing
@testable import Stampo

/// The editor keeps its scan overlay in a `@State` and hands it closures that
/// capture the view, which means the overlay's own storage — a cycle
/// overlay → closure → view → overlay. The cycle is only broken if the overlay
/// lets go of its callbacks when the session ends; otherwise a closed editor
/// window keeps its whole `EditorDocument` (a 5K base image is ≈ 59 MB) for the
/// rest of the run.
///
/// `Owner` stands in for that view: it holds the overlay and arms it with
/// closures that capture the owner strongly, which is what a SwiftUI view
/// struct's closures amount to. None of these tests starts the overlay, so none
/// puts a window on screen or touches the cursor.
@MainActor
@Suite struct SelectionOverlayLifetimeTests {

    private final class Owner {
        let overlay = SelectionOverlay()
        var selections: [CGRect] = []
        var cancellations = 0
        var modes: [ScanSelectionMode] = []

        /// Every callback the editor sets in `beginScanSelection`, each one
        /// reaching back into the owner.
        func arm() {
            overlay.onScanModeChanged = { self.modes.append($0) }
            overlay.onMagnify = { _ in _ = self }
            overlay.onPan = { _ in _ = self }
            overlay.onSelected = { self.selections.append($0) }
            overlay.onCancelled = { self.cancellations += 1 }
        }
    }

    /// Esc, a click without a drag and leaving the tool all end in `cancel()`.
    @Test func cancellingLetsTheOwnerGo() {
        weak var weakOwner: Owner?
        do {
            let owner = Owner()
            weakOwner = owner
            owner.arm()
            owner.overlay.cancel()
        }
        #expect(weakOwner == nil)
    }

    /// A completed selection ends in `finish(with:)`.
    @Test func finishingASelectionLetsTheOwnerGo() {
        weak var weakOwner: Owner?
        do {
            let owner = Owner()
            weakOwner = owner
            owner.arm()
            owner.overlay.finish(with: CGRect(x: 1, y: 2, width: 30, height: 40))
        }
        #expect(weakOwner == nil)
    }

    /// Letting go must come *after* the call: the owner still has to hear about
    /// the selection and the cancellation that ended the session.
    @Test func theOwnerStillHearsHowTheSessionEnded() {
        let owner = Owner()
        owner.arm()
        let rect = CGRect(x: 1, y: 2, width: 30, height: 40)
        owner.overlay.finish(with: rect)
        #expect(owner.selections == [rect])
        #expect(owner.cancellations == 0)

        owner.arm()
        owner.overlay.cancel()
        #expect(owner.cancellations == 1)
        #expect(owner.selections == [rect])
    }

    /// The overlay is reused for the next scan; the owner arms it again at
    /// every start, and that second session must work.
    @Test func anOverlayCanBeArmedAgainAfterItEnded() {
        let owner = Owner()
        owner.arm()
        owner.overlay.cancel()
        owner.arm()
        owner.overlay.finish(with: CGRect(x: 5, y: 5, width: 10, height: 10))
        #expect(owner.selections.count == 1)
    }
}
