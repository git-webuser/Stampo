import AppKit
import SwiftUI

/// Reliable hover tooltips for the editor toolbar.
///
/// SwiftUI's `.help()` does not reliably surface tooltips when the content is
/// hosted in an `NSHostingController` inside an agent (LSUIElement) app — which
/// is exactly the editor window's setup — so hovering the toolbar showed
/// nothing. This overlays a transparent, click-through `NSView` that carries an
/// AppKit `toolTip`, which AppKit's window tooltip manager always displays.
///
/// The text is resolved through `LocaleManager` so it honors the in-app
/// language override (not just the process language), and reading the manager's
/// observable locale here re-renders the tooltip when the language changes.
private struct TooltipCarrier: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView { PassthroughTooltipView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

/// A tooltip-only overlay that never intercepts mouse events, so the control
/// underneath stays fully interactive.
private final class PassthroughTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A tooltip's text: the name in the in-app language, and the shortcut after
/// it in parentheses — "Rectangle (R)". One format for every tooltip in the
/// editor, the drawn ones and the window toolbar's alike.
func tooltipText(_ key: String, shortcut: String? = nil) -> String {
    let localized = LocaleManager.shared.string(key)
    return shortcut.map { "\(localized) (\($0))" } ?? localized
}

extension View {
    /// Attaches a hover tooltip (and matching accessibility label) resolved
    /// from `key` in the app's string catalog via the current in-app language.
    func hoverTip(_ key: String, shortcut: String? = nil) -> some View {
        let text = tooltipText(key, shortcut: shortcut)
        return overlay(TooltipCarrier(text: text).allowsHitTesting(false))
            .accessibilityLabel(Text(verbatim: text))
    }
}
