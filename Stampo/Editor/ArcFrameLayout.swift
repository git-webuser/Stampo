import CoreGraphics

/// The Arc container's size policy, separate from AppKit so the window and
/// split view use the same limits without having to open either in a test.
struct ArcFrameLayout {
    static let panelDefaultWidth: CGFloat = 320
    static let panelMinimumWidth = PresentationInspector.contentMinimumWidth
    static let panelMaximumWidth: CGFloat = 400
    static let detailMinimumWidth: CGFloat = 787
    static let dividerThickness: CGFloat = 8
    static let minimumWidth: CGFloat = 1140

    /// The detail column keeps its floor while a dragged panel takes the
    /// remaining space, up to the panel's own maximum.
    static func panelWidthLimit(windowWidth: CGFloat) -> CGFloat {
        min(panelMaximumWidth, windowWidth - detailMinimumWidth - dividerThickness)
    }

    /// A screen narrower than the normal floor must still be able to contain
    /// the editor. Opening or closing the panel does not change this minimum.
    static func minimumContentWidth(visibleScreenWidth: CGFloat) -> CGFloat {
        min(minimumWidth, visibleScreenWidth)
    }
}
