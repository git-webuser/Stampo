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

    @State private var draft: Presentation
    /// Which groups the user has folded away. Sections are identified by a
    /// stable case rather than by their title, which is a localized key and
    /// therefore not a usable dictionary key.
    @State private var collapsed: Set<Section> = []
    /// Colours the user chose to keep, alongside the eight built-ins.
    /// Session-scoped on purpose: nothing about the decoration is
    /// persisted yet, and a palette is not the place to start.
    @State private var userColors: [Presentation.Color] = []

    private enum Section: Hashable, CaseIterable {
        case canvas, background, image, shadow

        /// Kept on the case (and exposed through `sectionSystemImages`) so the
        /// SF Symbol availability test can reach these names.
        var systemImage: String {
            switch self {
            // Each one its own: the decor button already owns
            // `rectangle.center.inset.filled`, and a section repeating it made
            // the panel look like it was labelled twice.
            case .canvas:     return "rectangle.dashed"
            case .background: return "paintpalette"
            case .image:      return "photo"
            case .shadow:     return "square.filled.on.square"
            }
        }
    }

    static var sectionSystemImages: [String] {
        Section.allCases.map(\.systemImage)
    }

    // MARK: Canvas formats

    /// Formats are listed in one orientation only. Portrait versions are the
    /// same format turned, which is what the rotate button is for — a separate
    /// "9:16" tile beside "16:9" would be the same choice twice.
    /// The formats, and — last — the page that has no fixed format at all.
    ///
    /// "Custom" is not here: a size you typed is not a format, it is what the
    /// width and height fields already say. `auto` is, because it is a real
    /// choice of page — one whose size follows the margins instead of dictating
    /// them, which is why its tile shows the size it currently works out to.
    private enum CanvasChoice: String, CaseIterable, Hashable, Identifiable {
        case square, threeFour, instagram, twitter, openGraph, auto

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .square:    return "Square"
            case .threeFour: return "Classic 3:4"
            case .instagram: return "Instagram 4:5"
            case .twitter:   return "Twitter / X"
            case .openGraph: return "Open Graph"
            case .auto:      return "Auto"
            }
        }

        /// nil for `auto`, whose size is worked out rather than chosen.
        var pixelSize: CGSize? {
            switch self {
            case .square:    return CGSize(width: 1080, height: 1080)
            case .threeFour: return CGSize(width: 1080, height: 1440)
            case .instagram: return CGSize(width: 1080, height: 1350)
            case .twitter:   return CGSize(width: 1600, height: 900)
            case .openGraph: return CGSize(width: 1200, height: 630)
            case .auto:      return nil
            }
        }
    }

    /// Linear and radial are one background with a shape switch, not two
    /// entries in the list — the stops, the palette and the whole editor below
    /// are identical, and giving them separate tiles made the panel reflow for
    /// what is really one choice.
    private enum BackgroundKind: String, CaseIterable, Hashable, Identifiable {
        case solid, none, gradient

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

    private enum CanvasDimension {
        case width, height
    }

    /// A number field whose value lives in the *placeholder*, so the editable
    /// text is always empty and typing starts a fresh number.
    ///
    /// Three attempts at selecting the text on click failed for the same
    /// reason: `mouseDown` runs its own tracking loop and sets the selection
    /// when the button comes back up, after anything the app chose. Rather than
    /// race that, there is simply nothing to select — the number is drawn as a
    /// placeholder in the ordinary label colour, so it reads as a value while
    /// behaving like an empty field. Confirming a number puts it back into the
    /// placeholder and empties the text again.
    private struct NumberField: NSViewRepresentable {
        @Binding var value: Double
        var alignment: NSTextAlignment = .right
        var onCommit: (Double) -> Void

        final class Field: NSTextField {
            /// The number goes the moment editing starts. Overridden on the
            /// field rather than handled through the delegate: this is the
            /// control's own hook and it fires whether or not anything else is
            /// listening — the delegate route left the placeholder standing.
            /// The number is ordinary text, and taking the keyboard empties it:
            /// the field editor is installed *after* this, so it starts on an
            /// empty string and the first keystroke begins a new number. No
            /// placeholder is involved — a placeholder that survives the click
            /// looks like text you could edit, and it is not.
            override func becomeFirstResponder() -> Bool {
                let accepted = super.becomeFirstResponder()
                if accepted { stringValue = "" }
                return accepted
            }

            func show(_ number: Double) {
                stringValue = Self.formatter.string(from: NSNumber(value: number))
                    ?? String(Int(number))
            }

            static let formatter: NumberFormatter = {
                let formatter = NumberFormatter()
                formatter.numberStyle = .none
                formatter.usesGroupingSeparator = false
                formatter.maximumFractionDigits = 0
                return formatter
            }()
        }

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var onCommit: (Double) -> Void = { _ in }
            var current: Double = 0

            /// An empty field means "unchanged": the placeholder is still the
            /// value, and leaving without typing must not rewrite it.
            private func commit(_ field: NSTextField) {
                defer { (field as? Field)?.show(current) }
                let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard !typed.isEmpty, let value = Double(typed) else { return }
                onCommit(value)
            }

            @objc func changed(_ sender: NSTextField) { commit(sender) }



            func controlTextDidEndEditing(_ notification: Notification) {
                guard let field = notification.object as? NSTextField else { return }
                commit(field)
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> Field {
            let field = Field()
            // `isBezeled`, not `isBordered`: a plain border draws the square box
            // that replaced the panel's rounded fields.
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .default
            field.alignment = alignment
            // Match the rest of the panel's controls, which are all large.
            field.controlSize = .large
            field.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize(for: .large), weight: .regular
            )
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.delegate = context.coordinator
            field.target = context.coordinator
            field.action = #selector(Coordinator.changed(_:))
            return field
        }

        func updateNSView(_ field: Field, context: Context) {
            context.coordinator.onCommit = onCommit
            context.coordinator.current = value
            field.alignment = alignment
            // Never disturb a field that has the keyboard — including the
            // moment after the click when its editor is not installed yet.
            guard field.currentEditor() == nil,
                  field.window?.firstResponder !== field else { return }
            field.show(value)
        }
    }

    /// A round colour chip that opens the system colour panel.
    ///
    /// SwiftUI's `ColorPicker` draws a wide rectangular well whose width cannot
    /// be constrained: beside the round chips it read as a different kind of
    /// control, and a row of them pushed the inspector past its own maximum
    /// width. This is the same circle the annotation toolbar uses, so every
    /// colour in the app is picked from the same shape.
    private struct ColorChip: View {
        let color: Presentation.Color
        var diameter: CGFloat
        var isSelected: Bool = false
        var supportsOpacity: Bool = true
        let onChange: (Presentation.Color) -> Void

        var body: some View {
            Button {
                // Order matters and so does ownership. `NSColorPanel` keeps an
                // unowned target, and assigning its colour makes it fire the
                // action straight away — so the target is installed first, and
                // it is a process-wide object rather than this view's state.
                // A per-view proxy was deallocated as the chip re-rendered and
                // the panel then messaged freed memory (EXC_BAD_ACCESS in
                // objc_msgSend, measured from the crash report).
                let panel = NSColorPanel.shared
                ColorPanelProxy.shared.onChange = onChange
                panel.setTarget(ColorPanelProxy.shared)
                panel.setAction(#selector(ColorPanelProxy.colorChanged(_:)))
                panel.showsAlpha = supportsOpacity
                panel.color = NSColor(srgbRed: color.red, green: color.green,
                                      blue: color.blue, alpha: color.alpha)
                panel.makeKeyAndOrderFront(nil)
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
    private static let backgroundPresets: [BackgroundPreset] = {
        func linear(_ id: String, _ a: Presentation.Color, _ b: Presentation.Color) -> BackgroundPreset {
            BackgroundPreset(id: id, background: .linearGradient(stops: [a, b], angle: .pi / 2))
        }
        return [
            BackgroundPreset(id: "paper", background: .solid(rgb(0.97, 0.97, 0.96))),
            BackgroundPreset(id: "sand", background: .solid(rgb(0.93, 0.89, 0.85))),
            BackgroundPreset(id: "mist", background: .solid(rgb(0.87, 0.89, 0.92))),
            BackgroundPreset(id: "sage", background: .solid(rgb(0.84, 0.88, 0.83))),
            BackgroundPreset(id: "graphite", background: .solid(rgb(0.11, 0.11, 0.12))),
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
                stops: [rgb(0.98, 0.78, 0.83), rgb(0.85, 0.36, 0.53)])),
            BackgroundPreset(id: "deep", background: .radialGradient(
                stops: [rgb(0.31, 0.36, 0.62), rgb(0.06, 0.07, 0.14)])),
            BackgroundPreset(id: "amberGlow", background: .radialGradient(
                stops: [rgb(0.99, 0.85, 0.55), rgb(0.85, 0.45, 0.15)])),
            BackgroundPreset(id: "mintGlow", background: .radialGradient(
                stops: [rgb(0.80, 0.98, 0.90), rgb(0.15, 0.50, 0.45)])),
            BackgroundPreset(id: "violetGlow", background: .radialGradient(
                stops: [rgb(0.80, 0.70, 0.99), rgb(0.30, 0.15, 0.55)])),
            BackgroundPreset(id: "steel", background: .radialGradient(
                stops: [rgb(0.85, 0.88, 0.92), rgb(0.35, 0.40, 0.48)])),
            BackgroundPreset(id: "ember", background: .radialGradient(
                stops: [rgb(0.99, 0.72, 0.55), rgb(0.55, 0.12, 0.15)])),
            BackgroundPreset(id: "ink", background: .radialGradient(
                stops: [rgb(0.45, 0.50, 0.60), rgb(0.05, 0.05, 0.09)])),
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

    private static let fallbackColor = Presentation.Color(
        red: 0.18, green: 0.43, blue: 0.92, alpha: 1
    )

    /// One row of eight, never two. Sized together with `contentMinimumWidth`.
    private static let swatchSize: CGFloat = 22
    private static let swatchGap: CGFloat = 6

    init(document: EditorDocument) {
        self.document = document
        _draft = State(initialValue: document.presentation ?? .identity)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header
                canvasSection
                backgroundSection
                imageSection
                shadowSection
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

    // MARK: Canvas

    private var canvasSection: some View {
        inspectorGroup("Canvas", section: .canvas) {
            tileGrid(CanvasChoice.allCases, selected: canvasChoice) { choice in
                canvasTile(choice)
            } action: { choice in
                selectCanvas(choice)
            }

            // The size fields show the page the document actually has, and
            // typing in them sets it.
            HStack(spacing: 8) {
                NumberField(value: .constant(Double(canvasSize.width.rounded()))) { typed in
                    setCustomDimension(.width, to: Int(typed))
                }
                .frame(width: Self.numberFieldWidth)
                Text(verbatim: "×").foregroundStyle(.secondary)
                NumberField(value: .constant(Double(canvasSize.height.rounded()))) { typed in
                    setCustomDimension(.height, to: Int(typed))
                }
                .frame(width: Self.numberFieldWidth)
                Spacer(minLength: 0)
                Button {
                    rotateCanvas()
                } label: {
                    Image(systemName: "rotate.right")
                }
                .controlSize(.large)
                .help("Rotate Canvas")
                .accessibilityLabel(Text("Rotate Canvas"))
                .disabled(marginsAreFree)

            }
            .controlSize(.large)
            .font(.system(size: 13))
        }
    }

    /// A proportional plate plus the format's own pixel size: the two things a
    /// name alone cannot tell you.
    ///
    /// Custom shows no numbers. Its size is whatever the fields below say, so
    /// printing it here only repeats them — and while a preset is active it
    /// repeats *that* preset, which reads as two tiles claiming the same size.
    private func canvasTile(_ choice: CanvasChoice) -> some View {
        let size = tileSize(for: choice)
        let ratio = size.height > 0 ? size.width / size.height : 1
        return VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.tertiary, lineWidth: 1))
                    .overlay {
                        // A bare grey plate says nothing a name does not; the
                        // ratio is the one fact the plate's silhouette only
                        // hints at. Custom has no ratio to promise — it is
                        // whatever the fields below say — so it shows a mark.
                        Text(verbatim: choice.pixelSize == nil
                             ? "—"
                             : Self.ratioLabel(for: size))
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 2)
                    }
                    .aspectRatio(max(0.3, min(3, ratio)), contentMode: .fit)
            }
            .frame(height: 34)
            Text(choice.titleKey)
                .font(.system(size: 10))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // `verbatim` on purpose: a localized interpolation groups the
            // digits, and "1 080×1 350" is not how anyone writes a pixel size.
            // Custom says nothing here: its numbers are the fields below, and
            // printing them twice is what made the tile look like a duplicate.
            Text(verbatim: "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// A selected format follows the canvas's current orientation; the others
    /// stay in their canonical one, so the row does not spin as you rotate.
    private func tileSize(for choice: CanvasChoice) -> CGSize {
        guard let preset = choice.pixelSize else { return resolvedLayout.canvasSize }
        guard canvasChoice == choice, canvasIsPortrait != (preset.height > preset.width)
        else { return preset }
        return CGSize(width: preset.height, height: preset.width)
    }

    /// "16:9" when the sides reduce to something a person would say, otherwise
    /// a decimal like "1.91:1". Reducing 1600×900 to 16:9 is the point; showing
    /// "1080:1350" instead of "4:5" would be worse than showing nothing.
    static func ratioLabel(for size: CGSize) -> String {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return "—" }
        var a = w, b = h
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = max(1, a)
        let rw = w / divisor, rh = h / divisor
        if rw <= 32 && rh <= 32 { return "\(rw):\(rh)" }
        let ratio = CGFloat(w) / CGFloat(h)
        return ratio >= 1
            ? String(format: "%.2f:1", Double(ratio))
            : String(format: "1:%.2f", Double(1 / ratio))
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
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .solid:
                swatchRow(selected: solidColor) { setSolidColor($0) }
                customColorRow(binding: solidColorBinding)
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
        let sorted = colors.sorted { $0.red + $0.green + $0.blue < $1.red + $1.green + $1.blue }
        let dark = sorted.first ?? Self.fallbackColor
        let light = sorted.last ?? dark
        let background: Presentation.Background
        switch (backgroundKind, gradientShape) {
        case (.solid, _):
            background = .solid(light)
        case (.gradient, .radial):
            background = .radialGradient(stops: [light, dark])
        case (.gradient, .mesh):
            background = .mesh(colors: colors)
        default:
            background = .linearGradient(stops: [light, dark], angle: .pi / 2)
        }
        return BackgroundPreset(id: "fromImage", background: background)
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
        let presets = [sampledPreset] + Self.backgroundPresets.filter { preset in
            guard preset.kind == backgroundKind else { return false }
            guard backgroundKind == .gradient else { return true }
            return preset.shape == gradientShape
        }
        if !presets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
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
                                            .font(.system(size: 9, weight: .semibold))
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
                .font(.system(size: 10))
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

    private func previewStops(for kind: BackgroundKind) -> [Presentation.Color] {
        if backgroundKind == kind, !draft.background.stops.isEmpty {
            return draft.background.stops
        }
        return Self.defaultStops
    }

    private static let defaultStops: [Presentation.Color] = [
        Presentation.Color(red: 0.36, green: 0.55, blue: 0.98, alpha: 1),
        Presentation.Color(red: 0.09, green: 0.13, blue: 0.36, alpha: 1)
    ]

    /// Stops are the whole gradient UI: every one is an editable well, and the
    /// two buttons are what turns an ordinary gradient into a layered one.
    private var stopEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.swatchGap) {
                ForEach(Array(currentStops.enumerated()), id: \.offset) { index, color in
                    ColorChip(color: color, diameter: Self.swatchSize) { picked in
                        var stops = currentStops
                        guard stops.indices.contains(index) else { return }
                        stops[index] = picked
                        setStops(stops)
                    }
                    .accessibilityLabel(Text("Stop"))
                }
                Spacer(minLength: 0)
                Button {
                    addStop()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(currentStops.count >= 5)
                .accessibilityLabel(Text("Add Stop"))
                Button {
                    removeStop()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(currentStops.count <= 2)
                .accessibilityLabel(Text("Remove Stop"))
            }
            .controlSize(.large)

            swatchRow(selected: nil) { appendOrReplaceLastStop($0) }
        }
    }

    private var swatchRowWidth: CGFloat {
        CGFloat(Self.palette.count) * Self.swatchSize
            + CGFloat(Self.palette.count - 1) * Self.swatchGap
    }

    /// A fixed single row — never a wrapping grid. If it does not fit, the
    /// inspector is too narrow and `contentMinimumWidth` is the thing to fix.
    /// The user's own colours follow the eight built-ins on a second row, which
    /// only appears once there is something to put on it.
    private func swatchRow(
        selected: Presentation.Color?,
        action: @escaping (Presentation.Color) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Self.swatchGap) {
            HStack(spacing: Self.swatchGap) {
                ForEach(Self.palette) { entry in
                    swatch(entry.color, selected: selected, label: entry.titleKey,
                           action: action)
                }
            }
            .frame(minWidth: swatchRowWidth, alignment: .leading)

            if !userColors.isEmpty {
                Divider()
                // Adaptive, not an HStack: saved colours must wrap onto another
                // line rather than push the inspector past its own maximum
                // width (and, with enough of them, off the screen).
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.swatchSize),
                                       spacing: Self.swatchGap,
                                       alignment: .leading)],
                    alignment: .leading,
                    spacing: Self.swatchGap
                ) {
                    ForEach(Array(userColors.enumerated()), id: \.offset) { index, color in
                        swatch(color, selected: selected, label: "Custom Color",
                               action: action)
                            .contextMenu {
                                Button(role: .destructive) {
                                    userColors.remove(at: index)
                                } label: {
                                    Label("Remove Color", systemImage: "trash")
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                    }
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

    /// The well picks a colour; the plus keeps it. Without the second half a
    /// "custom colour" is a single slot that the next pick overwrites, which is
    /// no use when a design needs three of them.
    private func customColorRow(binding: Binding<SwiftUI.Color>) -> some View {
        HStack(spacing: 8) {
            Text("Custom Color")
            ColorChip(color: presentationColor(binding.wrappedValue),
                      diameter: Self.swatchSize) { picked in
                binding.wrappedValue = swiftUIColor(picked)
            }
            Spacer(minLength: 0)
            // Trailing, like the canvas rotate button: the actions in this
            // panel all sit on the right edge of their row.
            Button {
                let color = presentationColor(binding.wrappedValue)
                if !userColors.contains(color), !Self.palette.contains(where: { $0.color == color }) {
                    userColors.append(color)
                }
            } label: {
                Image(systemName: "plus")
            }
            .controlSize(.large)
            .help("Save Color")
            .accessibilityLabel(Text("Save Color"))
        }
        .font(.system(size: 11))
    }


    /// A mesh is four corner colours, and now the panel says so. It used to
    /// offer a single seed that the app spread into four by mixing with white
    /// and black — which is why choosing one felt like guessing what would come
    /// out the other end.
    private var meshCornerEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Corners")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: Self.swatchGap) {
                ForEach(0..<4, id: \.self) { index in
                    ColorChip(color: meshCorners[index], diameter: Self.swatchSize) { picked in
                        var colors = meshCorners
                        colors[index] = picked
                        updateImmediately { $0.background = .mesh(colors: colors) }
                    }
                    .accessibilityLabel(Text("Corners"))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var meshCorners: [Presentation.Color] {
        if case .mesh(let colors) = draft.background, colors.count >= 4 { return colors }
        return Self.meshCorners(from: draft.background.stops)
    }

    /// Two stops spread over four corners: the ends keep their colours and the
    /// other two are the blend, so switching from a line to a mesh keeps what
    /// the user had rather than starting over.
    static func meshCorners(from stops: [Presentation.Color]) -> [Presentation.Color] {
        guard let first = stops.first else { return meshColors(from: fallbackColor) }
        let last = stops.last ?? first
        let middle = mix(first, last, amount: 0.5)
        return [first, middle, middle, last]
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

    /// The four margins drawn where they are: around a small stand-in for the
    /// picture. A column of four labelled fields made the reader work out which
    /// side each one meant.
    private var gapGrid: some View {
        let gaps = PresentationLayout.gaps(resolvedLayout)
        return VStack(spacing: Self.marginGap) {
            gapField(.top, value: gaps.top)
            HStack(spacing: Self.marginGap) {
                gapField(.leading, value: gaps.leading)
                // The picture's stand-in, sized to the gap between the fields
                // so the cross reads as a frame around it rather than as four
                // controls that happen to be near each other.
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: Self.marginPlateWidth, height: 30)
                gapField(.trailing, value: gaps.trailing)
            }
            gapField(.bottom, value: gaps.bottom)
        }
        .frame(maxWidth: .infinity)
    }

    private static let marginGap: CGFloat = 6
    /// What is left in the middle once two fields and their gaps are placed.
    private static let marginPlateWidth: CGFloat = 44

    private func gapField(_ edge: PresentationLayout.Edge, value: CGFloat) -> some View {
        NumberField(value: .constant(Double(value.rounded())), alignment: .center) { typed in
            setGap(edge, to: CGFloat(typed))
        }
        .frame(width: Self.numberFieldWidth)
        // SwiftUI writes the environment's control size onto the wrapped
        // NSControl, so a field outside a `.large` container is reset to the
        // regular one — 22 points against the canvas row's 30. Measured.
        .controlSize(.large)
        .help(Self.gapTitle(edge))
        .accessibilityLabel(Self.gapTitle(edge))
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

    private func setGap(_ edge: PresentationLayout.Edge, to value: CGFloat) {
        // On an auto page the margins *are* the page, so each one is simply
        // itself: 50 on four sides is four numbers. On a fixed page there is a
        // size to respect, so the picture resizes against the opposite edge.
        if case .auto(var margins, let scale) = draft.canvas {
            guard margins[edge] != value else { return }
            margins[edge] = value
            updateImmediately { $0.canvas = .auto(margins: margins, scale: scale) }
            return
        }
        let placement = PresentationLayout.placement(
            draft.image, settingGap: edge, to: value,
            imagePixelSize: document.pixelSize, canvasSize: canvasSize, in: draft
        )
        guard placement != draft.image else { return }
        updateImmediately { $0.image = placement }
    }

    /// The one switch that says which of the two numbers is the input.
    ///
    /// On: the margins are, and the page size follows them — so all four can be
    /// whatever you ask, 50 all round included. Off: the page size is, and the
    /// margins follow it, which on a locked aspect ratio means they cannot all
    /// be set independently. Flipping it never moves the picture: the state it
    /// leaves behind is the one you were already looking at.
    private func setFreeMargins(_ free: Bool) {
        let layout = resolvedLayout
        guard free != marginsAreFree else { return }
        if free {
            // Auto takes over exactly what is on screen — the margins *and* the
            // size the picture was left at. Going 1:1, resizing, then back to
            // Auto must not rewind to whatever Auto held before.
            let gaps = PresentationLayout.gaps(layout)
            let margins = Presentation.Margins(top: gaps.top.rounded(),
                                               leading: gaps.leading.rounded(),
                                               bottom: gaps.bottom.rounded(),
                                               trailing: gaps.trailing.rounded())
            let image = document.pixelSize
            let scale = image.width > 0 ? layout.imageRect.width / image.width : 1
            updateImmediately {
                $0.canvas = .auto(margins: margins, scale: scale)
                $0.image = .fitted
            }
            return
        }
        // Freezing the page: keep its current size, and describe the picture's
        // present rectangle as a placement inside it.
        let canvas = layout.canvasSize
        let image = document.pixelSize
        guard canvas.width > 0, canvas.height > 0, image.width > 0, image.height > 0,
              layout.imageRect.width > 0 else { return }
        let fit = min(canvas.width / image.width, canvas.height / image.height)
        guard fit > 0 else { return }
        let placement = Presentation.ImagePlacement(
            center: CGPoint(x: layout.imageRect.midX / canvas.width,
                            y: layout.imageRect.midY / canvas.height),
            scale: layout.imageRect.width / (image.width * fit)
        )
        updateImmediately {
            $0.canvas = .preset(pixelSize: canvas)
            $0.image = placement
        }
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
            HStack(spacing: 8) {
                Text("Shadow Color")
                ColorChip(color: draft.shadow.color, diameter: Self.swatchSize,
                          supportsOpacity: false) { picked in
                    var color = picked
                    // Opacity has its own slider; a colour that also carried
                    // alpha would give two controls one number to fight over.
                    color.alpha = 1
                    updateImmediately { $0.shadow.color = color }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
        }
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
    private var canvasChoice: CanvasChoice? {
        guard case .preset(let pixelSize) = draft.canvas else { return .auto }
        let turned = CGSize(width: pixelSize.height, height: pixelSize.width)
        // Either orientation counts: rotating a format does not turn it into a
        // different one. Nothing matches a size you typed — nothing is
        // highlighted then, which is the truth.
        return CanvasChoice.allCases.first {
            guard let preset = $0.pixelSize else { return false }
            return preset == pixelSize || preset == turned
        }
    }

    /// Turns the canvas a quarter, keeping the same format selected.
    private func rotateCanvas() {
        let size = canvasSize
        let turned = CGSize(width: size.height, height: size.width)
        updateImmediately { $0.canvas = .preset(pixelSize: turned) }
    }

    private var canvasIsPortrait: Bool {
        canvasSize.height > canvasSize.width
    }

    /// Custom keeps whatever size is on screen and simply hands it over to the
    /// user — it is a mode, not a different number, so it stays selectable even
    /// when the current size happens to match a preset exactly.
    /// Choosing a format fixes the page, so free margins switch off with it —
    /// otherwise the format would mean nothing, the size being derived from the
    /// margins anyway.
    private func selectCanvas(_ choice: CanvasChoice) {
        guard let presetSize = choice.pixelSize else {
            setFreeMargins(true)
            return
        }
        let canvas: Presentation.Canvas = .preset(pixelSize: presetSize)
        // Leaving "Original" for a real format is the moment a decoration
        // starts, so it starts framed rather than edge to edge. Only then:
        // a padding the user has since chosen (zero included) is theirs.
        let framesForTheFirstTime = draft.image == .fitted
        let framed = PresentationLayout.placement(
            framingWith: Presentation.defaultMargin,
            imagePixelSize: document.pixelSize,
            canvasSize: {
                if case .preset(let size) = canvas { return size }
                return document.pixelSize
            }()
        )
        updateImmediately {
            $0.canvas = canvas
            if framesForTheFirstTime {
                $0.image = framed
                // A transparent canvas is a deliberate choice, not a starting
                // point: the first thing a format should show is a framed shot
                // on a real background.
                if case .none = $0.background { $0.background = .solid(.white) }
            }
        }
    }

    private var canvasSize: CGSize {
        resolvedLayout.canvasSize
    }

    /// Shows the size the page *is* — an auto page grows with its margins, and
    /// a field that kept showing the last custom number instead would be the
    /// same kind of lie the margins used to tell. Typing is what makes it
    /// custom.
    private func customDimensionBinding(_ dimension: CanvasDimension) -> Binding<Int> {
        Binding(
            get: {
                let live = canvasSize
                let value = dimension == .width ? live.width : live.height
                return max(1, Int(value.rounded()))
            },
            set: { setCustomDimension(dimension, to: $0) }
        )
    }

    /// Typing a size is itself the act of going custom, so the fields select
    /// the Custom tile instead of quietly rewriting the preset that is active.
    ///
    /// The equality guard is not an optimisation. A `TextField(value:format:)`
    /// writes its parsed value back as the field appears, and without this the
    /// canvas jumped to Custom the moment the inspector was merely opened —
    /// measured, not supposed. Opening the panel must change nothing.
    private func setCustomDimension(_ dimension: CanvasDimension, to value: Int) {
        let safeValue = CGFloat(min(16384, max(1, value)))
        let live = canvasSize
        let current = dimension == .width ? live.width : live.height
        guard safeValue != current.rounded() else { return }
        // On an auto page the size is still yours to set — the margins take up
        // the difference and the picture is left alone. Typing a size on a
        // fixed page simply sets that page's size.
        if case .auto(var margins, let scale) = draft.canvas {
            let delta = safeValue - current
            if dimension == .width {
                let split = PresentationLayout.absorb(delta, into: margins.leading,
                                                      and: margins.trailing)
                margins.leading = split.near
                margins.trailing = split.far
            } else {
                let split = PresentationLayout.absorb(delta, into: margins.top,
                                                      and: margins.bottom)
                margins.top = split.near
                margins.bottom = split.far
            }
            updateImmediately { $0.canvas = .auto(margins: margins, scale: scale) }
            return
        }
        var size = live
        if dimension == .width { size.width = safeValue }
        else { size.height = safeValue }
        updateImmediately { $0.canvas = .preset(pixelSize: size) }
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
        let carried = draft.background.stops
        let stops = carried.count >= 2 ? carried : Self.defaultStops
        let next: Presentation.Background
        switch kind {
        case .none:
            next = .none
        case .solid:
            if case .solid(let color) = draft.background { next = .solid(color) }
            else { next = .solid(carried.first ?? .white) }
        case .gradient:
            switch draft.background {
            case .linearGradient, .radialGradient, .mesh:
                next = draft.background
            default:
                next = .linearGradient(stops: stops, angle: .pi / 2)
            }
        }
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
            get: { swiftUIColor(draft.background.stops.first ?? Self.fallbackColor) },
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
            let stops = currentStops
            let angle = currentGradientAngle
            updateImmediately { presentation in
                switch shape {
                case .linear:
                    presentation.background = .linearGradient(stops: stops, angle: angle)
                case .radial:
                    presentation.background = .radialGradient(stops: stops)
                case .mesh:
                    // The colours carry across: two stops become the two ends
                    // of a four-corner spread rather than being thrown away.
                    presentation.background = .mesh(colors: Self.meshCorners(from: stops))
                }
            }
        })
    }

    private var currentGradientAngle: CGFloat {
        if case .linearGradient(_, let angle) = draft.background { return angle }
        return .pi / 2
    }

    private var currentStops: [Presentation.Color] {
        let stops = draft.background.stops
        return stops.count >= 2 ? stops : Self.defaultStops
    }

    private func stopBinding(at index: Int) -> Binding<SwiftUI.Color> {
        Binding(
            get: {
                let stops = currentStops
                guard stops.indices.contains(index) else { return .clear }
                return swiftUIColor(stops[index])
            },
            set: { newValue in
                var stops = currentStops
                guard stops.indices.contains(index) else { return }
                stops[index] = presentationColor(newValue)
                setStops(stops)
            }
        )
    }

    private func setStops(_ stops: [Presentation.Color]) {
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

    private func addStop() {
        var stops = currentStops
        guard stops.count < 5, let last = stops.last else { return }
        stops.append(Self.mix(last, .black, amount: 0.35))
        setStops(stops)
    }

    private func removeStop() {
        var stops = currentStops
        guard stops.count > 2 else { return }
        stops.removeLast()
        setStops(stops)
    }

    /// A palette tap edits the stop nearest to "the one you are working on":
    /// the last. Picking colors for a gradient is otherwise a trip through the
    /// system color panel for every stop.
    private func appendOrReplaceLastStop(_ color: Presentation.Color) {
        var stops = currentStops
        stops[stops.count - 1] = color
        setStops(stops)
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
        let t = min(1, max(0, amount))
        return Presentation.Color(
            red: lhs.red + (rhs.red - lhs.red) * t,
            green: lhs.green + (rhs.green - lhs.green) * t,
            blue: lhs.blue + (rhs.blue - lhs.blue) * t,
            alpha: lhs.alpha + (rhs.alpha - lhs.alpha) * t
        )
    }

    private func sampledBackgroundColors() -> [Presentation.Color] {
        let colors = PresentationColorSampler.colors(from: document.baseImage)
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
