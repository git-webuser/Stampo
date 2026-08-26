import AppKit
import SwiftUI

/// A mesh, with a handle on each of its four corners.
///
/// The gradient's ramp got positions, selection, a hex field and a keyboard;
/// the mesh got none of it and stayed a bare row of four chips — no way to say
/// which corner you meant, so no way to paint one from the palette or from the
/// archive either. This is the same language, minus the one thing a mesh does
/// not have: a corner has nowhere to move to, so there is nothing to drag and
/// nothing to add or remove. Four corners, always.
///
/// **Which index is which corner was measured, not assumed.** `drawMesh` names
/// its first pair "top", but the presentation space is flipped, so on screen —
/// in the export and in a SwiftUI `Canvas` alike, which was checked separately —
/// index 0 is bottom-left, 1 bottom-right, 2 top-left, 3 top-right.
/// `MeshCorner` is the only place that knows it, and a test holds it still.
struct MeshCornersPlate: View {
    let colors: [Presentation.Color]
    @Binding var selection: Int
    let apply: ([Presentation.Color]) -> Void

    @State private var keyboardAccess = NSApp.isFullKeyboardAccessEnabled
    @FocusState private var isFocused: Bool

    private static let height: CGFloat = 76
    private static let handleSize: CGFloat = 18
    private static let inset: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            ZStack {
                plate
                ForEach(MeshCorner.allCases, id: \.rawValue) { corner in
                    handle(corner, in: geo.size)
                }
            }
        }
        .frame(height: Self.height)
        .focusable(keyboardAccess)
        .focused($isFocused)
        .onKeyPress { press in handleKey(press) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Corners"))
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            keyboardAccess = NSApp.isFullKeyboardAccessEnabled
        }
    }

    private var plate: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                PresentationRenderer.drawBackground(
                    .mesh(colors: colors),
                    in: CGRect(origin: .zero, size: size),
                    ctx: cg
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func handle(_ corner: MeshCorner, in size: CGSize) -> some View {
        let selected = corner.rawValue == selection
        return Circle()
            .fill(swiftUIColor(color(of: corner)))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            .overlay {
                if selected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: Self.handleSize, height: Self.handleSize)
            .position(x: corner.isLeading ? Self.inset : size.width - Self.inset,
                      y: corner.isTop ? Self.inset : size.height - Self.inset)
            .onTapGesture {
                // The second click on the same corner is the one that means
                // "change this colour" — the first has to be free to mean
                // "this is the one I am talking about", as on the stop bar.
                if selected {
                    openPanel(for: corner)
                } else {
                    selection = corner.rawValue
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(corner.titleKey))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let corner = MeshCorner(rawValue: selection) else { return .ignored }
        switch press.key {
        case .leftArrow, .rightArrow:
            selection = corner.acrossHorizontally.rawValue
            return .handled
        case .upArrow, .downArrow:
            selection = corner.acrossVertically.rawValue
            return .handled
        case .space, .return:
            openPanel(for: corner)
            return .handled
        default:
            return .ignored
        }
    }

    private func openPanel(for corner: MeshCorner) {
        PresentationInspector.openColorPanel(for: color(of: corner)) { picked in
            var updated = padded
            updated[corner.rawValue] = picked
            apply(updated)
        }
    }

    /// A mesh drawn from fewer than four colours repeats what it has; the
    /// handles must not fall off the end of a short list while it does.
    private var padded: [Presentation.Color] {
        guard let first = colors.first else { return Array(repeating: .white, count: 4) }
        return (0..<4).map { colors.indices.contains($0) ? colors[$0] : first }
    }

    private func color(of corner: MeshCorner) -> Presentation.Color {
        padded[corner.rawValue]
    }

    private func swiftUIColor(_ color: Presentation.Color) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue,
              opacity: color.alpha)
    }
}

/// The four corners of a mesh, in the order `Presentation.Background.mesh`
/// stores them — measured against what the renderer actually paints, in both
/// the export and a SwiftUI `Canvas`. `meshCornersAreWhereTheHandlesSay` in the
/// renderer's tests is what keeps this honest.
nonisolated enum MeshCorner: Int, CaseIterable, Sendable {
    case bottomLeading = 0
    case bottomTrailing = 1
    case topLeading = 2
    case topTrailing = 3

    var isTop: Bool { self == .topLeading || self == .topTrailing }
    var isLeading: Bool { self == .topLeading || self == .bottomLeading }

    var acrossHorizontally: MeshCorner {
        switch self {
        case .bottomLeading:  return .bottomTrailing
        case .bottomTrailing: return .bottomLeading
        case .topLeading:     return .topTrailing
        case .topTrailing:    return .topLeading
        }
    }

    var acrossVertically: MeshCorner {
        switch self {
        case .bottomLeading:  return .topLeading
        case .topLeading:     return .bottomLeading
        case .bottomTrailing: return .topTrailing
        case .topTrailing:    return .bottomTrailing
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .topLeading:     return "Top Left"
        case .topTrailing:    return "Top Right"
        case .bottomLeading:  return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }
}
