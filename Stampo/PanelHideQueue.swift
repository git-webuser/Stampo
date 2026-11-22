import Foundation

/// The close of the panel that is in flight, and the caller action that waits
/// for it to end.
///
/// `NotchPanelController.hideAnimated` asks this on every call. A close that
/// arrives while another is still running joins it instead of starting a second
/// animation, for two reasons that were both seen:
///
/// - Starting over erased the action the first close carried. A capture begun a
///   moment before a click outside the panel never started, with nothing in
///   the log to say why.
/// - Keeping the action and running two animations does not work either: the
///   first one's report hands over to the capture overlay (`.preSelection`),
///   and the second one's report then sets `.hidden` over it.
nonisolated struct PanelHideQueue {
    /// A hide older than this is taken for stuck — the animation never reported
    /// or the window is gone — and a new close runs it again, as it did before
    /// joining existed, so it can still bring the panel down. The longest real
    /// hide, the Archive's three phases, takes 0.56 s.
    static let joinWindow: TimeInterval = 1.0

    nonisolated enum Request: Equatable {
        /// No hide is running: run one.
        case begin
        /// A hide is running, but too long for a healthy one: run it again.
        case restart
        /// A hide is running: leave its animation alone.
        case join
    }

    /// When the hide in flight began. Joins do not move it, so the window is
    /// counted from the close that owns the animation.
    private(set) var startedAt: TimeInterval?

    private var completion: (() -> Void)?

    var hasPendingCompletion: Bool { completion != nil }

    /// - Parameters:
    ///   - isHiding: the panel's state is `.hiding`. Only the controller knows
    ///     this: a show that cut the last hide short has left the state, and
    ///     the clock of that hide says nothing about the next one.
    ///   - elapsed: seconds since the hide in flight began, if the clock was
    ///     started for it.
    static func decide(isHiding: Bool, elapsed: TimeInterval?) -> Request {
        guard isHiding, let elapsed else { return .begin }
        return (0..<joinWindow).contains(elapsed) ? .join : .restart
    }

    /// Takes one close and says what to do with the animation; the waiting
    /// action is already updated when this returns.
    ///
    /// A new hide takes the caller's action as it is — none included — which is
    /// what every close did before. A join keeps what is waiting unless the
    /// caller brings an action of its own: the last one wins, and a close with
    /// none (Esc, a click outside) does not cancel a capture.
    mutating func request(isHiding: Bool, now: TimeInterval,
                          completion: (() -> Void)?) -> Request {
        let decision = Self.decide(isHiding: isHiding, elapsed: startedAt.map { now - $0 })
        switch decision {
        case .begin, .restart:
            startedAt = now
            self.completion = completion
        case .join:
            if let completion { self.completion = completion }
        }
        return decision
    }

    /// Hands out the waiting action, once. The caller runs it.
    mutating func take() -> (() -> Void)? {
        defer { completion = nil }
        return completion
    }

    /// Drops the waiting action without running it: a show interrupting a hide,
    /// or a sleep, a Space change or a screen change under it.
    mutating func discard() {
        completion = nil
    }
}
