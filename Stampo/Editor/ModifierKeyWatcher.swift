import AppKit

/// Live ⌥ state for controls that preview what a modifier will do.
///
/// A local `flagsChanged` monitor rather than SwiftUI's
/// `onModifierKeysChanged`: that modifier reports for the view it is attached
/// to while the pointer interacts with it, and the scanner's ⌥ is pressed in
/// the middle of dragging a marquee across the canvas — the preview must not
/// depend on hover events reaching any particular view. Local monitors only
/// see events already routed to this app, so no Input Monitoring permission is
/// involved (that is what a *global* monitor would need).
///
/// Start and stop it with the mode that needs it; an always-on monitor would
/// re-render the editor on every ⌥ press for no reason.
@MainActor @Observable
final class ModifierKeyWatcher {
    private(set) var optionHeld = false

    @ObservationIgnored private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        // Seed from the current state: ⌥ may already be down when the mode is
        // entered, and flagsChanged only reports the next change.
        optionHeld = NSEvent.modifierFlags.contains(.option)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.optionHeld = event.modifierFlags.contains(.option)
            return event   // never swallow the event: other handlers still need it
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        optionHeld = false
    }
}
