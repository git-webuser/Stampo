import AppKit
import SwiftUI

/// Native trailing properties for the document's non-destructive decoration.
///
/// The inspector edits a local draft while a control is moving, mirrors that
/// draft into the document for live preview, and commits the whole gesture as
/// one undo step.
///
/// The panel itself never writes on appear: SwiftUI builds it together with the
/// editor, so anything hung on `onAppear` here would fire at editor launch.
/// Starting a decoration belongs to the toolbar button that opens the panel —
/// see `EditorDocument.startDecorationIfNeeded`.
///
/// Every choice a user makes here is shown, not described: canvas formats are
/// proportional tiles and backgrounds are painted by the very routine that
/// renders the export, so a tile cannot promise something the file will not
/// deliver.
struct PresentationInspector: View {
    /// Shared by the toolbar entry point and the inspector header so the
    /// symbol is discoverable by the SF Symbol availability test.
    static let decorSystemImage = "rectangle.center.inset.filled"

    /// Width the swatch row needs before it wraps: eight 22pt wells with 6pt
    /// gaps, plus the group box and the inspector's own padding. The window
    /// controller uses it as the inspector's minimum so a squeezed panel never
    /// pushes colors onto a second line.
    static let contentMinimumWidth: CGFloat = 320

    let document: EditorDocument
    /// The app's colours, live — see `PresentationColorShelf`. nil in previews
    /// and tests, where the built-in palette stands alone.
    let colorShelf: (any PresentationColorShelf)?

    @State private var draft: Presentation
    /// Which groups the user has folded away. Sections are identified by a
    /// stable case rather than by their title, which is a localized key and
    /// therefore not a usable dictionary key.
    @State private var collapsed: Set<Section> = []
    /// The shadow put aside by the hide button, so showing it again brings back
    /// the one you had rather than a stock one.
    @State private var hiddenShadow: Presentation.Shadow?
    /// Whether the margins are shown as four fields or as two. A way of
    /// looking at them, not a property of the document.
    @State private var marginsAreSplit = false
    /// Which margin field has the keyboard, if any.
    @State private var editedMargin: MarginShorthand.Target?
    /// What each kind of background held when it was last left. Session-scoped
    /// by design — see `BackgroundDrawers`.
    @State private var drawers = BackgroundDrawers()
    /// Whether the grid of effects to choose from is open.
    @State private var effectPickerIsOpen = false
    /// Which mesh corner the row below the plate acts on. Four corners, so no
    /// clamping machinery — just a number between 0 and 3.
    @State private var selectedCorner = 0
    /// Which gradient stop the row's controls act on. Held loosely: the list
    /// changes under it (a stop is added, removed, dragged elsewhere), so every
    /// read goes through `GradientStops.clampedSelection` rather than trusting
    /// the number.
    @State private var selectedStop = 0

    private enum Section: Hashable, CaseIterable {
        case background, effects, image, shadow, glow

        /// Kept on the case (and exposed through `sectionSystemImages`) so the
        /// SF Symbol availability test can reach these names.
        var systemImage: String {
            switch self {
            // Each one its own: the decor button already owns
            // `rectangle.center.inset.filled`, and a section repeating it made
            // the panel look like it was labelled twice.
            case .background: return "paintpalette"
            case .effects:    return "camera.filters"
            case .image:      return "photo"
            case .shadow:     return "square.filled.on.square"
            case .glow:       return "sun.max"
            }
        }
    }

    static var sectionSystemImages: [String] {
        Section.allCases.map(\.systemImage)
    }

    // MARK: Canvas formats

    /// Linear and radial are one background with a shape switch, not two
    /// entries in the list — the stops, the palette and the whole editor below
    /// are identical, and giving them separate tiles made the panel reflow for
    /// what is really one choice.
    private enum BackgroundKind: String, CaseIterable, Hashable, Identifiable {
        // Order is the order of the tiles: the two backgrounds you pick from
        // first, then the way out of having one at all.
        case solid, gradient, none

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .solid:    return "Solid"
            case .none:     return "No Background"
            case .gradient: return "Gradient"
            }
        }
    }

    /// A mesh is a gradient too — four colours instead of two, spread over the
    /// corners rather than along a line — so it belongs beside the other two
    /// rather than in the list of background kinds.
    private enum GradientShape: String, CaseIterable, Hashable, Identifiable {
        case linear, radial, mesh

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .linear: return "Linear"
            case .radial: return "Radial"
            case .mesh:   return "Mesh"
            }
        }
    }

    /// A round colour chip that opens the system colour panel.
    ///
    /// SwiftUI's `ColorPicker` draws a wide rectangular well whose width cannot
    /// be constrained: beside the round chips it read as a different kind of
    /// control, and a row of them pushed the inspector past its own maximum
    /// width. This is the same circle the annotation toolbar uses, so every
    /// colour in the app is picked from the same shape.
    /// Hands a colour to the system colour panel and takes the changes back.
    ///
    /// Order matters and so does ownership. `NSColorPanel` keeps an unowned
    /// target, and assigning its colour makes it fire the action straight away
    /// — so the target is installed first, and it is a process-wide object
    /// rather than a view's own state. A per-view proxy was deallocated as its
    /// chip re-rendered and the panel then messaged freed memory
    /// (EXC_BAD_ACCESS in objc_msgSend, measured from the crash report).
    static func openColorPanel(for color: Presentation.Color,
                               supportsOpacity: Bool = true,
                               onChange: @escaping (Presentation.Color) -> Void) {
        let panel = NSColorPanel.shared
        ColorPanelProxy.shared.onChange = onChange
        panel.setTarget(ColorPanelProxy.shared)
        panel.setAction(#selector(ColorPanelProxy.colorChanged(_:)))
        panel.showsAlpha = supportsOpacity
        panel.color = NSColor(srgbRed: color.red, green: color.green,
                              blue: color.blue, alpha: color.alpha)
        panel.makeKeyAndOrderFront(nil)
    }

    private struct ColorChip: View {
        let color: Presentation.Color
        var diameter: CGFloat
        var isSelected: Bool = false
        var supportsOpacity: Bool = true
        let onChange: (Presentation.Color) -> Void

        var body: some View {
            Button {
                PresentationInspector.openColorPanel(for: color,
                                                     supportsOpacity: supportsOpacity,
                                                     onChange: onChange)
            } label: {
                Circle()
                    .fill(Color(red: Double(color.red), green: Double(color.green),
                                blue: Double(color.blue), opacity: Double(color.alpha)))
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                    .overlay {
                        if isSelected {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(-3)
                        }
                    }
                    .frame(width: diameter, height: diameter)
            }
            .buttonStyle(.plain)
        }
    }

    /// The colour panel is a single shared window with one target, so the
    /// currently edited chip installs itself as that target on every click.
    private final class ColorPanelProxy: NSObject {
        /// One instance for the whole process: the panel's target is unowned,
        /// so it must outlive every chip that installs itself on it.
        static let shared = ColorPanelProxy()

        var onChange: ((Presentation.Color) -> Void)?

        @objc func colorChanged(_ sender: NSColorPanel) {
            guard let resolved = sender.color.usingColorSpace(.sRGB) else { return }
            onChange?(Presentation.Color(red: resolved.redComponent,
                                         green: resolved.greenComponent,
                                         blue: resolved.blueComponent,
                                         alpha: resolved.alphaComponent))
        }
    }

    private struct PaletteEntry: Identifiable {
        let id: String
        let titleKey: LocalizedStringKey
        let color: Presentation.Color
    }

    private static let palette: [PaletteEntry] = [
        PaletteEntry(id: "white", titleKey: "White", color: .white),
        PaletteEntry(id: "black", titleKey: "Black", color: .black),
        PaletteEntry(id: "graphite", titleKey: "Graphite",
                     color: Presentation.Color(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)),
        PaletteEntry(id: "sand", titleKey: "Sand",
                     color: Presentation.Color(red: 0.93, green: 0.89, blue: 0.85, alpha: 1)),
        PaletteEntry(id: "red", titleKey: "Red",
                     color: Presentation.Color(red: 0.92, green: 0.16, blue: 0.18, alpha: 1)),
        PaletteEntry(id: "orange", titleKey: "Orange",
                     color: Presentation.Color(red: 0.96, green: 0.47, blue: 0.08, alpha: 1)),
        PaletteEntry(id: "green", titleKey: "Green",
                     color: Presentation.Color(red: 0.22, green: 0.70, blue: 0.38, alpha: 1)),
        PaletteEntry(id: "blue", titleKey: "Blue",
                     color: Presentation.Color(red: 0.18, green: 0.43, blue: 0.92, alpha: 1))
    ]

    private struct BackgroundPreset: Identifiable {
        let id: String
        let background: Presentation.Background

        /// Which list this belongs to. Derived from the value rather than
        /// stated beside it: a preset that claimed one kind and carried another
        /// would put a gradient in the solid drawer.
        /// Which drawer inside `Gradient` — the three shapes are filtered the
        /// same way the kinds are, from the value itself.
        var shape: GradientShape {
            switch background {
            case .radialGradient: return .radial
            case .mesh:           return .mesh
            default:              return .linear
            }
        }

        var kind: BackgroundKind {
            switch background {
            case .none:                            return .none
            case .solid:                           return .solid
            case .linearGradient, .radialGradient,
                 .mesh:                            return .gradient
            }
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Presentation.Color {
        Presentation.Color(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    /// A fixed set, ours, not saveable — the point is to get a decent page in
    /// one click. Picking one writes an ordinary background value, so every
    /// control below keeps working on it: the preset is a starting point for
    /// this document, never a locked style.
    ///
    /// No solid here may equal a swatch in `palette` — the rule that
    /// `noPresetRepeatsAPaletteColor` keeps. Two grids of colour sit one above
    /// the other, and a tile that is pixel-for-pixel the circle below it makes
    /// the pair look like one list drawn twice rather than a shortcut above a
    /// vocabulary. `sand` and `graphite` used to be exactly that; they are the
    /// lighter `linen` and `charcoal` now, and the palette keeps the originals.
    private static let backgroundPresets: [BackgroundPreset] = {
        func linear(_ id: String, _ a: Presentation.Color, _ b: Presentation.Color) -> BackgroundPreset {
            BackgroundPreset(id: id,
                             background: .linearGradient(stops: Presentation.Stop.spread([a, b]),
                                                         angle: .pi / 2))
        }
        return [
            BackgroundPreset(id: "paper", background: .solid(rgb(0.97, 0.97, 0.96))),
            BackgroundPreset(id: "linen", background: .solid(rgb(0.96, 0.93, 0.87))),
            BackgroundPreset(id: "mist", background: .solid(rgb(0.87, 0.89, 0.92))),
            BackgroundPreset(id: "sage", background: .solid(rgb(0.84, 0.88, 0.83))),
            BackgroundPreset(id: "charcoal", background: .solid(rgb(0.17, 0.17, 0.19))),
            BackgroundPreset(id: "midnight", background: .solid(rgb(0.09, 0.11, 0.18))),
            BackgroundPreset(id: "clay", background: .solid(rgb(0.76, 0.55, 0.47))),
            BackgroundPreset(id: "denim", background: .solid(rgb(0.25, 0.38, 0.55))),
            linear("slate", rgb(0.20, 0.23, 0.29), rgb(0.07, 0.08, 0.11)),
            linear("ocean", rgb(0.26, 0.62, 0.85), rgb(0.09, 0.24, 0.51)),
            linear("violet", rgb(0.36, 0.35, 0.92), rgb(0.66, 0.33, 0.87)),
            linear("sunset", rgb(0.99, 0.60, 0.32), rgb(0.87, 0.24, 0.44)),
            linear("peach", rgb(0.99, 0.83, 0.72), rgb(0.97, 0.62, 0.60)),
            linear("mint", rgb(0.62, 0.93, 0.79), rgb(0.20, 0.63, 0.63)),
            linear("lemon", rgb(0.99, 0.90, 0.55), rgb(0.96, 0.70, 0.25)),
            linear("lavender", rgb(0.86, 0.83, 0.99), rgb(0.55, 0.50, 0.85)),
            BackgroundPreset(id: "rose", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.98, 0.78, 0.83), rgb(0.85, 0.36, 0.53)]))),
            BackgroundPreset(id: "deep", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.31, 0.36, 0.62), rgb(0.06, 0.07, 0.14)]))),
            BackgroundPreset(id: "amberGlow", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.99, 0.85, 0.55), rgb(0.85, 0.45, 0.15)]))),
            BackgroundPreset(id: "mintGlow", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.80, 0.98, 0.90), rgb(0.15, 0.50, 0.45)]))),
            BackgroundPreset(id: "violetGlow", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.80, 0.70, 0.99), rgb(0.30, 0.15, 0.55)]))),
            BackgroundPreset(id: "steel", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.85, 0.88, 0.92), rgb(0.35, 0.40, 0.48)]))),
            BackgroundPreset(id: "ember", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.99, 0.72, 0.55), rgb(0.55, 0.12, 0.15)]))),
            BackgroundPreset(id: "ink", background: .radialGradient(
                stops: Presentation.Stop.spread([rgb(0.45, 0.50, 0.60), rgb(0.05, 0.05, 0.09)]))),
            BackgroundPreset(id: "warmMesh", background: .mesh(colors: [
                rgb(0.99, 0.80, 0.55), rgb(0.97, 0.55, 0.44),
                rgb(0.85, 0.36, 0.53), rgb(0.99, 0.88, 0.72)])),
            BackgroundPreset(id: "coolMesh", background: .mesh(colors: [
                rgb(0.55, 0.79, 0.99), rgb(0.36, 0.45, 0.92),
                rgb(0.18, 0.63, 0.75), rgb(0.80, 0.90, 0.99)])),
            BackgroundPreset(id: "forestMesh", background: .mesh(colors: [
                rgb(0.72, 0.90, 0.65), rgb(0.30, 0.62, 0.42),
                rgb(0.16, 0.35, 0.28), rgb(0.88, 0.95, 0.80)])),
            BackgroundPreset(id: "duskMesh", background: .mesh(colors: [
                rgb(0.42, 0.33, 0.62), rgb(0.85, 0.45, 0.60),
                rgb(0.24, 0.20, 0.36), rgb(0.98, 0.75, 0.66)])),
            BackgroundPreset(id: "sunsetMesh", background: .mesh(colors: [
                rgb(0.99, 0.75, 0.45), rgb(0.95, 0.45, 0.35),
                rgb(0.60, 0.25, 0.55), rgb(0.99, 0.88, 0.70)])),
            BackgroundPreset(id: "auroraMesh", background: .mesh(colors: [
                rgb(0.55, 0.95, 0.85), rgb(0.35, 0.60, 0.95),
                rgb(0.65, 0.40, 0.95), rgb(0.85, 0.98, 0.95)])),
            BackgroundPreset(id: "sandMesh", background: .mesh(colors: [
                rgb(0.96, 0.92, 0.84), rgb(0.88, 0.80, 0.66),
                rgb(0.72, 0.62, 0.50), rgb(0.99, 0.97, 0.92)])),
            BackgroundPreset(id: "berryMesh", background: .mesh(colors: [
                rgb(0.95, 0.60, 0.75), rgb(0.70, 0.25, 0.55),
                rgb(0.35, 0.15, 0.45), rgb(0.99, 0.82, 0.88)]))
        ]
    }()

    /// The gallery's values, for the test that renders every one of them.
    static var backgroundPresetsForTesting: [Presentation.Background] {
        backgroundPresets.map(\.background)
    }

    /// The eight built-in swatches, for the test that keeps the gallery above
    /// them from repeating any of these.
    static var paletteColorsForTesting: [Presentation.Color] {
        palette.map(\.color)
    }

    private static let fallbackColor = Presentation.Color(
        red: 0.18, green: 0.43, blue: 0.92, alpha: 1
    )

    /// One row of eight, never two. Sized together with `contentMinimumWidth`.
    private static let swatchSize: CGFloat = 22
    private static let swatchGap: CGFloat = 6
    /// The square inside a section's action button.
    private static let sectionActionSize: CGFloat = 22

    init(document: EditorDocument, colorShelf: (any PresentationColorShelf)? = nil) {
        self.document = document
        self.colorShelf = colorShelf
        _draft = State(initialValue: document.presentation ?? .identity)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header
                backgroundSection
                effectsSection
                imageSection
                shadowSection
                glowSection
                removeButton
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: document.presentation) { _, presentation in
            draft = presentation ?? .identity
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Decor", systemImage: Self.decorSystemImage)
                .font(.title3.weight(.semibold))
            Text("Canvas and image presentation")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Background

    private var backgroundSection: some View {
        inspectorGroup("Background", section: .background) {
            tileGrid(BackgroundKind.allCases, selected: backgroundKind) { kind in
                backgroundTile(kind)
            } action: { kind in
                setBackgroundKind(kind)
            }

            if backgroundKind == .gradient { gradientShapePicker }

            presetGallery

            switch backgroundKind {
            case .none:
                Text("The canvas around the image stays transparent")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .solid:
                selectedColorRow(color: solidColor, onPick: { setSolidColor($0) }) {
                    saveToArchiveButton(color: solidColor)
                }
                swatchRow(selected: solidColor) { setSolidColor($0) }
            case .gradient:
                if gradientShape == .mesh {
                    meshCornerEditor
                } else {
                    stopEditor
                }
                // Always present, disabled for radial: linear and radial are two
                // modes of one thing, and the panel must not reflow when the
                // user flips between them.
                presentationSlider(
                    "Angle", id: "angle", systemImage: "angle",
                    value: gradientAngleBinding,
                    range: -180...180, step: 5,
                    unit: .degrees
                )
                .disabled(gradientShape != .linear)
                .opacity(gradientShape != .linear ? 0.4 : 1)
            }
        }
    }

    /// The ready-made pages, four to a row. Same painter as the tiles above and
    /// as the export, so nothing here promises a background the file would draw
    /// differently.
    /// The picture's own colours, shaped for whichever drawer is open: one
    /// colour for a solid page, two for a line or a ring, four for a mesh.
    ///
    /// It used to be a background kind of its own, which put the same four
    /// colours in a drawer where nothing else lived and left every other kind
    /// without them. As a preset it is simply the first thing in the row you
    /// are already looking at — and it stays an ordinary value, so the controls
    /// below keep working on it.
    private var sampledPreset: BackgroundPreset {
        let colors = sampledBackgroundColors()
        // The four quarters of a screenshot are usually near-identical window
        // chrome, so a gradient drawn between the lightest and the darkest of
        // them came out looking like a flat fill. A tint and a shade of the
        // shot's most characteristic colour keep its hue and actually read as
        // a gradient.
        let base = Self.characteristicColor(of: colors)
        let light = Self.mix(base, .white, amount: 0.30)
        let dark = Self.mix(base, .black, amount: 0.35)
        let background: Presentation.Background
        switch (backgroundKind, gradientShape) {
        case (.solid, _):
            background = .solid(base)
        case (.gradient, .radial):
            background = .radialGradient(stops: Presentation.Stop.spread([light, dark]))
        case (.gradient, .mesh):
            // Four near-identical quarters make a mesh that looks like a fill.
            // When the shot has no spread of its own, the corners are built
            // from its characteristic colour instead.
            background = .mesh(colors: Self.spread(colors) > 0.12
                               ? colors
                               : Self.meshColors(from: base))
        default:
            background = .linearGradient(stops: Presentation.Stop.spread([light, dark]), angle: .pi / 2)
        }
        return BackgroundPreset(id: "fromImage", background: background)
    }

    /// How far apart the sampled colours are — the largest gap between any two
    /// of them, on the same 0…1 scale as a channel.
    private static func spread(_ colors: [Presentation.Color]) -> CGFloat {
        var widest: CGFloat = 0
        for (index, a) in colors.enumerated() {
            for b in colors.dropFirst(index + 1) {
                widest = max(widest, abs(a.red - b.red)
                             + abs(a.green - b.green) + abs(a.blue - b.blue))
            }
        }
        return widest
    }

    /// The colour that says most about a picture: the one furthest from grey.
    /// Averaging instead pulls everything towards mud, and the lightest is
    /// usually just the window's background.
    private static func characteristicColor(of colors: [Presentation.Color]) -> Presentation.Color {
        func saturation(_ c: Presentation.Color) -> CGFloat {
            let high = max(c.red, max(c.green, c.blue))
            let low = min(c.red, min(c.green, c.blue))
            return high > 0 ? (high - low) / high : 0
        }
        guard let best = colors.max(by: { saturation($0) < saturation($1) }) else {
            return fallbackColor
        }
        guard saturation(best) > 0.08 else {
            // A grey shot: keep its lightness rather than inventing a hue.
            return colors.max { $0.red + $0.green + $0.blue < $1.red + $1.green + $1.blue }
                ?? fallbackColor
        }
        return best
    }

    private var gradientShapePicker: some View {
        Picker("", selection: gradientShapeBinding) {
            ForEach(GradientShape.allCases) { shape in
                Text(shape.titleKey).tag(shape)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
    }

    @ViewBuilder
    private var presetGallery: some View {
        // The kind above *is* the filter: a solid page offers solids, a
        // gradient offers gradients. Sorting them into one heap made the user
        // pick the kind twice — once in the tiles, once again by eye.
        // Two filters, one above the other: the kind, and — for gradients —
        // the shape, whose switch now sits over the gallery it narrows.
        // A transparent page has nothing to offer a gallery.
        let curated = backgroundKind == .none ? [] : Self.backgroundPresets.filter { preset in
            guard preset.kind == backgroundKind else { return false }
            guard backgroundKind == .gradient else { return true }
            return preset.shape == gradientShape
        }
        // The picture's own colours take the first slot rather than a ninth:
        // two rows of four is the shape of the row, and a lone tile on a third
        // line is not.
        let presets = curated.isEmpty ? [] : [sampledPreset] + curated.dropLast()
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: Self.captionGap) {
                Text("Presets")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                    spacing: 6
                ) {
                    ForEach(presets) { preset in
                        Button {
                            updateImmediately { $0.background = preset.background }
                        } label: {
                            backgroundSwatch(preset.background)
                                .overlay(alignment: .bottomTrailing) {
                                    if preset.id == "fromImage" {
                                        Image(systemName: "eyedropper")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .shadow(radius: 1)
                                            .padding(3)
                                    }
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(draft.background == preset.background
                                                      ? Color.accentColor
                                                      : Color.clear,
                                                      lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(preset.id == "fromImage" ? "From Image" : "Presets")
                        .accessibilityLabel(Text(preset.id == "fromImage" ? "From Image" : "Presets"))
                    }
                }
            }
        }
    }

    private func backgroundSwatch(_ background: Presentation.Background) -> some View {
        ZStack {
            checkerboard
            Canvas { context, size in
                context.withCGContext { cg in
                    PresentationRenderer.drawBackground(
                        background, in: CGRect(origin: .zero, size: size), ctx: cg
                    )
                }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
    }

    /// Painted by `PresentationRenderer`, not by a lookalike: what the tile
    /// shows is literally what the exported canvas would carry.
    private func backgroundTile(_ kind: BackgroundKind) -> some View {
        let sample = sampleBackground(for: kind)
        return VStack(spacing: 5) {
            ZStack {
                checkerboard
                Canvas { context, size in
                    context.withCGContext { cg in
                        PresentationRenderer.drawBackground(
                            sample,
                            in: CGRect(origin: .zero, size: size),
                            ctx: cg
                        )
                    }
                }
            }
            // 4:3 rather than a thin strip: a gradient's direction and a mesh's
            // spread are not readable in 30 points of height.
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
            Text(kind.titleKey)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Transparency has to look like transparency, otherwise "no background"
    /// and "white" are the same tile.
    private var checkerboard: some View {
        Canvas { context, size in
            let step: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: step, height: step)),
                            with: .color(Color(white: 0.85))
                        )
                    }
                    column += 1
                    x += step
                }
                row += 1
                y += step
            }
        }
    }

    /// The preview values for each tile. They are deliberately built from the
    /// current colors when the kind is already selected, so the tile doubles as
    /// a live thumbnail of what the user has configured.
    private func sampleBackground(for kind: BackgroundKind) -> Presentation.Background {
        switch kind {
        case .none:
            return .none
        case .solid:
            return .solid(backgroundKind == .solid ? solidColor : .white)
        case .gradient:
            if backgroundKind == .gradient {
                switch draft.background {
                case .mesh(let colors):          return .mesh(colors: colors)
                case .radialGradient(let stops): return .radialGradient(stops: stops)
                default: break
                }
            }
            return .linearGradient(stops: previewStops(for: .gradient), angle: .pi / 2)
        }
    }

    private func previewStops(for kind: BackgroundKind) -> [Presentation.Stop] {
        if backgroundKind == kind, !draft.background.stops.isEmpty {
            return draft.background.stops
        }
        return Presentation.Stop.spread(Self.defaultStops)
    }

    private static var defaultStops: [Presentation.Color] { BackgroundDrawers.defaultStops }

    /// The gradient's stops, on the ramp they belong to.
    ///
    /// Three rewrites, each answering the last one's complaint. It began acting
    /// on the end of the list whatever the user pointed at — "+" appended a
    /// darkened copy of the last colour, "−" took the last one away, a palette
    /// tap overwrote the last one, and order could not be changed at all. Then
    /// the stops became selectable, which reached the middle ones but left
    /// "order" as a separate idea to manipulate. Now they have positions, and
    /// order is simply where they sit: `GradientStopsBar` drags them, a tap on
    /// the ramp adds one where it landed, and the row below belongs to whichever
    /// is selected.
    private var stopEditor: some View {
        let stops = currentStops
        let selection = GradientStops.clampedSelection(selectedStop, in: stops)
        return VStack(alignment: .leading, spacing: 8) {
            GradientStopsBar(stops: stops,
                             selection: Binding(get: { selection },
                                                set: { selectedStop = $0 }),
                             apply: { setStops($0) })
            selectedStopRow(stops: stops, selection: selection)
            swatchRow(selected: stops.indices.contains(selection)
                      ? stops[selection].color : nil) {
                setSelectedStopColor($0)
            }
        }
    }

    /// What the selected stop is, and the two things you can do to it that the
    /// ramp itself cannot show: name a colour exactly, and take the stop away.
    /// "+" stays beside them because a bar you cannot click — a keyboard — still
    /// needs a way to add one.
    /// What the selected colour is, and the two things the plate or the ramp
    /// cannot show: name it exactly, and hand it to the system panel. Whatever
    /// else the surface offers — adding and removing stops, and nothing at all
    /// for a mesh's fixed four — rides along on the right.
    private func selectedColorRow<Trailing: View>(
        color: Presentation.Color,
        onPick: @escaping (Presentation.Color) -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            ColorChip(color: color, diameter: Self.swatchSize) { onPick($0) }
                .accessibilityLabel(Text("Color"))
            ColorField(color: color) { onPick($0) }
            Spacer(minLength: 0)
            trailing()
        }
        .controlSize(.large)
    }

    private func selectedStopRow(stops: [Presentation.Stop], selection: Int) -> some View {
        let color = stops.indices.contains(selection) ? stops[selection].color : .white
        return selectedColorRow(color: color) { picked in
            setStops(GradientStops.recolored(stops, at: selection, to: picked))
        } trailing: {
            Button {
                // Halfway to the next stop, or halfway to the end when the
                // selected one is last: the same "add a handle where there is
                // room" the ramp does under the pointer.
                setStops(GradientStops.inserted(into: stops, at: nextGap(in: stops, after: selection)))
                selectedStop = selection + 1
            } label: {
                Image(systemName: "plus")
            }
            .disabled(stops.count >= GradientStops.maximum)
            .help("Add Stop")
            .accessibilityLabel(Text("Add Stop"))
            Button {
                let remaining = GradientStops.removed(from: stops, at: selection)
                guard remaining != stops else { return }
                setStops(remaining)
                selectedStop = GradientStops.clampedSelection(selection, in: remaining)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(stops.count <= GradientStops.minimum)
            .help("Remove Stop")
            .accessibilityLabel(Text("Remove Stop"))
        }
        .controlSize(.large)
    }

    private func nextGap(in stops: [Presentation.Stop], after index: Int) -> CGFloat {
        guard stops.indices.contains(index) else { return 0.5 }
        let here = stops[index].location
        let next = stops.indices.contains(index + 1) ? stops[index + 1].location : 1
        return here + (next - here) / 2
    }

    private var swatchRowWidth: CGFloat {
        CGFloat(Self.palette.count) * Self.swatchSize
            + CGFloat(Self.palette.count - 1) * Self.swatchGap
    }

    /// A fixed single row — never a wrapping grid. If it does not fit, the
    /// inspector is too narrow and `contentMinimumWidth` is the thing to fix.
    /// The user's own colours follow the eight built-ins on a second row, which
    /// only appears once there is something to put on it.
    ///
    /// Captioned like "Presets" above it and "Corners" beside it, because
    /// without a word the two grids of colour read as one list that changed
    /// its mind about size: the gallery is a ready-made page, this is the
    /// palette a page is painted from.
    private func swatchRow(
        selected: Presentation.Color?,
        action: @escaping (Presentation.Color) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Self.captionGap) {
            Text("Colors")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: Self.swatchGap) {
                ForEach(Self.palette) { entry in
                    swatch(entry.color, selected: selected, label: entry.titleKey,
                           action: action)
                }
            }
            .frame(minWidth: swatchRowWidth, alignment: .leading)

            archiveRow(selected: selected, action: action)
        }
    }

    /// The colours the user has already collected — the archive's, live.
    ///
    /// A colour picked with the eyedropper is an archive entry, so it is
    /// already in a list the user keeps and can see from the panel. Repeating
    /// that list here is what turns the eyedropper into a way of choosing a
    /// background or a gradient stop, and it is why the inspector keeps no
    /// private palette of its own: a second list would be one to fill, prune
    /// and disagree with.
    @ViewBuilder
    private func archiveRow(
        selected: Presentation.Color?,
        action: @escaping (Presentation.Color) -> Void
    ) -> some View {
        let colors = colorShelf?.shelfColors ?? []
        if !colors.isEmpty {
            Divider()
            Text("From Archive")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // Adaptive, not an HStack: the archive holds up to fifty entries,
            // and they must wrap onto another line rather than push the
            // inspector past its own maximum width.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.swatchSize),
                                   spacing: Self.swatchGap,
                                   alignment: .leading)],
                alignment: .leading,
                spacing: Self.swatchGap
            ) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    swatch(color, selected: selected, label: "From Archive",
                           action: action)
                }
            }
        }
    }

    private func swatch(_ color: Presentation.Color,
                        selected: Presentation.Color?,
                        label: LocalizedStringKey,
                        action: @escaping (Presentation.Color) -> Void) -> some View {
        // Circles, the same chip the annotation toolbar uses — one shape for
        // every colour in the app.
        Button { action(color) } label: {
            Circle()
                .fill(swiftUIColor(color))
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                .overlay {
                    if selected == color {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .frame(width: Self.swatchSize, height: Self.swatchSize)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Keeps the colour on screen in the archive, beside the ones the
    /// eyedropper put there. The row it sits on already says which colour that
    /// is — the swatch and the hex field — so the button needs no label of its
    /// own, and it sits on the right edge like every other action here.
    private func saveToArchiveButton(color: Presentation.Color) -> some View {
        Button {
            colorShelf?.addShelfColor(color)
        } label: {
            Image(systemName: "plus")
        }
        .disabled(colorShelf == nil)
        .help("Save Color to Archive")
        .accessibilityLabel(Text("Save Color to Archive"))
    }


    /// A mesh is four corner colours, and now the panel shows them where they
    /// are. It began as a single seed the app spread into four by mixing with
    /// white and black — choosing one felt like guessing what would come out
    /// the other end — and then as a bare row of four chips, which said the
    /// colours but not which corner each belonged to, so nothing else in the
    /// panel could act on "the one you mean". A corner cannot move, so there is
    /// no dragging and nothing to add or remove; everything else is the stop
    /// bar's language.
    private var meshCornerEditor: some View {
        let corners = meshCorners
        let selection = min(max(0, selectedCorner), 3)
        return VStack(alignment: .leading, spacing: 8) {
            MeshCornersPlate(colors: corners,
                             selection: Binding(get: { selection },
                                                set: { selectedCorner = $0 }),
                             apply: { setMeshColors($0) })
            selectedColorRow(color: corners[selection]) { picked in
                setMeshCorner(picked, at: selection)
            }
            swatchRow(selected: corners[selection]) { setMeshCorner($0, at: selection) }
        }
    }

    private func setMeshColors(_ colors: [Presentation.Color]) {
        updateImmediately { $0.background = .mesh(colors: colors) }
    }

    private func setMeshCorner(_ color: Presentation.Color, at index: Int) {
        var colors = meshCorners
        guard colors.indices.contains(index) else { return }
        colors[index] = color
        setMeshColors(colors)
    }

    private var meshCorners: [Presentation.Color] {
        if case .mesh(let colors) = draft.background, colors.count >= 4 { return colors }
        return Self.meshCorners(from: draft.background.colors)
    }

    /// Two stops spread over four corners: the ends keep their colours and the
    /// other two are the blend, so switching from a line to a mesh keeps what
    /// the user had rather than starting over.
    static func meshCorners(from colors: [Presentation.Color]) -> [Presentation.Color] {
        BackgroundDrawers.meshCorners(from: colors)
    }



    // MARK: Effects

    /// The stack, Figma's shape: a row per effect, its parameters beneath it,
    /// and one button that adds another. Order is meaningful — filters do not
    /// commute — so rows can be dragged past each other.
    ///
    /// The section is deliberately not a switch with one set of controls. Two
    /// grains of different sizes is a legitimate thing to ask for, and any
    /// design where an effect is a property rather than a member of a list
    /// cannot say it.
    private var effectsSection: some View {
        inspectorGroup("Effects", section: .effects) {
            ForEach(draft.effects) { effect in
                effectRow(effect)
            }
            HStack(spacing: 8) {
                if draft.effects.isEmpty {
                    // An empty section that says nothing looks broken; this is
                    // the one line that says what the button is for.
                    Text("Grain, texture and other treatments of the background")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                sectionActionButton("plus", label: "Add Effect") {
                    effectPickerIsOpen = true
                }
                .popover(isPresented: $effectPickerIsOpen, arrowEdge: .bottom) {
                    effectPicker
                }
            }
        }
    }

    /// The grid behind the "+": every kind, drawn on the background it would
    /// land on, with the stack that is already there underneath it.
    ///
    /// That is what makes a tile honest rather than decorative — and it also
    /// tells the truth about the awkward ones. Pixelate and glass have nothing
    /// to work on over a bare gradient, so their tiles show almost nothing, and
    /// so would the page. An effect that needs a texture under it is a fact
    /// about the effect, not something a stock sample should hide.
    private var effectPicker: some View {
        ScrollView {
            tileGrid(Presentation.Effect.Kind.allCases, selected: nil) { kind in
                effectTile(kind)
            } action: { kind in
                addEffect(kind)
                effectPickerIsOpen = false
            }
            .padding(10)
        }
        .frame(width: 300, height: 340)
    }

    private func effectTile(_ kind: Presentation.Effect.Kind) -> some View {
        let stack = draft.effects + [EffectStack.make(kind, seed: 5)]
        return VStack(spacing: 5) {
            Canvas { context, size in
                context.withCGContext { cg in
                    PresentationRenderer.drawBackground(
                        draft.background, effects: stack,
                        in: CGRect(origin: .zero, size: size), ctx: cg
                    )
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary, lineWidth: 1))
            // The name alone: the picture above it already says what the
            // effect is, and the glyph beside it cost enough width to truncate
            // "Pixelate" in three columns.
            Text(LocalizedStringKey(EffectStack.title(for: kind)))
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func effectRow(_ effect: Presentation.Effect) -> some View {
        VStack(alignment: .leading, spacing: Self.captionGap) {
            HStack(spacing: 8) {
                effectPreview(effect)
                Text(LocalizedStringKey(EffectStack.title(for: effect.kind)))
                    .font(.system(size: 11))
                Spacer(minLength: 0)
                // Hide rather than delete, exactly as the shadow does: an
                // effect switched off keeps its numbers, so turning it back on
                // returns the one you had.
                effectRowButton(effect.isEnabled ? "eye" : "eye.slash",
                                label: effect.isEnabled ? "Hide Effect" : "Show Effect") {
                    setEffect(effect) { $0.isEnabled.toggle() }
                }
                effectRowButton("xmark", label: "Remove Effect") {
                    removeEffect(effect)
                }
            }
            ForEach(EffectStack.parameters(for: effect.kind), id: \.parameter) { info in
                if info.parameter == .color {
                    effectColorRow(effect, info)
                } else {
                    presentationSlider(
                        LocalizedStringKey(info.titleKey),
                        id: "effect-\(effect.id)-\(info.parameter.rawValue)",
                        systemImage: info.systemImage,
                        value: effectBinding(effect, info.parameter),
                        range: info.range,
                        step: info.step,
                        unit: Self.unit(for: info, canvasSize: canvasSize)
                    )
                }
            }
        }
        .opacity(effect.isEnabled ? 1 : 0.5)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Identity, not geometry: a row knows its own index, so dropping on it
        // needs no arithmetic about row heights — and the rows here are not
        // even the same height, since each kind brings its own sliders.
        .draggable(effect.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first,
                  let from = draft.effects.firstIndex(where: { $0.id.uuidString == dragged }),
                  let to = draft.effects.firstIndex(where: { $0.id == effect.id })
            else { return false }
            moveEffect(from: from, to: to)
            return true
        }
    }

    /// A colour is not a number, so it gets the panel's colour controls rather
    /// than a slider — the same chip and the same typed field as the shadow's
    /// colour, in the same notation the rest of the app uses.
    private func effectColorRow(_ effect: Presentation.Effect,
                                _ info: EffectStack.ParameterInfo) -> some View {
        VStack(alignment: .leading, spacing: Self.captionGap) {
            Text(LocalizedStringKey(info.titleKey))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ColorChip(color: effect.color, diameter: Self.swatchSize,
                          supportsOpacity: false) { color in
                    setEffect(effect) { $0.color = color }
                }
                .accessibilityLabel(Text(LocalizedStringKey(info.titleKey)))
                ColorField(color: effect.color) { color in
                    setEffect(effect) { $0.color = color }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The row's own small buttons — plain, because two bordered squares beside
    /// a name read as a toolbar rather than as the ends of a row.
    private func effectRowButton(_ systemImage: String,
                                 label: LocalizedStringKey,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    /// The effect on the background it is actually sitting on, drawn by the
    /// routine that draws the canvas — a swatch that made its own picture could
    /// promise something the page would not deliver.
    private func effectPreview(_ effect: Presentation.Effect) -> some View {
        // Drawn as if switched on, even while it is off: the swatch answers
        // "what would come back", and a switched-off row whose swatch showed
        // the plain background said nothing about what it was hiding.
        var shown = effect
        shown.isEnabled = true
        return Canvas { context, size in
            context.withCGContext { cg in
                let rect = CGRect(origin: .zero, size: size)
                PresentationRenderer.drawBackground(draft.background, effects: [shown],
                                                    in: rect, ctx: cg)
            }
        }
        .frame(width: 28, height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        .accessibilityHidden(true)
    }

    /// `scale` is a fraction of the short side, so the field beside the slider
    /// can show it in the pixels it will actually be.
    private static func unit(for info: EffectStack.ParameterInfo,
                             canvasSize: CGSize) -> ValueUnit {
        switch info.parameter {
        case .scale:
            return .pixels(basis: min(canvasSize.width, canvasSize.height))
        case .angle:
            return .degrees
        case .amount, .color:
            return .percent
        }
    }

    /// Position is edited on the object, not on a slider: the four fields are
    /// the *measured* gaps between picture and canvas, and the buttons snap it
    /// to an edge or the middle.
    private var imageSection: some View {
        inspectorGroup("Image", section: .image) {
            alignmentRow
            gapGrid
            presentationSlider(
                "Corner Radius", id: "cornerRadius", systemImage: "rectangle",
                value: cornerRadiusBinding,
                range: 0...0.5, step: 0.005,
                unit: .pixels(basis: min(canvasSize.width, canvasSize.height))
            )
        }
    }

    private var alignmentRow: some View {
        HStack(spacing: 6) {
            ForEach(Alignment.allCases) { item in
                Button { align(item) } label: {
                    Image(systemName: item.systemImage)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help(item.titleKey)
                .accessibilityLabel(item.titleKey)
            }
        }
    }

    /// The four margins as two fields — one per axis — with a button that opens
    /// them into four.
    ///
    /// The shape of the fields *is* the explanation: the field you type into is
    /// the thing you are setting, and the glyph inside it says which sides that
    /// is. Three earlier tries changed an invisible rule instead and left the
    /// same four fields standing: a cross around a plate that meant nothing to
    /// anyone, driven first by keyboard modifiers that could not work at all
    /// (no modifier can be held while digits are typed) and then by a button in
    /// the middle whose two states said nothing about what typing would do.
    ///
    /// The caption carries the unit for all of them: a "px" in every field says
    /// the same thing four times, in the one place on the panel where there is
    /// no room to say anything.
    private var gapGrid: some View {
        let gaps = PresentationLayout.gaps(resolvedLayout)
        let margins = Presentation.Margins(top: gaps.top, leading: gaps.leading,
                                           bottom: gaps.bottom, trailing: gaps.trailing)
        return VStack(alignment: .leading, spacing: Self.captionGap) {
            Text("Margins, px")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Self.marginGap) {
                if marginsAreSplit {
                    VStack(spacing: Self.marginGap) {
                        HStack(spacing: Self.marginGap) {
                            gapField(.side(.top), of: margins)
                            gapField(.side(.bottom), of: margins)
                        }
                        HStack(spacing: Self.marginGap) {
                            gapField(.side(.leading), of: margins)
                            gapField(.side(.trailing), of: margins)
                        }
                    }
                } else {
                    HStack(spacing: Self.marginGap) {
                        gapField(.vertical, of: margins)
                        gapField(.horizontal, of: margins)
                    }
                }
                splitMarginsButton
            }
        }
    }

    /// Opens the two axis fields into four, one per side, and closes them
    /// again. Figma's own control, and for its reason: two fields are what the
    /// margins usually are, four is what they sometimes need to be, and the
    /// button is the only thing on screen that has to be learned.
    private var splitMarginsButton: some View {
        Button {
            marginsAreSplit.toggle()
        } label: {
            Image(systemName: marginsAreSplit
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11))
                .frame(width: 26, height: 30)
                // The hit area is the frame, not the glyph. A label that is
                // only a stroked shape takes clicks on the stroke alone, which
                // is how the last button here came to look broken.
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!marginsAreFree)
        .help(marginsAreSplit ? "Join Margins" : "Split Margins")
        .accessibilityLabel(Text(marginsAreSplit ? "Join Margins" : "Split Margins"))
    }

    private func gapField(_ target: MarginShorthand.Target,
                          of margins: Presentation.Margins) -> some View {
        let values = MarginShorthand.values(for: target, of: margins).map { Double($0) }
        return HStack(spacing: 4) {
            Image(systemName: Self.marginSymbol(target))
                .font(.system(size: 10))
                // The glyph is the only thing that tells these fields apart,
                // so it is also where the field says it has the keyboard.
                .foregroundStyle(editedMargin == target ? AnyShapeStyle(.tint)
                                 : AnyShapeStyle(.secondary))
            NumberField(values: Binding<[Double]>.constant(values),
                        alignment: .center,
                        onCommit: { (typed: [Double]) in
                setGap(target, to: typed.map { CGFloat($0) }, from: margins)
            }, onEditingChange: { editing in
                editedMargin = editing ? target : (editedMargin == target ? nil : editedMargin)
            })
            // SwiftUI writes the environment's control size onto the wrapped
            // NSControl, so a field outside a `.large` container is reset to
            // the regular one — 22 points against the canvas row's 30.
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .help(Self.marginTitle(target))
        .accessibilityLabel(Self.marginTitle(target))
    }

    /// A rectangle with the sides the field stands for picked out — the same
    /// idea as the little squares in Figma's padding fields, and the reason a
    /// glyph belongs *inside* the field rather than on a button beside it.
    static func marginSymbol(_ target: MarginShorthand.Target) -> String {
        switch target {
        case .vertical:          return "rectangle.split.1x2"
        case .horizontal:        return "rectangle.split.2x1"
        case .side(.top):        return "rectangle.tophalf.inset.filled"
        case .side(.bottom):     return "rectangle.bottomhalf.inset.filled"
        case .side(.leading):    return "rectangle.lefthalf.inset.filled"
        case .side(.trailing):   return "rectangle.righthalf.inset.filled"
        }
    }

    static func marginTitle(_ target: MarginShorthand.Target) -> LocalizedStringKey {
        switch target {
        case .vertical:        return "Top and Bottom Margins"
        case .horizontal:      return "Left and Right Margins"
        case .side(let edge):  return gapTitle(edge)
        }
    }

    private static func gapTitle(_ edge: PresentationLayout.Edge) -> LocalizedStringKey {
        switch edge {
        case .top:      return "Top Margin"
        case .leading:  return "Left Margin"
        case .bottom:   return "Bottom Margin"
        case .trailing: return "Right Margin"
        }
    }

    private var resolvedLayout: PresentationLayout.Resolved {
        PresentationLayout.resolve(imagePixelSize: document.pixelSize, draft)
    }

    /// The field's door into `EditorDocument.setGap`. The document owns the
    /// rule — the canvas drags the same sides — and what stays here is what
    /// belongs to the fields alone: how far one typed number reaches.
    /// The fields' door into `EditorDocument.setGap`. The document owns the
    /// rule — the canvas drags the same sides — and what belongs to the fields
    /// alone is how a typed list maps onto the four margins.
    private func setGap(_ target: MarginShorthand.Target, to values: [CGFloat],
                        from margins: Presentation.Margins) {
        let updated = MarginShorthand.applied(values, from: target, to: margins)
        guard updated != margins else { return }
        document.beginChange()
        // One Return is one undo step however many sides it reached.
        for edge in PresentationLayout.Edge.allCases where updated[edge] != margins[edge] {
            document.setGap(edge, to: updated[edge])
        }
        document.commitChange()
        draft = document.presentation ?? draft
    }

    private var marginsAreFree: Bool {
        if case .auto = draft.canvas { return true }
        return false
    }

    private enum Alignment: String, CaseIterable, Identifiable {
        case left, centerX, right, top, centerY, bottom

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .left:    return "align.horizontal.left"
            case .centerX: return "align.horizontal.center"
            case .right:   return "align.horizontal.right"
            case .top:     return "align.vertical.top"
            case .centerY: return "align.vertical.center"
            case .bottom:  return "align.vertical.bottom"
            }
        }

        var titleKey: LocalizedStringKey {
            switch self {
            case .left:    return "Align Left"
            case .centerX: return "Center Horizontally"
            case .right:   return "Align Right"
            case .top:     return "Align Top"
            case .centerY: return "Center Vertically"
            case .bottom:  return "Align Bottom"
            }
        }
    }

    static var alignmentSystemImages: [String] {
        Alignment.allCases.map(\.systemImage)
    }

    /// Aligning is a move, so it keeps the page and trades margins — the same
    /// rule a drag follows. On an auto page that means writing the margins
    /// themselves; on a fixed one, the placement. Sending it only to the
    /// placement left the buttons dead on an auto page, where the resolver
    /// reads margins and ignores placement entirely.
    private func align(_ alignment: Alignment) {
        let layout = resolvedLayout
        let canvas = layout.canvasSize
        let picture = layout.imageRect.size
        guard canvas.width > 0, canvas.height > 0 else { return }

        if case .auto(var margins, let scale) = draft.canvas {
            let slackX = canvas.width - picture.width
            let slackY = canvas.height - picture.height
            switch alignment {
            case .left:    margins.leading = 0;          margins.trailing = slackX
            case .centerX: margins.leading = slackX / 2; margins.trailing = slackX / 2
            case .right:   margins.leading = slackX;     margins.trailing = 0
            case .top:     margins.top = 0;              margins.bottom = slackY
            case .centerY: margins.top = slackY / 2;     margins.bottom = slackY / 2
            case .bottom:  margins.top = slackY;         margins.bottom = 0
            }
            guard case .auto(let old, _) = draft.canvas, old != margins else { return }
            updateImmediately { $0.canvas = .auto(margins: margins, scale: scale) }
            return
        }

        let half = CGSize(width: picture.width / 2, height: picture.height / 2)
        var placement = draft.image
        switch alignment {
        case .left:    placement.center.x = half.width / canvas.width
        case .centerX: placement.center.x = 0.5
        case .right:   placement.center.x = 1 - half.width / canvas.width
        case .top:     placement.center.y = half.height / canvas.height
        case .centerY: placement.center.y = 0.5
        case .bottom:  placement.center.y = 1 - half.height / canvas.height
        }
        guard placement != draft.image else { return }
        updateImmediately { $0.image = placement }
    }

    /// One shape for every section: a title and its controls. The shadow used
    /// to hide behind a switch, which made it the only part of the panel you
    /// had to turn on before you could see it — zero opacity says the same
    /// thing and says it in the same place as everything else.
    private var shadowSection: some View {
        inspectorGroup("Shadow", section: .shadow) {
            presentationSlider(
                "Shadow Radius", id: "shadowRadius", systemImage: "circle.dotted",
                value: shadowRadiusBinding,
                range: 0...0.25, step: 0.005,
                unit: .pixels(basis: max(canvasSize.width, canvasSize.height))
            )
            presentationSlider(
                "Shadow Opacity", id: "shadowOpacity", systemImage: "circle.lefthalf.filled",
                value: shadowOpacityBinding,
                range: 0...1, step: 0.01,
                unit: .percent
            )
            presentationSlider(
                "Shadow Offset X", id: "shadowOffsetX", systemImage: "arrow.left.and.right",
                value: shadowOffsetXBinding,
                range: -0.1...0.1, step: 0.005,
                unit: .pixels(basis: canvasSize.width)
            )
            presentationSlider(
                "Shadow Offset Y", id: "shadowOffsetY", systemImage: "arrow.up.and.down",
                value: shadowOffsetYBinding,
                range: -0.1...0.1, step: 0.005,
                unit: .pixels(basis: canvasSize.height)
            )
            // The caption sits above its controls, like "Presets", "Colors"
            // and "From Archive" — the sliders in this section put their names
            // on the left because a slider has no room above it, which is not
            // a reason for a colour row to do the same.
            //
            // In its own stack, and that is the whole point of the stack: a
            // caption left as a sibling of the row inherits the section's
            // spacing between *controls* (14), so it floated twice as far from
            // what it names as every other caption in the panel does.
            VStack(alignment: .leading, spacing: Self.captionGap) {
                Text("Shadow Color")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ColorChip(color: draft.shadow.color, diameter: Self.swatchSize,
                              supportsOpacity: false) { setShadowColor($0) }
                        .accessibilityLabel(Text("Shadow Color"))
                    ColorField(color: draft.shadow.color) { setShadowColor($0) }
                    Spacer(minLength: 0)
                    // Same corner, same button as the canvas rotate: the section's
                    // one whole-block action. It hides rather than resets — the
                    // radius and the offset survive the round trip, so turning the
                    // shadow back on returns the one you had.
                    sectionActionButton(shadowIsVisible ? "eye" : "eye.slash",
                                        label: shadowIsVisible ? "Hide Shadow" : "Show Shadow") {
                        toggleShadow()
                    }
                }
            }
            .font(.system(size: 11))
        }
    }

    /// Light from behind the picture — the same drawing as the shadow, and a
    /// section of its own because the two are wanted together: depth below,
    /// colour all round.
    private var glowSection: some View {
        inspectorGroup("Glow", section: .glow) {
            presentationSlider(
                "Glow Radius", id: "glowRadius", systemImage: "circle.dotted",
                value: glowRadiusBinding,
                range: 0...0.25, step: 0.005,
                unit: .pixels(basis: max(canvasSize.width, canvasSize.height))
            )
            presentationSlider(
                "Glow Opacity", id: "glowOpacity", systemImage: "circle.lefthalf.filled",
                value: glowOpacityBinding,
                range: 0...1, step: 0.01,
                unit: .percent
            )
            VStack(alignment: .leading, spacing: Self.captionGap) {
                Text("Glow Color")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ColorChip(color: draft.glow.color, diameter: Self.swatchSize,
                              supportsOpacity: false) { color in
                        updateImmediately { $0.glow.color = color }
                    }
                    .accessibilityLabel(Text("Glow Color"))
                    ColorField(color: draft.glow.color) { color in
                        updateImmediately { $0.glow.color = color }
                    }
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 11))
        }
    }

    private var glowRadiusBinding: Binding<CGFloat> {
        Binding(get: { draft.glow.radius }, set: { value in
            updateLive { $0.glow.radius = value }
        })
    }

    private var glowOpacityBinding: Binding<CGFloat> {
        Binding(get: { draft.glow.opacity }, set: { value in
            updateLive { $0.glow.opacity = value }
        })
    }

    /// Throwing the decoration away is the one thing in this panel that undoes
    /// everything else, so it gets the weight of a real button rather than a
    /// line of tinted text that reads as a caption. It keeps the destructive
    /// role, which is what makes it red, and a rule above it so it is plainly
    /// not part of the last section.
    private var removeButton: some View {
        VStack(spacing: Self.sectionSpacing) {
            Divider()
            Button(role: .destructive) {
                removePresentation()
            } label: {
                Label("Remove Decor", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(document.presentation == nil)
        }
    }

    // MARK: Building blocks

    /// A section's one whole-block action, in the trailing corner of its last
    /// row: rotate for the canvas, hide/show for the shadow. One builder, so
    /// the two are the same button rather than two buttons that happen to look
    /// alike — they sit in rows with different fonts, and inheriting those made
    /// them different sizes.
    private func sectionActionButton(
        _ systemImage: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: Self.sectionActionSize, height: Self.sectionActionSize)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(label)
        .accessibilityLabel(Text(label))
    }

    /// The group's own title is the only title: the controls inside carry no
    /// repeated label, so "Canvas / Canvas" and "Background / Background" are
    /// gone. The title is also the fold control — the whole header row is the
    /// hit target, not just the chevron, because the row is what reads as
    /// clickable at this size.
    private func inspectorGroup<Content: View>(
        _ title: LocalizedStringKey,
        section: Section,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isExpanded = !collapsed.contains(section)
        // A collapsed section is the header alone. Keeping an empty GroupBox
        // around would leave its container — padding and all — visible under
        // the title, which reads as a rendering fault rather than as a folded
        // section.
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isExpanded { collapsed.insert(section) }
                    else { collapsed.remove(section) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(title).font(.headline)
                    Spacer(minLength: 0)
                    // Trailing, where a disclosure control belongs once the row
                    // opens with an icon of its own.
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                // The whole row is the target, and it is tall enough to hit
                // without aiming: a 13pt headline alone is a 16pt-high strip.
                .frame(minHeight: 28)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                GroupBox {
                    VStack(alignment: .leading, spacing: Self.controlSpacing) {
                        content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Self.groupPadding)
                }
            }
        }
    }

    private func tileGrid<Choice: Identifiable & Hashable, Tile: View>(
        _ choices: [Choice],
        selected: Choice?,
        @ViewBuilder tile: @escaping (Choice) -> Tile,
        action: @escaping (Choice) -> Void
    ) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(choices) { choice in
                Button { action(choice) } label: {
                    tile(choice)
                        .padding(5)
                        .frame(maxWidth: .infinity)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selected == choice
                                      ? Color.accentColor.opacity(0.16)
                                      : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selected == choice
                                              ? Color.accentColor
                                              : Color.clear,
                                              lineWidth: 1.5)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// How a control's number is written down. The unit lives *inside* the
    /// field — "28%" — rather than as a caption beside it, so every field in
    /// the panel is the same width and their right edges line up. A trailing
    /// "px" caption pushed each field left by a different amount depending on
    /// the unit's own width.
    private enum ValueUnit {
        /// A canvas fraction shown as pixels of `basis` — the same length the
        /// renderer multiplies that fraction by.
        case pixels(basis: CGFloat)
        case percent
        case degrees
    }

    /// One width for every number in the panel — canvas size, margins, slider
    /// values. They sit in different rows, and different widths made them read
    /// as different kinds of control.
    ///
    /// 100 is what the tightest row allows at the inspector's own minimum
    /// width: the canvas row carries two of them plus the × and the rotate
    /// button, and the margins carry two plus the picture's stand-in.
    private static let numberFieldWidth: CGFloat = 100
    /// The panel's rhythm, in one place: between sections, and between the
    /// controls inside one.
    private static let sectionSpacing: CGFloat = 16
    private static let controlSpacing: CGFloat = 14
    /// Between a caption and the thing it names. Every caption in the panel —
    /// "Presets", "Colors", "From Archive", "Corners", "Margins, px" — sits
    /// this far above its controls, and the shadow's colour drifted to the
    /// section's own control spacing until it was given a stack of its own.
    private static let captionGap: CGFloat = 6
    /// Between the margin fields and the button beside them.
    private static let marginGap: CGFloat = 6
    /// Breathing room inside a section's box, on top of what `GroupBox` gives.
    /// Its own inset is about half of what the app's settings cards use, and
    /// beside them the panel looked cramped rather than compact.
    private static let groupPadding: CGFloat = 8

    /// A slider **and** a typed field for the same number.
    ///
    /// The stored value stays normalized to the canvas — that is what keeps a
    /// decoration meaningful when the format changes — but nobody thinks in
    /// "6% of the long side", so the field converts.
    @ViewBuilder
    private func presentationSlider(
        _ title: LocalizedStringKey,
        id: String,
        systemImage: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        unit: ValueUnit
    ) -> some View {
        let snapped = Binding<CGFloat>(
            get: { value.wrappedValue },
            set: { raw in
                let detents = ((raw - range.lowerBound) / step).rounded()
                value.wrappedValue = min(
                    range.upperBound,
                    max(range.lowerBound, range.lowerBound + detents * step)
                )
            }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                valueField(value: value, range: range, unit: unit, id: id)
            }
            Slider(value: snapped, in: range, onEditingChanged: sliderEditingChanged)
        }
    }

    private func valueField(value: Binding<CGFloat>,
                            range: ClosedRange<CGFloat>,
                            unit: ValueUnit,
                            id: String) -> some View {
        let commit: (CGFloat) -> Void = { fraction in
            let clamped = min(range.upperBound, max(range.lowerBound, fraction))
            guard clamped != value.wrappedValue else { return }
            document.beginChange()
            value.wrappedValue = clamped
            document.commitChange()
        }
        let shown: Double
        switch unit {
        case .pixels(let basis): shown = (Double(value.wrappedValue) * Double(basis)).rounded()
        case .percent:           shown = (Double(value.wrappedValue) * 100).rounded()
        case .degrees:           shown = Double(value.wrappedValue.rounded())
        }
        return NumberField(value: .constant(shown)) { typed in
            switch unit {
            case .pixels(let basis):
                guard basis != 0 else { return }
                commit(CGFloat(typed) / basis)
            case .percent:
                commit(CGFloat(typed) / 100)
            case .degrees:
                commit(CGFloat(typed))
            }
        }
        .controlSize(.large)
        .frame(width: Self.numberFieldWidth)
    }

    private func sliderEditingChanged(_ editing: Bool) {
        if editing { document.beginChange() }
        else { document.commitChange() }
    }

    // MARK: Canvas state

    /// Which format the page currently is — nil when it is a size of your own,
    /// or when the margins are free and there is no fixed size at all. Nothing
    /// is highlighted then, which is the truth.
    /// A transparent shadow is a shadow that is not there — the section needs no
    /// separate switch to say so.
    var shadowIsVisible: Bool { draft.shadow.opacity > 0 }

    /// What the hide button turns *on* when there is nothing to bring back: a
    /// soft drop sitting slightly below the picture. Restoring only the opacity
    /// of an all-zero shadow would leave the button looking broken.
    static let defaultVisibleShadow = Presentation.Shadow(
        radius: 0.05, offset: CGPoint(x: 0, y: 0.02), opacity: 0.35)

    /// Hides the shadow without forgetting it, or brings it back.
    func toggleShadow() {
        let (shadow, remembered) = Self.shadowToggled(draft.shadow, remembered: hiddenShadow)
        hiddenShadow = remembered
        updateImmediately { $0.shadow = shadow }
    }

    /// The whole hide/show step as one value: the shadow to apply, and what to
    /// put aside for the next press.
    ///
    /// The colour never takes part in the round trip — it is the one shadow
    /// setting still worth changing while the shadow is hidden, so bringing the
    /// shadow back keeps whatever colour is current rather than the old one.
    static func shadowToggled(_ shadow: Presentation.Shadow,
                              remembered: Presentation.Shadow?)
    -> (shadow: Presentation.Shadow, remembered: Presentation.Shadow?) {
        if shadow.opacity > 0 {
            var hidden = shadow
            hidden.opacity = 0
            return (hidden, shadow)
        }
        var shown = shadow
        if let remembered {
            shown.radius = remembered.radius
            shown.offset = remembered.offset
            shown.opacity = remembered.opacity
        }
        // A shadow that is transparent or has no blur is still invisible, which
        // would make the button look broken on a document that never had one.
        if shown.opacity <= 0 { shown.opacity = defaultVisibleShadow.opacity }
        if shown.radius <= 0 { shown.radius = defaultVisibleShadow.radius }
        return (shown, nil)
    }

    /// Turns the canvas a quarter, keeping the same format selected.
    private var canvasSize: CGSize {
        resolvedLayout.canvasSize
    }

    // MARK: Background state

    private var backgroundKind: BackgroundKind {
        switch draft.background {
        case .none:           return .none
        case .solid:          return .solid
        case .linearGradient,
             .radialGradient,
             .mesh:           return .gradient
        }
    }

    private func setBackgroundKind(_ kind: BackgroundKind) {
        switch kind {
        case .none:
            drawers.keep(draft.background)
            updateImmediately { $0.background = .none }
        case .solid:
            switchBackground(to: .solid)
        case .gradient:
            // Back to the gradient you were last in, not to a linear one you
            // may never have chosen.
            switchBackground(to: drawers.lastGradient)
        }
    }

    /// Moving between the four drawers puts back what was in the one you are
    /// entering and keeps what was in the one you are leaving — the rules, and
    /// the reason for them, are in `BackgroundDrawers`.
    private func switchBackground(to drawer: BackgroundDrawers.Drawer) {
        guard BackgroundDrawers.drawer(of: draft.background) != drawer else { return }
        var drawers = self.drawers
        let next = drawers.switching(from: draft.background, to: drawer,
                                     angle: currentGradientAngle)
        self.drawers = drawers
        updateImmediately { $0.background = next }
    }

    private var solidColor: Presentation.Color {
        guard case .solid(let color) = draft.background else { return .white }
        return color
    }

    private var solidColorBinding: Binding<SwiftUI.Color> {
        Binding(
            get: { swiftUIColor(solidColor) },
            set: { setSolidColor(presentationColor($0)) }
        )
    }

    private var meshSeedBinding: Binding<SwiftUI.Color> {
        Binding(
            get: { swiftUIColor(draft.background.colors.first ?? Self.fallbackColor) },
            set: { setMeshColor(presentationColor($0)) }
        )
    }

    private var gradientShape: GradientShape {
        switch draft.background {
        case .radialGradient: return .radial
        case .mesh:           return .mesh
        default:              return .linear
        }
    }

    /// Flipping the shape keeps the stops and the angle: it is the same
    /// gradient drawn a different way, so nothing the user picked is discarded.
    private var gradientShapeBinding: Binding<GradientShape> {
        Binding(get: { gradientShape }, set: { shape in
            switch shape {
            case .linear: switchBackground(to: .linear)
            case .radial: switchBackground(to: .radial)
            case .mesh:   switchBackground(to: .mesh)
            }
        })
    }

    private var currentGradientAngle: CGFloat {
        if case .linearGradient(_, let angle) = draft.background { return angle }
        return .pi / 2
    }

    private var currentStops: [Presentation.Stop] {
        let stops = draft.background.stops
        return stops.count >= 2 ? stops : Presentation.Stop.spread(Self.defaultStops)
    }

    private func setStops(_ stops: [Presentation.Stop]) {
        updateImmediately {
            switch $0.background {
            case .radialGradient:
                $0.background = .radialGradient(stops: stops)
            case .linearGradient(_, let angle):
                $0.background = .linearGradient(stops: stops, angle: angle)
            default:
                $0.background = .linearGradient(stops: stops, angle: .pi / 2)
            }
        }
    }

    /// A palette or archive tap paints the stop the user has selected — the
    /// one wearing the ring. That is the whole reason the row has a selection:
    /// picking colours for a gradient is otherwise a trip through the system
    /// colour panel for every stop.
    private func setSelectedStopColor(_ color: Presentation.Color) {
        let stops = currentStops
        let index = GradientStops.clampedSelection(selectedStop, in: stops)
        setStops(GradientStops.recolored(stops, at: index, to: color))
    }

    private func setSolidColor(_ color: Presentation.Color) {
        updateImmediately { $0.background = .solid(color) }
    }

    private func setMeshColor(_ color: Presentation.Color) {
        updateImmediately { $0.background = .mesh(colors: Self.meshColors(from: color)) }
    }

    private static func meshColors(from color: Presentation.Color) -> [Presentation.Color] {
        [mix(color, .white, amount: 0.28),
         mix(color, .white, amount: 0.06),
         mix(color, .black, amount: 0.18),
         mix(color, .black, amount: 0.04)]
    }

    private static func mix(_ lhs: Presentation.Color,
                            _ rhs: Presentation.Color,
                            amount: CGFloat) -> Presentation.Color {
        GradientStops.blend(lhs, rhs, amount: amount)
    }

    private func sampledBackgroundColors() -> [Presentation.Color] {
        let colors = document.sampledPalette
        return colors.isEmpty ? Self.meshColors(from: Self.fallbackColor) : colors
    }

    // MARK: Image and effect bindings

    private var cornerRadiusBinding: Binding<CGFloat> {
        Binding(get: { draft.cornerRadius }, set: { value in
            updateLive { $0.cornerRadius = value }
        })
    }

    private var gradientAngleBinding: Binding<CGFloat> {
        Binding(
            get: {
                guard case .linearGradient(_, let angle) = draft.background
                else { return 90 }
                return angle * 180 / .pi
            },
            set: { value in
                updateLive {
                    guard case .linearGradient(let stops, _) = $0.background
                    else { return }
                    $0.background = .linearGradient(stops: stops,
                                                    angle: value * .pi / 180)
                }
            }
        )
    }

    private var shadowRadiusBinding: Binding<CGFloat> {
        Binding(get: { draft.shadow.radius }, set: { value in
            updateLive { $0.shadow.radius = value }
        })
    }

    private var shadowOpacityBinding: Binding<CGFloat> {
        Binding(get: { draft.shadow.opacity }, set: { value in
            updateLive { $0.shadow.opacity = value }
        })
    }

    private var shadowOffsetXBinding: Binding<CGFloat> {
        Binding(get: { draft.shadow.offset.x }, set: { value in
            updateLive { $0.shadow.offset.x = value }
        })
    }

    private var shadowOffsetYBinding: Binding<CGFloat> {
        Binding(get: { draft.shadow.offset.y }, set: { value in
            updateLive { $0.shadow.offset.y = value }
        })
    }

    /// Opacity has its own slider; a colour that also carried alpha would give
    /// two controls one number to fight over.
    private func setShadowColor(_ color: Presentation.Color) {
        var opaque = color
        opaque.alpha = 1
        updateImmediately { $0.shadow.color = opaque }
    }

    private var shadowColorBinding: Binding<SwiftUI.Color> {
        Binding(
            get: { swiftUIColor(draft.shadow.color) },
            set: { value in
                var color = presentationColor(value)
                // Opacity has its own slider; a colour that also carried alpha
                // would give the user two controls fighting over one number.
                color.alpha = 1
                updateImmediately { $0.shadow.color = color }
            }
        )
    }

    // MARK: Document mutations

    private func addEffect(_ kind: Presentation.Effect.Kind) {
        updateImmediately { $0.effects.append(EffectStack.make(kind)) }
    }

    private func removeEffect(_ effect: Presentation.Effect) {
        updateImmediately { $0.effects.removeAll { $0.id == effect.id } }
    }

    private func moveEffect(from: Int, to: Int) {
        updateImmediately { $0.effects = EffectStack.moved($0.effects, from: from, to: to).effects }
    }

    /// One effect changed in place. Discrete, so it is its own undo step —
    /// unlike a slider, which groups the whole drag.
    private func setEffect(_ effect: Presentation.Effect,
                           _ mutation: (inout Presentation.Effect) -> Void) {
        guard let index = draft.effects.firstIndex(where: { $0.id == effect.id }) else { return }
        var changed = draft.effects[index]
        mutation(&changed)
        updateImmediately { $0.effects[index] = changed }
    }

    /// A parameter of one effect, live: the slider drags the picture and the
    /// gesture is one undo step (`sliderEditingChanged`), exactly as the shadow
    /// sliders do.
    private func effectBinding(_ effect: Presentation.Effect,
                               _ parameter: EffectStack.Parameter) -> Binding<CGFloat> {
        Binding(
            get: {
                guard let current = draft.effects.first(where: { $0.id == effect.id })
                else { return 0 }
                return EffectStack.value(parameter, of: current)
            },
            set: { value in
                guard let index = draft.effects.firstIndex(where: { $0.id == effect.id })
                else { return }
                let updated = EffectStack.setting(parameter, of: draft.effects[index], to: value)
                updateLive { $0.effects[index] = updated }
            }
        )
    }

    private func updateLive(_ mutation: (inout Presentation) -> Void) {
        var next = draft
        mutation(&next)
        draft = next
        // Keep the identity draft local until a real control changes it. This
        // preserves nil for an untouched document while still rendering every
        // subsequent slider tick immediately.
        guard document.presentation != nil || next != .identity else { return }
        if document.presentation != next { document.presentation = next }
    }

    private func updateImmediately(_ mutation: (inout Presentation) -> Void) {
        document.beginChange()
        updateLive(mutation)
        document.commitChange()
    }

    private func removePresentation() {
        document.beginChange()
        draft = .identity
        document.presentation = nil
        document.commitChange()
    }

    private func swiftUIColor(_ color: Presentation.Color) -> SwiftUI.Color {
        SwiftUI.Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: Double(color.alpha)
        )
    }

    private func presentationColor(_ color: SwiftUI.Color) -> Presentation.Color {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return Presentation.Color(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }
}
