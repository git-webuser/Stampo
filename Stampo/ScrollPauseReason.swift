import Foundation

/// Why a scrolling capture stopped with part of the image collected. Shown as
/// a short line in a toast: the strip's two buttons say what can be done —
/// Save keeps what there is, ✕ drops it — so this says only what happened.
nonisolated enum ScrollPauseReason: Equatable, Sendable {
    /// The frames could not be put together, and nothing in particular is to blame.
    case framesNotAligned
    /// Where the frames would not line up there was something changing by itself.
    case videoInTheWay
    /// What is under the pointer is no longer the area the capture began on —
    /// the scroll container the click found was replaced as the page changed.
    case scrollAreaChanged
    /// The user scrolled, pressed a button or a key, or took the pointer off the
    /// window while the capture was scrolling by itself.
    case userInput

    /// The localization key — the English text.
    var key: String {
        switch self {
        case .framesNotAligned: return "Frames couldn't be aligned."
        case .videoInTheWay:    return "A video or animation is in the way"
        case .scrollAreaChanged: return "The scroll area under the pointer changed"
        case .userInput:         return "Stopped: you scrolled or pressed something"
        }
    }

    /// The reason for a run of steps that would not match: the page has a video
    /// or an animation in it if tiles that fit no offset — changing by
    /// themselves — were seen in at least two of the failures.
    static func forFailedMatches(changingTilesSeen: Bool) -> ScrollPauseReason {
        changingTilesSeen ? .videoInTheWay : .framesNotAligned
    }
}
