import AppKit
import SwiftUI

/// The Arc container shares its dimensions and frame colour without needing
/// to construct a window to resolve either policy.
struct ArcFrameLayout {
    static let panelDefaultWidth: CGFloat = 320
    static let panelMinimumWidth = PresentationInspector.contentMinimumWidth
    static let panelMaximumWidth: CGFloat = 400
    static let detailMinimumWidth: CGFloat = 787
    static let frameGap: CGFloat = 8
    /// The native toolbar already leaves the top gap before content begins.
    static let panelContentInsets = EdgeInsets(top: 0, leading: frameGap, bottom: frameGap, trailing: 0)
    static let cardCornerRadius: CGFloat = 10
    static let minimumWidth: CGFloat = 1140

    /// A single dynamic colour keeps the exposed window frame consistent
    /// when its appearance changes, including the area below the toolbar.
    static let frameColor = NSColor(name: nil) { appearance in
        var color = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            color = (NSColor.windowBackgroundColor.blended(withFraction: 0.07, of: NSColor.labelColor)
                     ?? NSColor.windowBackgroundColor).usingColorSpace(.sRGB) ?? NSColor.windowBackgroundColor
        }
        return color
    }

    /// A screen narrower than the normal floor must still be able to contain
    /// the editor. Opening or closing the panel does not change this minimum.
    static func minimumContentWidth(visibleScreenWidth: CGFloat) -> CGFloat {
        min(minimumWidth, visibleScreenWidth)
    }
}
