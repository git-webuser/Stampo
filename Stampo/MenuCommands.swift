import AppKit
import SwiftUI

// MARK: - MenuIcon

/// One glyph per verb, shared by every context menu in the app — the archive
/// cells, the capture thumbnail, the pinned window. The menus are long (a
/// screenshot offers seven commands) and a symbol is faster to find than a
/// word, but only while the same verb always wears the same symbol, so the
/// vocabulary lives here rather than being spelled out at each call site.
///
/// Near-synonyms are told apart on purpose: "Remove from archive" only drops
/// the entry (xmark) while "Move to Trash" takes the file on disk with it
/// (trash); "Pin to Screen" opens a pin and "Unpin" closes one (pin.slash).
/// Copy/Share keep their base glyph in the "… As" submenus — what a submenu
/// picks there is the notation, not the verb.
enum MenuIcon: String {
    case edit     = "pencil"
    case open     = "arrow.up.forward.app"
    case pin      = "pin"
    case unpin    = "pin.slash"
    case unpinAll = "rectangle.on.rectangle.slash"
    case finder   = "folder"
    case copy     = "doc.on.doc"
    case share    = "square.and.arrow.up"
    /// The glyph the archive's inline CollapseButton already shows, so the menu
    /// row and the button on screen read as one command.
    case collapse = "arrow.down.forward.and.arrow.up.backward"
    /// The archive's multi-select mode. Deliberately the checkbox the cells put
    /// on themselves once it is on, so the row that turns it on and the badges
    /// it produces are recognisably the same thing.
    case select   = "checkmark.circle"
    case remove   = "xmark.circle"
    case trash    = "trash"
}

// MARK: - MenuCommandLabel

/// Menu row label, spelled the one way that keeps its icon: macOS drops the
/// symbol from `Button(_:systemImage:)` and from a plain `Label` once the row
/// becomes an NSMenuItem — only an explicit `.titleAndIcon` style survives the
/// trip (checked on 15.7). Everything goes through here so no row can quietly
/// lose its glyph, which would also drag its title out of line with the rest.
struct MenuCommandLabel: View {
    let titleKey: LocalizedStringKey
    /// nil draws an empty icon of the same width — the row a submenu opens from
    /// would only repeat the glyph of the command right above it, but dropping
    /// the icon outright pulls its title left, out of line with every other row.
    let icon: MenuIcon?

    init(_ titleKey: LocalizedStringKey, icon: MenuIcon) {
        self.titleKey = titleKey
        self.icon = icon
    }

    init(indented titleKey: LocalizedStringKey) {
        self.titleKey = titleKey
        self.icon = nil
    }

    var body: some View {
        Label {
            Text(titleKey)
        } icon: {
            if let icon {
                Image(systemName: icon.rawValue)
            } else {
                // An empty NSImage keeps the icon column's width without
                // drawing into it; a clear SwiftUI shape gets collapsed away.
                Image(nsImage: NSImage(size: NSSize(width: 14, height: 14)))
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - MenuCommandButton

/// A command row in a context menu — Button plus MenuCommandLabel.
struct MenuCommandButton: View {
    let titleKey: LocalizedStringKey
    let icon: MenuIcon
    var role: ButtonRole? = nil
    let action: () -> Void

    init(_ titleKey: LocalizedStringKey,
         icon: MenuIcon,
         role: ButtonRole? = nil,
         action: @escaping () -> Void) {
        self.titleKey = titleKey
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            MenuCommandLabel(titleKey, icon: icon)
        }
    }
}
