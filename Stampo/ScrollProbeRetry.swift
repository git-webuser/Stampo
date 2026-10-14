import Foundation

/// The probe that calibrates a capture is refused when the page is not yet still: an intro that plays by itself
/// (apple.com/mac-mini, apple.com/iphone-18-pro) shows another frame before the probe than after it. The probe is
/// taken again, about once a second, until it matches or the page has had `limit` seconds.
nonisolated enum ScrollProbeRetry {
    /// How long after the first refusal a new attempt may begin, in seconds.
    static let limit: TimeInterval = 10
    /// The pause before each attempt, in seconds.
    static let pause: TimeInterval = 1

    /// Whether an attempt may begin `elapsed` seconds after the first refusal.
    static func beginsAttempt(after elapsed: TimeInterval) -> Bool {
        elapsed < limit
    }

    /// The attempt whose pair the capture goes on from when none matched: the last in which the probe moved something
    /// (`moved` says, for each attempt in turn). Nil when the probe moved nothing in any of them, and the capture goes
    /// on from the first pair, the one before the attempts.
    static func attemptToKeep(moved: [Bool]) -> Int? {
        moved.lastIndex(of: true)
    }
}
