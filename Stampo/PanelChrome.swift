import SwiftUI

/// Chrome alphas for the notch panel and the HUD, answering Increase Contrast.
///
/// The panel draws itself as white at low alpha over a dark blur: a button's
/// idle state is nothing at all, hover is 0.16, pressed 0.28. That reads fine
/// normally, and it is exactly the kind of thing Increase Contrast exists to
/// undo — the setting is a statement that faint alpha differences are not
/// legible to this user. So every fill comes back stronger, and the dimmed
/// foregrounds go to full white: hover, pressed and active stay clearly apart
/// from idle instead of separating by a few percent of alpha.
///
/// The panel is white-on-dark in both appearances, so there is no light-mode
/// branch to write here — only the contrast one.
enum PanelChrome {
    /// A background fill. Alpha is pushed up but stays in range, so the
    /// strongest states (0.28, 0.32) go near-solid rather than clipping to a
    /// flat white block that loses the ordering between them.
    static func fill(_ opacity: Double, _ contrast: ColorSchemeContrast) -> Color {
        guard contrast == .increased else { return .white.opacity(opacity) }
        return .white.opacity(min(0.92, opacity * 1.9))
    }

    /// A dimmed foreground (icon or label). Under increased contrast there is
    /// no reason to dim it at all.
    static func foreground(_ opacity: Double, _ contrast: ColorSchemeContrast) -> Color {
        .white.opacity(contrast == .increased ? 1 : opacity)
    }

    /// A hairline or outline. Same treatment as a fill; kept separate so the
    /// call sites read as what they are.
    static func stroke(_ opacity: Double, _ contrast: ColorSchemeContrast) -> Color {
        fill(opacity, contrast)
    }
}
