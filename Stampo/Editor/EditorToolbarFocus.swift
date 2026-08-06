import SwiftUI

/// Which toolbar buttons currently hold keyboard focus.
///
/// The canvas swallows Space to pan, which is right while the canvas is what
/// the user is working in and wrong the moment they have tabbed onto a button:
/// there Space is how a button is pressed, and hold-to-pan is not what anyone
/// means. The key monitor cannot see SwiftUI's focus, so the buttons publish
/// it here and the monitor lets Space past when one of them has it.
///
/// A set rather than a counter: a button can disappear while focused (the
/// context bar swaps its whole row when the tool changes), and a counter that
/// misses one decrement would strand Space in the wrong mode for good.
@MainActor
final class ToolbarFocus {
    static let shared = ToolbarFocus()
    private var focused: Set<UUID> = []

    var isAnyFocused: Bool { !focused.isEmpty }

    func set(_ id: UUID, _ hasFocus: Bool) {
        if hasFocus { focused.insert(id) } else { focused.remove(id) }
    }
}

/// Shapes the keyboard focus ring on a toolbar button, and publishes the focus.
///
/// macOS draws the ring itself, and drawing a second one by hand was the wrong
/// answer — that is what put two rings around one button. The real problem was
/// the shape: with nothing said about it the system traces the *label*, and
/// the label is a bare SF Symbol, so the ring took the silhouette of whichever
/// glyph the button showed. An indicator whose outline changes per tool is not
/// an indicator. `.contentShape(.focusEffect,)` is the whole fix: the system
/// keeps drawing its own ring, now around the button.
///
/// The radius matches the active-tool fill behind it, so a focused active tool
/// shows a ring concentric with its own highlight rather than two competing
/// rounded rectangles.
private struct ToolbarKeyboardFocus: ViewModifier {
    let activate: () -> Void

    @FocusState private var isFocused: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            // The button itself must not be the focusable one. A focused
            // Button draws the system ring around its *label* — a bare SF
            // Symbol — so the outline takes the silhouette of whichever glyph
            // the button shows, and changes shape from tool to tool. Neither
            // `.focusEffectDisabled()` nor `.contentShape(.focusEffect,)`
            // touches that ring: the borderless style draws it and ignores
            // both. Focus goes to the wrapper instead, where the effect does
            // turn off — and where the ring can follow the button.
            .focusable(false)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 3)
                    .padding(-1)
                    .opacity(isFocused ? 1 : 0)
                    // The ring sits over the button; it must never take the
                    // click meant for it.
                    .allowsHitTesting(false)
            )
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            // The wrapper is what has focus, so pressing it is this modifier's
            // job now. Space only arrives here because ToolbarFocus tells the
            // canvas monitor to stop swallowing it.
            .onKeyPress(.space) { activate(); return .handled }
            .onKeyPress(.return) { activate(); return .handled }
            .onChange(of: isFocused) { _, focused in
                ToolbarFocus.shared.set(id, focused)
            }
            .onDisappear { ToolbarFocus.shared.set(id, false) }
    }
}

extension View {
    /// Focus ring and keyboard activation for a toolbar button. `activate` must
    /// do what clicking the button does. See `ToolbarKeyboardFocus`.
    func toolbarKeyboardFocus(activate: @escaping () -> Void) -> some View {
        modifier(ToolbarKeyboardFocus(activate: activate))
    }
}
