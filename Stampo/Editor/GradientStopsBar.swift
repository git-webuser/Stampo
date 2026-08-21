import AppKit
import SwiftUI

/// The gradient's ramp, with a handle per stop.
///
/// It replaces a row of round chips that could say only what order the colours
/// came in, because the stops were spread evenly and had nowhere else to be.
/// Here the position *is* the order: drag a handle past its neighbour and the
/// gradient reorders, because there is nothing else to reorder.
///
/// The ramp is painted by `PresentationRenderer`, the routine that writes the
/// file — so the strip cannot promise a blend the export would draw
/// differently. It is drawn flat, left to right, whatever the gradient's angle
/// or shape: this is the editor for *where the colours are*, and the angle has
/// its own slider below. On a radial gradient the same left-to-right reads as
/// centre-to-edge, which is what it is.
struct GradientStopsBar: View {
    let stops: [Presentation.Stop]
    @Binding var selection: Int
    /// Hands a whole new list back to the document. One call is one undo step.
    let apply: ([Presentation.Stop]) -> Void

    /// Whether the bar takes keyboard focus at all.
    ///
    /// Gated on the system setting for the same reason `ShortcutRecorderView`
    /// gates its own field: `.focusable()` on its own ignores Full Keyboard
    /// Access, and SwiftUI hands initial focus to the first focusable view as
    /// soon as the window becomes key — which lights a ring nobody asked for.
    @State private var keyboardAccess = NSApp.isFullKeyboardAccessEnabled
    @FocusState private var isFocused: Bool
    /// The stop being dragged, so the ramp can follow the pointer without the
    /// selection jumping when the list re-sorts under it.
    @State private var dragging: Int?

    private static let height: CGFloat = 24
    private static let handleSize: CGFloat = 14
    /// Room for a handle sitting on 0 or 1 to hang over the ramp's edge
    /// instead of being clipped by it.
    private static let overhang: CGFloat = handleSize / 2

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                ramp
                ForEach(Array(ordered.enumerated()), id: \.offset) { index, stop in
                    handle(at: index, stop: stop, width: width)
                }
            }
            .contentShape(Rectangle())
            // A tap on the ramp itself adds a stop where it landed, in the
            // colour that was already under the pointer — so adding a handle
            // changes nothing until it is moved, which is what adding a handle
            // should mean.
            .gesture(SpatialTapGesture().onEnded { value in
                insert(at: value.location.x / width)
            })
        }
        .frame(height: Self.height)
        .padding(.horizontal, Self.overhang)
        .focusable(keyboardAccess)
        .focused($isFocused)
        .onKeyPress { press in handleKey(press) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Gradient"))
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            keyboardAccess = NSApp.isFullKeyboardAccessEnabled
        }
    }

    // MARK: Pieces

    private var ramp: some View {
        ZStack {
            checkerboard
            Canvas { context, size in
                context.withCGContext { cg in
                    PresentationRenderer.drawBackground(
                        .linearGradient(stops: ordered, angle: 0),
                        in: CGRect(origin: .zero, size: size),
                        ctx: cg
                    )
                }
            }
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
    }

    /// The transparency behind a stop that carries alpha — the same square grid
    /// the background tiles use.
    private var checkerboard: some View {
        Canvas { context, size in
            let step: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = (row % 2 == 0) ? 0 : step
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: step, height: step)),
                                 with: .color(Color(white: 0.85)))
                    x += step * 2
                }
                y += step
                row += 1
            }
        }
    }

    private func handle(at index: Int, stop: Presentation.Stop, width: CGFloat) -> some View {
        let selected = index == selection
        return Circle()
            .fill(swiftUIColor(stop.color))
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
            .overlay {
                if selected {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                }
            }
            .frame(width: Self.handleSize, height: Self.handleSize)
            .position(x: stop.location * width, y: Self.height / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == nil { dragging = index; selection = index }
                        move(from: dragging ?? index, to: value.location.x / width)
                    }
                    .onEnded { _ in dragging = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Stop"))
            .accessibilityValue(Text(verbatim: percent(stop.location)))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAdjustableAction { direction in
                selection = index
                switch direction {
                case .increment: move(from: index, to: stop.location + 0.01)
                case .decrement: move(from: index, to: stop.location - 0.01)
                @unknown default: break
                }
            }
    }

    // MARK: Editing

    private var ordered: [Presentation.Stop] { GradientStops.sorted(stops) }

    private func insert(at location: CGFloat) {
        let updated = GradientStops.inserted(into: ordered, at: location)
        guard updated != ordered else { return }
        apply(updated)
        // The new stop is the one at the position asked for — select it, since
        // adding a handle is the first half of moving it somewhere.
        if let index = updated.firstIndex(where: {
            abs($0.location - GradientStops.clampedLocation(location)) < 0.0001
        }) {
            selection = index
        }
    }

    private func move(from index: Int, to location: CGFloat) {
        let result = GradientStops.moved(ordered, at: index, to: location)
        guard result.stops != ordered else { return }
        apply(result.stops)
        selection = result.index
        if dragging != nil { dragging = result.index }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let stops = ordered
        let index = GradientStops.clampedSelection(selection, in: stops)
        guard stops.indices.contains(index) else { return .ignored }
        let step: CGFloat = press.modifiers.contains(.shift) ? 0.1 : 0.01
        switch press.key {
        case .leftArrow:
            move(from: index, to: stops[index].location - step)
            return .handled
        case .rightArrow:
            move(from: index, to: stops[index].location + step)
            return .handled
        case .delete, .deleteForward:
            let remaining = GradientStops.removed(from: stops, at: index)
            guard remaining != stops else { return .handled }
            apply(remaining)
            selection = GradientStops.clampedSelection(index, in: remaining)
            return .handled
        case .space, .return:
            PresentationInspector.openColorPanel(for: stops[index].color) { picked in
                apply(GradientStops.recolored(stops, at: index, to: picked))
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func percent(_ location: CGFloat) -> String {
        "\(Int((location * 100).rounded()))%"
    }

    private func swiftUIColor(_ color: Presentation.Color) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue,
              opacity: color.alpha)
    }
}

/// A colour as `#RRGGBB`, typed.
///
/// The ramp says where a colour is and the swatch opens the system panel; this
/// is for the case both are bad at — a colour someone already has as six
/// digits, from a brand sheet or from the app's own archive, where every colour
/// is copied in exactly this notation.
struct HexField: View {
    let color: Presentation.Color
    let onCommit: (Presentation.Color) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 90)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                // Leaving without Return commits too: the field is one value,
                // not a form, and a number left on screen that the document
                // never took is the lie the number fields were built to avoid.
                if !focused { commit() }
            }
            .onAppear { text = Self.hex(color) }
            // Not while typing: the document's colour changes with every
            // keystroke the *other* controls make, and rewriting the field
            // under the cursor would fight the person using it.
            .onChange(of: color) { _, new in
                if !isFocused { text = Self.hex(new) }
            }
            .help("Hex")
            .accessibilityLabel(Text("Hex"))
    }

    private func commit() {
        guard let parsed = NSColor(hexString: text) else {
            text = Self.hex(color)
            return
        }
        let srgb = parsed.usingColorSpace(.sRGB) ?? parsed
        onCommit(Presentation.Color(red: srgb.redComponent, green: srgb.greenComponent,
                                    blue: srgb.blueComponent, alpha: color.alpha))
        text = Self.hex(color)
    }

    private static func hex(_ color: Presentation.Color) -> String {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue,
                alpha: color.alpha).hexString
    }
}
