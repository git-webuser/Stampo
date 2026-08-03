import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// Where a click on an archive cell actually lands.
///
/// Hosted rather than unit-tested, because the bug this replaces could only be
/// seen in a real hierarchy. The shim used to override `hitTest` to step out of
/// the badge's corner — but `hitTest` is handed its point in the *superview's*
/// coordinates, and the view SwiftUI wraps a representable in is not flipped
/// while the shim is. The rect came out mirrored: it freed the bottom-right
/// corner, which holds nothing but cell, and a click just under the badge
/// reached neither the badge nor the cell. Reasoning about that on paper is how
/// it survived two attempts; asking the hierarchy settles it.
///
/// The cell is reproduced rather than imported — the real ones are `private` —
/// but with the layout the geometry depends on: the shim as an overlay, the
/// badge as a later overlay bled out past the corner by the same 3 pt.
@MainActor
@Suite struct ArchiveCellHitTests {

    private static let cell = CGSize(width: 51, height: 32)   // a file cell: 32 × 1.6
    private static let bleed: CGFloat = 3

    private struct Shim: NSViewRepresentable {
        @Binding var pressed: Bool
        @Binding var dragging: Bool
        func makeNSView(context: Context) -> ArchiveDragShimView {
            ArchiveDragShimView(isPressed: $pressed, isDragging: $dragging,
                                onHoverChange: { _ in }, onTap: {})
        }
        func updateNSView(_ view: ArchiveDragShimView, context: Context) {}
    }

    private struct Cell: View {
        @State var pressed = false
        @State var dragging = false
        var body: some View {
            Color.gray
                .frame(width: cell.width, height: cell.height)
                .overlay { Shim(pressed: $pressed, dragging: $dragging) }
                .overlay(alignment: .topTrailing) {
                    ArchiveDeleteBadge(action: {})
                        .offset(x: bleed, y: -bleed)
                }
        }
    }

    /// Hosts a cell on screen and returns a probe answering "does the shim get
    /// the click here", addressed as points down-and-right from the cell's
    /// top-left corner.
    ///
    /// Addressed through the window, deliberately. Every coordinate space in
    /// between disagrees about which way is up — the shim is flipped, the
    /// `PlatformViewHost` SwiftUI wraps it in is not, the hosting view is again
    /// — and a probe that converts through them lands upside down and reports a
    /// dead zone at the wrong end of the cell. The window is the one space that
    /// is unambiguous, and the cell's own rect in it is asked for, not assumed.
    private func hosted(_ body: (_ shimGets: (_ fromLeft: CGFloat, _ fromTop: CGFloat) -> Bool) -> Void) throws {
        let hosting = NSHostingView(rootView: Cell().padding(20))
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 100)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Layout, not async work: pumping the run loop is the right tool here.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let shim = try #require(findShim(hosting))
        let cell = shim.convert(shim.bounds, to: nil)   // window space, y up
        body { fromLeft, fromTop in
            hosting.hitTest(CGPoint(x: cell.minX + fromLeft, y: cell.maxY - fromTop)) === shim
        }
    }

    private func findShim(_ view: NSView) -> ArchiveDragShimView? {
        if let shim = view as? ArchiveDragShimView { return shim }
        for sub in view.subviews { if let found = findShim(sub) { return found } }
        return nil
    }

    /// The regression, and the one the user hit: everything below the badge is
    /// the cell's, all the way into the bottom-right corner.
    @Test func theCellAnswersEverywhereBelowTheBadge() throws {
        try hosted { shimGets in
            for fromTop in stride(from: CGFloat(18), through: Self.cell.height - 1, by: 1) {
                for fromLeft in stride(from: CGFloat(30), through: Self.cell.width - 1, by: 1) {
                    #expect(shimGets(fromLeft, fromTop), "dead pixel \(fromLeft) from left, \(fromTop) from top")
                }
            }
        }
    }

    /// The badge keeps its own clicks — by sitting above the shim in the
    /// overlay order, with the shim yielding nothing. Also the control for the
    /// test above: if this passed too, the probe would be addressing the cell
    /// upside down and proving nothing.
    @Test func theBadgeTakesItsOwn() throws {
        try hosted { shimGets in
            #expect(!shimGets(Self.cell.width - 4, 4))
        }
    }

    @Test func therestOfTheCellIsTheCells() throws {
        try hosted { shimGets in
            #expect(shimGets(4, 4))                                        // top-left
            #expect(shimGets(Self.cell.width / 2, Self.cell.height / 2))
            #expect(shimGets(4, Self.cell.height - 4))                     // bottom-left
            #expect(shimGets(Self.cell.width - 4, Self.cell.height - 4))   // bottom-right
        }
    }
}
