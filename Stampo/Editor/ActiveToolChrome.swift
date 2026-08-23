import SwiftUI

/// What "this one is on" looks like, in one place.
///
/// Crop and Scan are toggles rather than picker entries, so they build their
/// own buttons — and had only half of it, colouring the icon while staying
/// flat. "This tool is on" has to look the same wherever it is said, and that
/// claim outgrew the toolbar the moment the decor panel gained a row of choices
/// of its own: which way the background picture meets the page is the same kind
/// of statement, and it is now made the same way.
struct ActiveToolChrome: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.22) : .clear)
            )
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
    }
}

extension View {
    func activeToolChrome(_ isActive: Bool) -> some View {
        modifier(ActiveToolChrome(isActive: isActive))
    }
}
