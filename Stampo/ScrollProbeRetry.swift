import Foundation

/// The probe that calibrates a capture is refused when the page is not yet still: an intro that plays by itself
/// (apple.com/mac-mini, apple.com/iphone-18-pro) shows another frame before the probe than after it. The probe is
/// taken again, about once a second, until it matches or the page has had `limit` seconds.
nonisolated enum ScrollProbeRetry {
    /// How long after the first refusal a new attempt may begin, in seconds.
    static let limit: TimeInterval = 10
    /// The pause before each attempt, in seconds.
    static let pause: TimeInterval = 1

    /// The page that does not change on its own is not playing an intro: the frame taken at the same place before this
    /// attempt and the one before the last differ by less than this (the mean difference of the viewport's crops,
    /// the same still point `captureStableWindow` waits for).
    static let stillBelow = 0.003

    /// Whether the attempts go on after one that did not match, given how much the page changed between the last two
    /// looks at it from the same place. An intro or a video does; a page that stands (a line of text) does not, and
    /// one attempt is all the wait it costs. The page is not put back at exactly the same place, so a change that is
    /// not the page's own only costs time.
    static func keepsTrying(changeSinceLastLook: Double) -> Bool {
        changeSinceLastLook >= stillBelow
    }

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
