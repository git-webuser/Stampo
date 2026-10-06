import Foundation

/// Why a scrolling capture stopped with part of the image collected. Shown as
/// a short line in a toast: the strip's two buttons say what can be done —
/// Save keeps what there is, ✕ drops it — so this says only what happened.
nonisolated enum ScrollPauseReason: Equatable, Sendable {
    /// The frames could not be put together, and nothing in particular is to blame.
    case framesNotAligned
    /// Where the frames would not line up there was something changing by itself.
    case videoInTheWay
    /// Scrolling stopped moving the page, and sending one line back shows why:
    /// this part of the page is fixed and changes in place.
    case partDoesNotScroll

    /// The localization key — the English text.
    var key: String {
        switch self {
        case .framesNotAligned: return "Frames couldn't be aligned."
        case .videoInTheWay:    return "A video or animation is in the way"
        case .partDoesNotScroll: return "This part of the page doesn't scroll"
        }
    }

    /// The reason for a run of steps that would not match: the page has a video
    /// or an animation in it if tiles that fit no offset — changing by
    /// themselves — were seen in at least two of the failures.
    static func forFailedMatches(changingTilesSeen: Bool) -> ScrollPauseReason {
        changingTilesSeen ? .videoInTheWay : .framesNotAligned
    }
}
