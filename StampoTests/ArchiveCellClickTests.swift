import AppKit
import SwiftUI
import Testing
@testable import Stampo

/// What the drag shim reports back when a cell is clicked.
///
/// `archiveTapIntent` decides what a click *means*, and is unit-tested on its
/// own; this covers the half that has to come from AppKit — that the modifiers
/// reach the closure at all, and which event's modifiers they are. Neither can
/// be reasoned out: the flags travel with the NSEvent through the shim, and the
/// choice between the press and the release is invisible until a hand lets go
/// of ⌘ a moment early.
@MainActor
@Suite struct ArchiveCellClickTests {

    private func event(_ type: NSEvent.EventType,
                       _ modifiers: NSEvent.ModifierFlags,
                       at location: NSPoint = NSPoint(x: 10, y: 10)) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: location,
                           modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 1)!
    }

    /// Presses and releases the shim, and reports the modifiers the tap carried
    /// — nil when no tap fired at all.
    private func click(down: NSEvent.ModifierFlags,
                       up: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        var seen: NSEvent.ModifierFlags?
        var pressed = false
        var dragging = false
        let shim = ArchiveDragShimView(isPressed: Binding(get: { pressed }, set: { pressed = $0 }),
                                       isDragging: Binding(get: { dragging }, set: { dragging = $0 }),
                                       onHoverChange: { _ in },
                                       onTap: { seen = $0 })
        shim.frame = NSRect(x: 0, y: 0, width: 51, height: 32)
        shim.mouseDown(with: event(.leftMouseDown, down))
        shim.mouseUp(with: event(.leftMouseUp, up))
        return seen
    }

    @Test func aPlainClickCarriesNoModifiers() throws {
        let flags = try #require(click(down: [], up: []))
        #expect(!flags.contains(.command))
    }

    @Test func aCommandClickCarriesCommand() throws {
        let flags = try #require(click(down: .command, up: .command))
        #expect(flags.contains(.command))
    }

    /// The gesture is decided when the button goes down. Releasing ⌘ first is
    /// what a hand actually does, and it must not turn the pick back into a
    /// plain click — which would open the capture in Preview and hide the panel.
    @Test func lettingGoOfCommandFirstStillPicks() throws {
        let flags = try #require(click(down: .command, up: []))
        #expect(flags.contains(.command))
    }

    /// And the reverse: ⌘ pressed after the button went down is not the gesture
    /// the user started, so it does not turn a plain click into a pick.
    @Test func graspingCommandLateDoesNotPick() throws {
        let flags = try #require(click(down: [], up: .command))
        #expect(!flags.contains(.command))
    }

    // MARK: - Click or drag

    /// Where a press turns into a drag. A table, because the rule is a distance
    /// and the interesting cases are the ones either side of it: the wobble of a
    /// hand that means to click, the exact threshold, and every direction.
    @Test(arguments: [
        // Wobble: still a click.
        (0.0, 0.0, 0.0, 0.0, false),
        (0.0, 0.0, 2.0, 2.0, false),     // 2.83 pt along the diagonal
        (0.0, 0.0, 3.0, 0.0, false),
        (0.0, 0.0, 3.99, 0.0, false),
        // At and past the threshold: a drag.
        (0.0, 0.0, 4.0, 0.0, true),
        (0.0, 0.0, 0.0, 4.0, true),
        (0.0, 0.0, 3.0, 3.0, true),      // 4.24 pt along the diagonal
        (0.0, 0.0, 40.0, 0.0, true),
        // The sign of the move does not matter.
        (0.0, 0.0, -3.0, 0.0, false),
        (0.0, 0.0, -4.0, 0.0, true),
        (0.0, 0.0, 0.0, -4.0, true),
        (0.0, 0.0, -3.0, -3.0, true),
        // Measured from the press point, not from the origin.
        (100.0, 50.0, 102.0, 52.0, false),
        (100.0, 50.0, 96.0, 50.0, true),
    ])
    func theDragStartsFourPointsFromThePress(sx: Double, sy: Double,
                                             cx: Double, cy: Double,
                                             started: Bool) {
        #expect(archiveDragHasStarted(from: CGPoint(x: sx, y: sy),
                                      to: CGPoint(x: cx, y: cy)) == started)
    }

    /// A shim with a payload hook that counts how often the drag asked for one.
    /// The payload is empty on purpose: `mouseDragged` then returns before it
    /// opens a drag session, which a unit test has no window for — but it only
    /// gets as far as asking for the payload once it has decided to drag, so the
    /// count is the decision. Returns what happened on a press at (10, 10), the
    /// given drag events and a release at `releaseAt`.
    private func press(dragTo moves: [NSPoint],
                       releaseAt: NSPoint = NSPoint(x: 10, y: 10))
        -> (taps: Int, payloadRequests: Int, dragging: Bool) {
        var taps = 0
        var requests = 0
        var dragging = false
        let shim = ArchiveDragShimView(isPressed: .constant(false),
                                       isDragging: Binding(get: { dragging }, set: { dragging = $0 }),
                                       onHoverChange: { _ in },
                                       onTap: { _ in taps += 1 })
        shim.frame = NSRect(x: 0, y: 0, width: 51, height: 32)
        shim.makePayload = { requests += 1; return [] }
        shim.mouseDown(with: event(.leftMouseDown, []))
        for point in moves {
            shim.mouseDragged(with: event(.leftMouseDragged, [], at: point))
        }
        shim.mouseUp(with: event(.leftMouseUp, [], at: releaseAt))
        return (taps, requests, dragging)
    }

    /// The bug itself: a click with a slightly moving hand. Before, the first
    /// drag event started the session and the tap never ran.
    @Test func aClickThatMovesAFewPointsStillTaps() {
        let result = press(dragTo: [NSPoint(x: 11, y: 10), NSPoint(x: 12, y: 11)],
                           releaseAt: NSPoint(x: 12, y: 11))
        #expect(result.taps == 1)
        #expect(result.payloadRequests == 0)
        #expect(!result.dragging)
    }

    @Test func aClickWithoutMovementStillTaps() {
        let result = press(dragTo: [])
        #expect(result.taps == 1)
        #expect(result.payloadRequests == 0)
    }

    /// Several small drag events do not add up to a drag: the distance is from
    /// the press, not from the previous event.
    @Test func manySmallStepsStayAClick() {
        let steps = (1...3).map { NSPoint(x: 10 + CGFloat($0), y: 10) }
        let result = press(dragTo: steps, releaseAt: NSPoint(x: 13, y: 10))
        #expect(result.taps == 1)
        #expect(result.payloadRequests == 0)
    }

    /// Four points out, the drag begins: the payload is built — once, for the
    /// event that crossed the line.
    @Test func theDragBeginsAtTheThreshold() {
        let result = press(dragTo: [NSPoint(x: 12, y: 10), NSPoint(x: 14, y: 10)],
                           releaseAt: NSPoint(x: 14, y: 10))
        #expect(result.payloadRequests == 1)
    }

    /// A drag event with no press behind it has nothing to measure from.
    @Test func aDragEventWithoutAPressIsIgnored() {
        var requests = 0
        let shim = ArchiveDragShimView(isPressed: .constant(false), isDragging: .constant(false),
                                       onHoverChange: { _ in }, onTap: { _ in })
        shim.makePayload = { requests += 1; return [] }
        shim.mouseDragged(with: event(.leftMouseDragged, [], at: NSPoint(x: 100, y: 100)))
        #expect(requests == 0)
    }
}
