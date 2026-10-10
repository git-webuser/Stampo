import Foundation

/// A hiccup in the middle of a capture that is waited out rather than stopped
/// for: a notification, or the AirPods' sheet, over the scroll point for a
/// second; the window list stumbling and saying for an instant that the window
/// is gone or has another size. The user asked for a screenshot, not for a
/// pause every time the system speaks up.
///
/// Not the hiccups before the first frame, which end in the window's
/// screenshot, and not the failures that are not hiccups — the window moved to
/// the background, the scroll area replaced — which pause as ever.
nonisolated enum ScrollInterference: Equatable {
    /// Something is over the scroll point, so that a wheel event sent there
    /// would go to it.
    case pointCovered
    /// The window is said to be gone, or to have another size or scale: the
    /// window list answered wrongly for a moment.
    case windowGlitch

    static func classify(_ error: Error) -> ScrollInterference? {
        switch error {
        case ScrollDriverError.pointCovered:
            return .pointCovered
        case ScrollDriverError.windowSizeChanged,
             ScrollDriverError.displayScaleChanged,
             WindowFrameSourceError.windowUnavailable:
            return .windowGlitch
        default:
            return nil
        }
    }

    /// How often it is looked at again, and for how long, before the capture
    /// pauses: ten seconds for a thing over the point — a notification can stay
    /// that long — and two for a stumble of the window list.
    static let pollInterval: TimeInterval = 0.25
    var patience: TimeInterval {
        switch self {
        case .pointCovered: return 10
        case .windowGlitch: return 2
        }
    }

    enum Verdict: Equatable {
        /// It has passed: the step goes on.
        case goOn
        /// It has not, and there is time: look again.
        case wait
        /// It has not and the time is up: pause, with the toast.
        case pause
    }

    func verdict(clear: Bool, waited: TimeInterval) -> Verdict {
        if clear { return .goOn }
        return waited >= patience ? .pause : .wait
    }

    /// How many hiccups in a row the capture waits out without a step made in
    /// between: a flicker that never settles is a reason to pause after all.
    static let maxWithoutProgress = 5

    var logText: String {
        switch self {
        case .pointCovered: return "the scroll point is covered"
        case .windowGlitch: return "the window is not where it was"
        }
    }

    /// Whether an Accessibility refusal — no scroll area under the point — is
    /// let through to the window-level check instead of stopping the step. In
    /// the middle of a capture it is: the window is where it was and on top,
    /// and a wheel event goes to whatever is there, the pixels telling whether
    /// it scrolled. Before the first strip the area is what the capture rests
    /// on, and it stops as it did.
    static func fallsBackToWindowCheck(_ error: Error, hasCollected: Bool) -> Bool {
        guard hasCollected, case ScrollDriverError.scrollAreaUnavailable = error else { return false }
        return true
    }
}
