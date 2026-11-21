import Foundation

/// Bookkeeping for lifting the global Carbon hotkeys while a shortcut field
/// records.
///
/// Why they have to be lifted: `RegisterEventHotKey` CONSUMES a registered
/// combination before the app sees a key event — the app gets
/// `kEventHotKeyPressed`, not a keyDown. The recorder listens with a local
/// `NSEvent` monitor, so for a combination another Stampo action holds the
/// monitor never fires, `HotkeyValidator` is never asked, and the field just
/// sits at "Press keys…". With the registrations lifted the key reaches the
/// field, which can then say "Already used by another Stampo action".
///
/// This type only counts who needs the registrations to stay lifted and says
/// when the controller has to act. It touches no Carbon API, so the rules
/// that matter — lift once, come back on every exit path, never come back
/// early — are testable without registering a single hotkey.
///
/// A count and not a flag: moving from one field to another posts "stopped"
/// for the first and "started" for the second, and the two can land in either
/// order. A flag would come back while the second field is still recording.
nonisolated struct HotkeyRegistrationPause: Equatable {

    /// What the controller has to do after an event.
    enum Transition: Equatable {
        /// Nothing: the registrations are already in the state asked for.
        case unchanged
        /// Unregister every live hotkey (statuses stay as they are).
        case lift
        /// Register the hotkeys again from the stored combinations.
        case restore
    }

    /// Recorders that are armed right now.
    private(set) var activeRecorders = 0

    var isPaused: Bool { activeRecorders > 0 }

    /// False while paused. Every caller that registers or unregisters hotkeys
    /// on its own schedule — the defaults observer, the wake-up check — has to
    /// ask first: a recording writes the new combination to the defaults
    /// before it stops, and a re-registration at that moment would take the
    /// keys back from the field.
    var allowsRegistrationChanges: Bool { !isPaused }

    /// A recorder armed (`.hotkeyRecordingChanged` with `true`).
    mutating func recordingBegan() -> Transition {
        activeRecorders += 1
        return activeRecorders == 1 ? .lift : .unchanged
    }

    /// A recorder disarmed (`.hotkeyRecordingChanged` with `false`). A stray
    /// "stopped" with nobody recording — a view that disappears after Settings
    /// closed and already lifted the pause — changes nothing.
    mutating func recordingEnded() -> Transition {
        guard activeRecorders > 0 else { return .unchanged }
        activeRecorders -= 1
        return activeRecorders == 0 ? .restore : .unchanged
    }

    /// The Settings window closed. Whatever was recording is gone with it,
    /// even if its view never reported "stopped": the safety net.
    mutating func settingsDidClose() -> Transition {
        guard activeRecorders > 0 else { return .unchanged }
        activeRecorders = 0
        return .restore
    }

    /// The controller stops: forget the recorders without touching anything.
    mutating func reset() {
        activeRecorders = 0
    }
}
