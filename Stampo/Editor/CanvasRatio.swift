import CoreGraphics
import Foundation

/// Which of a page's two numbers is being set.
nonisolated enum CanvasDimension: Sendable {
    case width, height
}

/// A page shape, and the arithmetic that turns one into a page.
///
/// The formats used to be pixel sizes: "Instagram 4:5" meant exactly
/// 1080×1350, so a retina screenshot 2400 wide was resampled down to 1080
/// before it ever reached the export. A ratio has no such opinion — the page is
/// derived from the picture that is actually in it, and nothing is thrown away.
///
/// Kept free of AppKit and SwiftUI, like `PresentationLayout` and
/// `GradientStops`: every rule here is a function the tests can ask about
/// directly.
nonisolated struct CanvasRatio: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat
    /// Key in the string catalogue for the format's familiar name. Shown as the
    /// chip's tooltip — the ratio is on the chip, the name is what tells you
    /// what it is *for*.
    var titleKey: String

    /// Width over height. 1.78 for 16:9, 0.8 for 4:5.
    var value: CGFloat { height > 0 ? width / height : 1 }

    var swapped: CanvasRatio {
        CanvasRatio(width: height, height: width, titleKey: titleKey)
    }

    /// One orientation each: the other half of every pair is this one turned,
    /// which is what the swap button is for.
    static let presets: [CanvasRatio] = [
        CanvasRatio(width: 1, height: 1, titleKey: "Square"),
        CanvasRatio(width: 3, height: 4, titleKey: "Classic 3:4"),
        CanvasRatio(width: 4, height: 5, titleKey: "Instagram 4:5"),
        CanvasRatio(width: 16, height: 9, titleKey: "Twitter / X"),
        CanvasRatio(width: 1200, height: 630, titleKey: "Open Graph")
    ]

    // MARK: Page arithmetic

    /// The page this ratio makes for the layout on screen.
    ///
    /// The picture keeps the size it is drawn at — its own pixels if nothing
    /// has scaled it, the smaller size if the user has — and the tightest of
    /// its four gaps becomes the margin all round. Whatever the ratio then
    /// needs beyond that is air on the long axis.
    ///
    /// Taking the *tightest* gap rather than the four as they are is what makes
    /// the operation reversible: air added for one ratio is not counted as
    /// content by the next one, so 4:5 → 16:9 → 4:5 lands on the page it
    /// started from instead of growing every time.
    static func page(for ratio: CanvasRatio, in layout: PresentationLayout.Resolved) -> CGSize {
        let margin = tightestGap(in: layout)
        let content = CGSize(width: layout.imageRect.width + margin * 2,
                             height: layout.imageRect.height + margin * 2)
        return grown(content, to: ratio)
    }

    /// The smallest page of this ratio that holds `content`.
    static func grown(_ content: CGSize, to ratio: CanvasRatio) -> CGSize {
        guard content.width > 0, content.height > 0, ratio.value > 0 else { return content }
        let contentRatio = content.width / content.height
        if contentRatio < ratio.value {
            return CGSize(width: (content.height * ratio.value).rounded(),
                          height: content.height.rounded())
        }
        return CGSize(width: content.width.rounded(),
                      height: (content.width / ratio.value).rounded())
    }

    static func tightestGap(in layout: PresentationLayout.Resolved) -> CGFloat {
        let gaps = PresentationLayout.gaps(layout)
        return max(0, min(min(gaps.top, gaps.bottom), min(gaps.leading, gaps.trailing)))
    }

    /// Where the picture sits on the new page: the same size it is drawn at
    /// now, in the same relative spot.
    ///
    /// `scale` is relative to the fitted size, and the fit changes with the
    /// page — so keeping the drawn size means recomputing it, not copying it.
    /// The centre is a fraction of the canvas and is copied as it is: a picture
    /// the user pushed left stays proportionally left instead of jumping to the
    /// middle because the page changed shape.
    static func placement(keepingDrawnSizeOf layout: PresentationLayout.Resolved,
                          from placement: Presentation.ImagePlacement,
                          imagePixelSize: CGSize,
                          on page: CGSize) -> Presentation.ImagePlacement {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              page.width > 0, page.height > 0,
              layout.imageRect.width > 0
        else { return placement }
        let fit = min(page.width / imagePixelSize.width, page.height / imagePixelSize.height)
        guard fit > 0 else { return placement }
        return Presentation.ImagePlacement(
            center: placement.center,
            scale: layout.imageRect.width / (imagePixelSize.width * fit)
        )
    }

    // MARK: Reading a ratio back

    /// Whether a page of this size is this ratio. Loose on purpose: the page is
    /// rounded to whole pixels, so 2736×3420 and 4:5 must count as the same
    /// answer.
    func matches(_ size: CGSize, tolerance: CGFloat = 0.005) -> Bool {
        guard size.width > 0, size.height > 0, value > 0 else { return false }
        let ratio = size.width / size.height
        return abs(ratio - value) / value <= tolerance
    }

    /// The preset a page is currently in, or nil for a shape of the user's own.
    /// Either orientation counts — turning a format does not make it a
    /// different one.
    static func preset(matching size: CGSize) -> CanvasRatio? {
        presets.first { $0.matches(size) || $0.swapped.matches(size) }
    }

    /// "16:9" when the sides reduce to something a person would say, otherwise
    /// a decimal like "1.91:1". Reducing 1600×900 to 16:9 is the point; showing
    /// "1080:1350" instead of "4:5" would be worse than showing nothing.
    static func label(for size: CGSize) -> String {
        let (w, h) = parts(for: size)
        guard w > 0, h > 0 else { return "—" }
        func number(_ value: CGFloat) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.2f", Double(value))
        }
        return "\(number(w)):\(number(h))"
    }

    /// The same reduction as `label`, as two numbers — what the ratio fields
    /// show and edit. Whole numbers while the ratio reduces to something small,
    /// a decimal against 1 when it does not: 1237×641 is 1.93 : 1, never
    /// 1237 : 641.
    static func parts(for size: CGSize) -> (CGFloat, CGFloat) {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return (0, 0) }
        var a = w, b = h
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(1, a)
        let rw = w / divisor, rh = h / divisor
        if rw <= 32 && rh <= 32 { return (CGFloat(rw), CGFloat(rh)) }
        let ratio = CGFloat(w) / CGFloat(h)
        return ratio >= 1
            ? ((ratio * 100).rounded() / 100, 1)
            : (1, ((1 / ratio) * 100).rounded() / 100)
    }

    /// A ratio built from two measurements — the page's own sides, turned
    /// round by the swap button. Zero or nonsense means "no change", which the
    /// caller shows by leaving the page alone.
    static func typed(width: CGFloat, height: CGFloat) -> CanvasRatio? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CanvasRatio(width: width, height: height, titleKey: "Canvas")
    }
}
