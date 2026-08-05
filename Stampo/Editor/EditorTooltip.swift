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

/// Glyph → spoken name, for the accessibility hint. Same reason as
/// `HotkeyCombo.spokenDescription`: read as characters, ⌘ is "place of
/// interest sign" and ⇧ is "upwards white arrow".
private let spokenGlyphs: [Character: String] = [
    "⌘": "Command", "⌥": "Option", "⌃": "Control", "⇧": "Shift",
    "↩": "Return", "⌫": "Delete", "⎋": "Escape", "⇥": "Tab", "␣": "Space",
]

/// `"⇧⌘X"` → `"Shift Command X"`.
private func spokenShortcut(_ label: String) -> String {
    label.map { spokenGlyphs[$0] ?? String($0) }.joined(separator: " ")
}

extension View {
    /// Attaches a hover tooltip (and matching accessibility label) resolved
    /// from `key` in the app's string catalog via the current in-app language.
    ///
    /// The tooltip says "Copy (⌘C)" because the eye takes both in at once. The
    /// name and the shortcut split for VoiceOver: rolled into the label they
    /// become one run-on phrase the user has to sit through every time the
    /// button is passed, while a hint is spoken after a pause and can be
    /// turned off entirely.
    func hoverTip(_ key: String, shortcut: String? = nil) -> some View {
        let localized = LocaleManager.shared.string(key)
        let text = shortcut.map { "\(localized) (\($0))" } ?? localized
        return overlay(TooltipCarrier(text: text).allowsHitTesting(false))
            .accessibilityLabel(Text(verbatim: localized))
            .accessibilityHint(Text(verbatim: shortcut.map(spokenShortcut) ?? ""))
    }
}
