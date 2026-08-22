import CoreGraphics

/// Immutable, renderable dressing for an editor document.
///
/// The values stay independent of AppKit and image objects so the same
/// presentation can cross into the detached export task and be compared by
/// document history. Except for the canvas's explicit output size, all
/// distances are normalized to the canvas rather than tied to one screenshot.
nonisolated struct Presentation: Equatable, Sendable {
    /// Two kinds of page, and they carry different things because they *are*
    /// different things.
    ///
    /// `.auto` is a page that hugs the picture: its size is the picture plus
    /// the four margins, so all four are free — asking for 50 on every side is
    /// simply four numbers, not an aspect-ratio puzzle. `.preset` is a page of
    /// a fixed size, where the picture has to be placed inside it, so what it
    /// carries is a placement instead.
    ///
    /// Each case holds exactly its own degrees of freedom, which is why neither
    /// can drift out of agreement with what is drawn.
    enum Canvas: Equatable, Sendable {
        /// Margins plus the size the picture is drawn at, as a multiple of its
        /// own pixels. The page is the sum of the two, so both belong to the
        /// case: an auto page that forgot the picture's size would throw away
        /// a scaling the user had just done on a fixed page.
        case auto(margins: Margins, scale: CGFloat)
        case preset(pixelSize: CGSize)

        /// The ratio is a view of the pixel size, not a second source of truth.
        /// Keeping it computed prevents equal-looking canvases from becoming
        /// unequal merely because a redundant stored ratio was written.
        var aspectRatio: CGFloat {
            switch self {
            case .auto:
                return 0
            case .preset(let pixelSize):
                guard pixelSize.width.isFinite,
                      pixelSize.height.isFinite,
                      pixelSize.height != 0 else { return 0 }
                return pixelSize.width / pixelSize.height
            }
        }
    }

    /// A color value safe to carry through a detached render without bringing
    /// `NSColor` or `CGColor` into the document model.
    struct Color: Equatable, Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var alpha: CGFloat

        static let clear = Color(red: 0, green: 0, blue: 0, alpha: 0)
        static let white = Color(red: 1, green: 1, blue: 1, alpha: 1)
        static let black = Color(red: 0, green: 0, blue: 0, alpha: 1)
    }

    /// One colour of a gradient, and where along it that colour sits.
    ///
    /// The position is what makes a gradient editable rather than merely
    /// orderable: without it the stops are spread evenly and the only thing a
    /// person can change is which comes first, so "this colour holds to the
    /// middle and then falls away" cannot be said at all.
    struct Stop: Equatable, Sendable {
        var color: Color
        /// 0 at the start of the ramp, 1 at its end.
        var location: CGFloat

        init(_ color: Color, at location: CGFloat) {
            self.color = color
            self.location = location
        }

        /// Colours laid out evenly — how every gradient was built before
        /// positions existed, and still the right answer for a preset, for a
        /// mesh unfolded into a ramp, and for anything else that has colours
        /// but no opinion about where they go.
        static func spread(_ colors: [Color]) -> [Stop] {
            guard colors.count > 1 else {
                return colors.map { Stop($0, at: 0) }
            }
            let last = CGFloat(colors.count - 1)
            return colors.enumerated().map { Stop($1, at: CGFloat($0) / last) }
        }
    }

    /// Background recipes are values, not live SwiftUI gradients.
    ///
    /// Both gradients carry a *list* of stops rather than a start/end pair:
    /// two stops is the ordinary gradient and three or more is the layered one,
    /// so the renderer, the inspector and the model need no separate case for
    /// "complex". Each stop carries its own position; the list is never empty.
    enum Background: Equatable, Sendable {
        /// Nothing is painted, so the canvas around the image stays
        /// transparent and PNG export carries that transparency through.
        case none
        case solid(Color)
        case linearGradient(stops: [Stop], angle: CGFloat)
        case radialGradient(stops: [Stop])
        /// Four corner colours. Where they came from — a preset, the picture,
        /// the user — is not the model's business; a separate "sampled" case
        /// only meant the same drawing twice.
        case mesh(colors: [Color])

        /// The stops a user-facing editor works with. Empty for the cases that
        /// have no ramp — the mesh included: its four corners are colours in a
        /// square, not points on a line, and handing them back as "stops" is
        /// what made one accessor mean two different things.
        var stops: [Stop] {
            switch self {
            case .none, .solid, .mesh:           return []
            case .linearGradient(let stops, _):  return stops
            case .radialGradient(let stops):     return stops
            }
        }

        /// The four corners of a mesh, or nothing.
        var meshColors: [Color] {
            if case .mesh(let colors) = self { return colors }
            return []
        }

        /// Every colour this background is made of, wherever it keeps them —
        /// what a switch between kinds carries across.
        var colors: [Color] {
            switch self {
            case .none:              return []
            case .solid(let color):  return [color]
            case .mesh(let colors):  return colors
            case .linearGradient(let stops, _), .radialGradient(let stops):
                return stops.map(\.color)
            }
        }
    }

    /// Where the picture sits on the canvas.
    ///
    /// Three numbers for three degrees of freedom — position and size, with the
    /// aspect ratio locked — and nothing else. The previous encoding kept four
    /// paddings *and* a two-axis offset: six stored values for the same three,
    /// so the same placement had several spellings and the panel's "padding"
    /// readout described one of them rather than the result. A redundant
    /// encoding always drifts into lying.
    ///
    /// Edge gaps are not stored at all. They are what you get by subtracting
    /// this rectangle from the canvas, which is why they can never disagree
    /// with where the picture actually is — see `PresentationLayout.gaps`.
    struct ImagePlacement: Equatable, Sendable {
        /// Centre of the picture in canvas fractions; (0.5, 0.5) is the middle.
        var center: CGPoint
        /// Size relative to the picture fitted inside the canvas: 1 touches two
        /// edges, below 1 leaves air, above 1 overflows and the canvas crops.
        var scale: CGFloat

        static let fitted = ImagePlacement(center: CGPoint(x: 0.5, y: 0.5), scale: 1)
    }

    /// The four margins of an auto page, in pixels around the picture.
    struct Margins: Equatable, Sendable {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat

        static let zero = Margins(top: 0, leading: 0, bottom: 0, trailing: 0)

        init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        init(all: CGFloat) { self.init(top: all, leading: all, bottom: all, trailing: all) }

        subscript(edge: PresentationLayout.Edge) -> CGFloat {
            get {
                switch edge {
                case .top: return top
                case .leading: return leading
                case .bottom: return bottom
                case .trailing: return trailing
                }
            }
            set {
                switch edge {
                case .top: top = newValue
                case .leading: leading = newValue
                case .bottom: bottom = newValue
                case .trailing: trailing = newValue
                }
            }
        }
    }

    /// The margin a picture is framed with when a decoration starts.
    ///
    /// A share of the picture's short side rather than a fixed number of
    /// pixels: ten pixels — what this used to be — is a thick outline on a
    /// 2400-wide screenshot, not a background, and there is nothing to judge a
    /// background by. An absolute number lies in both directions, though, so it
    /// cannot simply be raised: 50 is half a 300-pixel crop and still an
    /// outline on a retina screen. Twelve percent of the short side is a
    /// seventh of the height on an ordinary window shot, and the clamps keep
    /// the extremes sane — a panorama's short side is small, a full retina
    /// screen's is large.
    static func defaultMargin(for imagePixelSize: CGSize) -> CGFloat {
        let short = min(imagePixelSize.width, imagePixelSize.height)
        guard short.isFinite, short > 0 else { return 32 }
        return min(240, max(32, (short * 0.12).rounded()))
    }

    /// The four gaps between the picture and the canvas edges, in canvas
    /// pixels. Derived, never stored; negative means the picture reaches past
    /// that edge and the canvas crops it.
    struct EdgeGaps: Equatable, Sendable {
        var top: CGFloat
        var leading: CGFloat
        var bottom: CGFloat
        var trailing: CGFloat
    }

    /// Shadow dimensions are normalized to the canvas; the offset is likewise
    /// expressed as fractions of its width and height, in both axes.
    ///
    /// `color` carries the hue only — `opacity` stays the single master alpha,
    /// so a colour picked with a translucent alpha cannot silently fight the
    /// opacity slider.
    struct Shadow: Equatable, Sendable {
        var radius: CGFloat
        var offset: CGPoint
        var opacity: CGFloat
        var color: Color = .black

        static let none = Shadow(radius: 0, offset: .zero, opacity: 0)
    }

    var canvas: Canvas
    var background: Background
    var image: ImagePlacement
    var cornerRadius: CGFloat
    var shadow: Shadow

    /// The identity value used when an optional presentation is absent.
    /// A plain white page is the neutral starting point; transparency is a
    /// deliberate choice made in the panel, not the state you land in.
    /// It is invisible until the picture stops covering the canvas, so an
    /// untouched document is unaffected — `nil` still means "no decoration".
    static let identity = Presentation(
        canvas: .auto(margins: .zero, scale: 1),
        background: .solid(.white),
        image: .fitted,
        cornerRadius: 0,
        shadow: .none
    )

    init(canvas: Canvas = .auto(margins: .zero, scale: 1),
         background: Background = .solid(.white),
         image: ImagePlacement = .fitted,
         cornerRadius: CGFloat = 0,
         shadow: Shadow = .none) {
        self.canvas = canvas
        self.background = background
        self.image = image
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }
}

/// Pure geometry for turning a presentation value into pixel-space rectangles.
///
/// Keeping this separate from CGContext and the editor means preview and
/// export can share the exact same canvas/image relationship and tests can
/// exercise the awkward aspect-ratio and degenerate-size cases directly.
nonisolated enum PresentationLayout {
    struct Resolved: Equatable, Sendable {
        let canvasSize: CGSize
        let imageRect: CGRect
    }

    static func resolve(imagePixelSize: CGSize, _ presentation: Presentation?) -> Resolved {
        guard let presentation else {
            let size = sanitizedSize(imagePixelSize)
            return Resolved(canvasSize: size, imageRect: CGRect(origin: .zero, size: size))
        }
        return resolve(imagePixelSize: imagePixelSize, presentation)
    }

    static func resolve(imagePixelSize: CGSize, _ presentation: Presentation) -> Resolved {
        let imageSize = sanitizedSize(imagePixelSize)
        // An auto page needs no fitting at all: the picture keeps its own
        // pixels — nothing is resampled — and the page grows around it.
        if case .auto(let margins, let scale) = presentation.canvas {
            let factor = max(0, finiteOrZero(scale, fallback: 1))
            let drawn = CGSize(width: imageSize.width * factor,
                               height: imageSize.height * factor)
            let leading = finiteOrZero(margins.leading)
            let top = finiteOrZero(margins.top)
            let canvas = CGSize(
                width: max(0, drawn.width + leading + finiteOrZero(margins.trailing)),
                height: max(0, drawn.height + top + finiteOrZero(margins.bottom))
            )
            return Resolved(canvasSize: canvas,
                            imageRect: CGRect(origin: CGPoint(x: leading, y: top),
                                              size: drawn))
        }
        let canvasSize: CGSize
        switch presentation.canvas {
        case .auto:
            canvasSize = imageSize
        case .preset(let pixelSize):
            canvasSize = sanitizedSize(pixelSize)
        }

        // Fit first, then the placement's own scale and centre. Nothing is
        // clamped: a picture larger than the canvas is a deliberate crop.
        let fit: CGFloat
        if imageSize.width > 0, imageSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 {
            fit = min(canvasSize.width / imageSize.width,
                      canvasSize.height / imageSize.height)
        } else {
            fit = 0
        }
        let scale = max(0, finiteOrZero(presentation.image.scale, fallback: 1))
        let scaledSize = CGSize(width: imageSize.width * fit * scale,
                                height: imageSize.height * fit * scale)
        let center = CGPoint(
            x: finiteOrZero(presentation.image.center.x, fallback: 0.5) * canvasSize.width,
            y: finiteOrZero(presentation.image.center.y, fallback: 0.5) * canvasSize.height
        )
        let imageOrigin = CGPoint(x: center.x - scaledSize.width / 2,
                                  y: center.y - scaledSize.height / 2)

        return Resolved(canvasSize: canvasSize,
                        imageRect: CGRect(origin: imageOrigin, size: scaledSize))
    }

    private static func sanitizedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(0, finiteOrZero(size.width)),
               height: max(0, finiteOrZero(size.height)))
    }

    private static func finiteOrZero(_ value: CGFloat, fallback: CGFloat = 0) -> CGFloat {
        value.isFinite ? value : fallback
    }

    /// The four gaps between the picture and the canvas edges, in canvas
    /// pixels. This is the only place edge insets exist, and it is a
    /// subtraction — so what the panel shows is always where the picture is.
    static func gaps(_ resolved: Resolved) -> Presentation.EdgeGaps {
        Presentation.EdgeGaps(
            top: resolved.imageRect.minY,
            leading: resolved.imageRect.minX,
            bottom: resolved.canvasSize.height - resolved.imageRect.maxY,
            trailing: resolved.canvasSize.width - resolved.imageRect.maxX
        )
    }

    /// The gap a pointer is asking for on `edge`, in canvas pixels.
    ///
    /// Dragging the middle of a side is the same act as typing into that
    /// margin field — the distance from the page's edge to the pointer *is* the
    /// margin — so both doors lead to `placement(_:settingGap:to:)` and neither
    /// invents a second rule. Negative is allowed and means the picture reaches
    /// past that edge, exactly as it does when the number is typed.
    static func gap(forPointer point: CGPoint, on edge: Edge,
                    canvasSize: CGSize) -> CGFloat {
        switch edge {
        case .leading:  return point.x
        case .top:      return point.y
        case .trailing: return canvasSize.width - point.x
        case .bottom:   return canvasSize.height - point.y
        }
    }

    /// The corner radius a pointer is asking for, as the model keeps it: a
    /// share of the canvas's short side.
    ///
    /// Measured from whichever corner the hand is on, along whichever axis the
    /// pointer travelled less — that is how a rounded corner grows, since the
    /// arc can only use what both sides give it. The radius is one number for
    /// the picture, but every corner can set it. Capped at half the short side,
    /// the same ceiling the renderer applies when it clips.
    static func cornerRadius(forPointer point: CGPoint, from corner: ImageCorner,
                             in imageRect: CGRect, canvasSize: CGSize) -> CGFloat {
        let short = min(canvasSize.width, canvasSize.height)
        guard short > 0 else { return 0 }
        let anchor = corner.point(in: imageRect)
        let reach = min(abs(point.x - anchor.x), abs(point.y - anchor.y))
        return min(0.5, max(0, reach / short))
    }

    /// The placement that puts a given gap at `value` on that edge, **keeping
    /// the opposite edge where it is** — so the picture resizes rather than
    /// slides.
    ///
    /// Moving instead would make the two ends of an axis fight: setting the top
    /// margin to 100 would drag the bottom one to −100 and back, and a
    /// symmetric 100/100 frame would be unreachable. Margins are what is left
    /// around the picture, so setting one decides how much room the picture
    /// gets — exactly what padding means.
    ///
    /// Note the arithmetic the aspect ratio forces: four margins are four
    /// numbers over a rectangle with three degrees of freedom, so the *other*
    /// axis follows along. 100/100 top and bottom is reachable; 100 on all four
    /// sides only if the picture's proportions happen to agree with the canvas.
    static func placement(_ placement: Presentation.ImagePlacement,
                          settingGap edge: Edge, to value: CGFloat,
                          imagePixelSize: CGSize, canvasSize: CGSize,
                          in presentation: Presentation) -> Presentation.ImagePlacement {
        let resolved = resolve(imagePixelSize: imagePixelSize, presentation)
        let imageSize = sanitizedSize(imagePixelSize)
        guard canvasSize.width > 0, canvasSize.height > 0,
              imageSize.width > 0, imageSize.height > 0,
              resolved.imageRect.width > 0, resolved.imageRect.height > 0
        else { return placement }

        let fit = min(canvasSize.width / imageSize.width,
                      canvasSize.height / imageSize.height)
        guard fit > 0 else { return placement }

        let gaps = self.gaps(resolved)
        var moved = placement
        switch edge {
        case .top, .bottom:
            let opposite = edge == .top ? gaps.bottom : gaps.top
            let height = canvasSize.height - value - opposite
            guard height > 0 else { return placement }
            moved.scale = height / (imageSize.height * fit)
            let centerY = edge == .top
                ? value + height / 2
                : canvasSize.height - value - height / 2
            moved.center.y = centerY / canvasSize.height
        case .leading, .trailing:
            let opposite = edge == .leading ? gaps.trailing : gaps.leading
            let width = canvasSize.width - value - opposite
            guard width > 0 else { return placement }
            moved.scale = width / (imageSize.width * fit)
            let centerX = edge == .leading
                ? value + width / 2
                : canvasSize.width - value - width / 2
            moved.center.x = centerX / canvasSize.width
        }
        return moved
    }

    enum Edge: CaseIterable, Sendable { case top, leading, bottom, trailing }

    /// Splits `delta` between the two margins of one axis, keeping whatever
    /// bias they already have. A picture deliberately pushed left stays pushed
    /// left; only when both sides are zero (or negative) is the delta halved.
    static func absorb(_ delta: CGFloat, into near: CGFloat, and far: CGFloat)
        -> (near: CGFloat, far: CGFloat) {
        let total = near + far
        guard total > 0 else { return (near + delta / 2, far + delta / 2) }
        return (near + delta * near / total, far + delta * far / total)
    }

    /// A centred placement leaving `margin` canvas pixels on the two edges the
    /// picture would otherwise touch.
    ///
    /// The aspect ratio is locked, so only one axis can be given an exact
    /// margin — the one that binds. The other gets whatever is left over, which
    /// is more, never less.
    static func placement(framingWith margin: CGFloat,
                          imagePixelSize: CGSize,
                          canvasSize: CGSize) -> Presentation.ImagePlacement {
        let image = sanitizedSize(imagePixelSize)
        guard image.width > 0, image.height > 0,
              canvasSize.width > 0, canvasSize.height > 0
        else { return .fitted }
        // Whichever axis the fit lands on is the one that touches the edges.
        let binding = canvasSize.width / image.width <= canvasSize.height / image.height
            ? canvasSize.width
            : canvasSize.height
        guard binding > 2 * margin else { return .fitted }
        return Presentation.ImagePlacement(center: CGPoint(x: 0.5, y: 0.5),
                                           scale: (binding - 2 * margin) / binding)
    }

    /// The whole canvas expressed in the image's own pixel coordinates — the
    /// space annotations live in.
    ///
    /// Annotations may be placed on the decorated background, so this, not the
    /// picture's bounds, is what a gesture clamps to. Without a presentation it
    /// is exactly `(0, 0, W, H)`, which is what the editor always allowed.
    static func annotationBounds(imagePixelSize: CGSize,
                                 _ resolved: Resolved) -> CGRect {
        let full = CGRect(origin: .zero, size: imagePixelSize)
        guard imagePixelSize.width > 0, imagePixelSize.height > 0,
              resolved.imageRect.width > 0, resolved.imageRect.height > 0
        else { return full }
        let scale = resolved.imageRect.width / imagePixelSize.width
        guard scale > 0, scale.isFinite else { return full }
        return CGRect(
            x: -resolved.imageRect.minX / scale,
            y: -resolved.imageRect.minY / scale,
            width: resolved.canvasSize.width / scale,
            height: resolved.canvasSize.height / scale
        )
    }
}

/// View-space geometry for the canvas and the image inside it.
///
/// The canvas owns zoom and pan, while annotations, hit testing, crop and
/// scan continue to speak image pixels. Keeping both transforms here makes
/// the unpresented path exactly the old letterbox calculation and gives the
/// presented path one source of truth for the two coordinate spaces.
nonisolated enum EditorCanvasGeometry {
    static let edgeInset: CGFloat = 24

    struct Resolved: Equatable, Sendable {
        let presentationLayout: PresentationLayout.Resolved
        let canvasScale: CGFloat
        let canvasOffset: CGPoint
        let canvasBaseDrawSize: CGSize
        let canvasDrawSize: CGSize
        let imageFitScale: CGFloat
        let imageOffset: CGPoint
        let imageDrawSize: CGSize
    }

    /// `canvasOriginOverride` puts the page somewhere other than the middle —
    /// see `canvasOrigin(pinning:)`, which is the only thing that asks.
    /// Where the page has to sit for `edge` to stay under the pointer.
    ///
    /// An auto page has no size of its own — it *is* the picture plus its
    /// margins — so dragging a margin resizes the page, and a page that resizes
    /// is re-fitted and re-centred on the next pass. Left alone, that moves the
    /// very edge the hand is holding: it travels at half the speed of the
    /// mouse, the other half going into recentring, and it slides sideways as
    /// the fit shrinks.
    ///
    /// Holding the fit instead was worse in its own way: the page grew straight
    /// out of the window and the margin being set could not be seen. So the fit
    /// is left alone — the whole page stays visible, as everywhere else in this
    /// editor — and the page is placed so that the edge in hand lands under the
    /// pointer. Only the axis being dragged is pinned; the other one stays
    /// centred, since nothing on it changed.
    static func canvasOrigin(pinning edge: PresentationLayout.Edge,
                             at viewPoint: CGPoint,
                             imageRect: CGRect,
                             canvasScale: CGFloat,
                             centred: CGPoint) -> CGPoint {
        switch edge {
        case .leading:
            return CGPoint(x: viewPoint.x - imageRect.minX * canvasScale, y: centred.y)
        case .trailing:
            return CGPoint(x: viewPoint.x - imageRect.maxX * canvasScale, y: centred.y)
        case .top:
            return CGPoint(x: centred.x, y: viewPoint.y - imageRect.minY * canvasScale)
        case .bottom:
            return CGPoint(x: centred.x, y: viewPoint.y - imageRect.maxY * canvasScale)
        }
    }

    static func resolve(viewport: CGSize,
                        imagePixelSize: CGSize,
                        presentation: Presentation?,
                        zoom: CGFloat,
                        pan: CGSize,
                        canvasOriginOverride: CGPoint? = nil) -> Resolved {
        let layout = PresentationLayout.resolve(
            imagePixelSize: imagePixelSize,
            presentation
        )
        let canvasSize = layout.canvasSize
        let availableWidth = max(1, finite(viewport.width) - edgeInset * 2)
        let availableHeight = max(1, finite(viewport.height) - edgeInset * 2)

        let baseScale: CGFloat
        if canvasSize.width > 0, canvasSize.height > 0 {
            baseScale = min(min(availableWidth / canvasSize.width,
                                availableHeight / canvasSize.height), 1)
        } else {
            baseScale = 1
        }
        let zoomScale = max(0, finite(zoom, fallback: 1))
        let canvasScale = baseScale * zoomScale
        let canvasBaseDrawSize = CGSize(
            width: canvasSize.width * baseScale,
            height: canvasSize.height * baseScale
        )
        let canvasDrawSize = CGSize(
            width: canvasBaseDrawSize.width * zoomScale,
            height: canvasBaseDrawSize.height * zoomScale
        )
        let canvasOffset = canvasOriginOverride ?? CGPoint(
            x: (finite(viewport.width) - canvasDrawSize.width) / 2
                + finite(pan.width),
            y: (finite(viewport.height) - canvasDrawSize.height) / 2
                + finite(pan.height)
        )

        let imageFitScale: CGFloat
        if imagePixelSize.width > 0 {
            imageFitScale = canvasScale * layout.imageRect.width / imagePixelSize.width
        } else {
            imageFitScale = 0
        }
        let imageOffset = CGPoint(
            x: canvasOffset.x + layout.imageRect.minX * canvasScale,
            y: canvasOffset.y + layout.imageRect.minY * canvasScale
        )
        let imageDrawSize = CGSize(
            width: max(0, finite(imagePixelSize.width)) * imageFitScale,
            height: max(0, finite(imagePixelSize.height)) * imageFitScale
        )

        return Resolved(
            presentationLayout: layout,
            canvasScale: canvasScale,
            canvasOffset: canvasOffset,
            canvasBaseDrawSize: canvasBaseDrawSize,
            canvasDrawSize: canvasDrawSize,
            imageFitScale: imageFitScale,
            imageOffset: imageOffset,
            imageDrawSize: imageDrawSize
        )
    }

    private static func finite(_ value: CGFloat, fallback: CGFloat = 0) -> CGFloat {
        value.isFinite ? value : fallback
    }
}
