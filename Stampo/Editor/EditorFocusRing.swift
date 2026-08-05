import SwiftUI

/// Keyboard-focus ring for the editor's hand-styled toolbar buttons.
///
/// The buttons are `.borderless` carrying their own background and tint, sized
/// into a tight 26×22 slot. `.buttonStyle(.accessoryBar)` would hand them a
/// real focus ring, but it also brings its own background and selected state —
/// and the active tool is already marked with an accent fill drawn by hand, so
/// the two selections would stack. The ring is drawn instead, the same shape
/// and colour `ShortcutRecorderView` uses, so keyboard focus looks like one
/// thing across the app.
///
/// Each application of the modifier gets its own `@FocusState`, which is what
/// makes it usable per button without threading state through the toolbar.
private struct ToolbarFocusRing: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 3)
                    .padding(-1)
                    .opacity(isFocused ? 1 : 0)
                    // The ring sits over the button it belongs to; it must
                    // never take the click meant for it.
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Shows where keyboard focus is on a toolbar button. See `ToolbarFocusRing`.
    func toolbarFocusRing() -> some View { modifier(ToolbarFocusRing()) }
}
