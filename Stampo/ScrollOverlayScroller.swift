import CoreGraphics
import Foundation

/// The scroll bars of macOS are drawn over the content and fade out a moment after the wheel stops (the default
/// style). A capture that cuts the edge where the bar lies loses the last points of what is under it (the bottom of
/// the thumbnails in Finder's gallery); a capture that waits for the bar to go leaves the edge whole.
nonisolated enum ScrollOverlayScroller {
    /// What the capture does about the scroll bar at the edge of an area.
    enum Decision: Equatable {
        /// "Don't capture scroll bars" is off: the edge is left as it is.
        case leave
        /// Cut the edge by this many points, as always.
        case cut(points: CGFloat)
        /// The bar is drawn over the content and goes by itself: leave the edge, and take the frame of a step
        /// no sooner than `minimumDelay` after the wheel.
        case wait
    }

    /// The least time after a wheel event before a frame is taken, in seconds, while the bar may still be shown.
    static let minimumDelay: TimeInterval = 1.0

    /// `axisScrollbarInset`: what the scroll bar that Accessibility found along the scroll takes of the area (nil
    /// when there is none: the fixed reserve of `fallbackPoints` is cut, as before). A page is cut as it always was,
    /// and so are the bars that are always shown (legacy): they stand beside the content or over it for good.
    /// `overMovingStrip`: false when the bar lies in a part of the area where nothing moves.
    static func decision(excludeScrollbars: Bool, isWebPage: Bool, overlayStyle: Bool,
                         axisScrollbarInset: CGFloat?, overMovingStrip: Bool = true,
                         fallbackPoints: CGFloat) -> Decision {
        guard excludeScrollbars else { return .leave }
        if !isWebPage, overlayStyle, overMovingStrip, let axisScrollbarInset, axisScrollbarInset > 0 { return .wait }
        return .cut(points: axisScrollbarInset ?? fallbackPoints)
    }

    /// Whether the bar, which takes `inset` points of the area's far edge across the scroll (the right edge for a
    /// scroll down, the bottom for one sideways), lies over the strip that moves (`ScrollStrip`); with no strip the
    /// whole area moves, and it does.
    static func barLiesOver(strip: ClosedRange<CGFloat>?, area: CGRect, axis: ScrollAxis, inset: CGFloat) -> Bool {
        guard let strip else { return true }
        let edge = axis == .vertical ? area.maxX : area.maxY
        return strip.upperBound > edge - inset
    }

    /// How much longer to wait before taking a frame, when `elapsed` seconds have passed since the last wheel event.
    static func remainingWait(sinceWheel elapsed: TimeInterval) -> TimeInterval {
        max(0, minimumDelay - max(0, elapsed))
    }
}
