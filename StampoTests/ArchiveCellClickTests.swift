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
                       _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: NSPoint(x: 10, y: 10),
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
}
