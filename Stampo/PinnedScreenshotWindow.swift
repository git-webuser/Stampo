import AppKit
import SwiftUI

// MARK: - PinnedScreenshotPanel

/// A single screenshot pinned above all normal windows: borderless, floating,
/// visible on every Space, never steals focus. One instance per pin — unlike
/// `ScreenshotThumbnailHUD`, which reuses a single transient panel.
final class PinnedScreenshotPanel: NSPanel {
    private var escObservation: EscObservation?
    private var onClose: () -> Void

    /// Aspect of the pinned image, kept for the plate-corner resize.
    private let imageAspect: CGFloat
    /// Bounds the image (not the window) may be resized between.
    private let minImageSize: CGSize
    private let maxImageSize: CGSize
    /// Whether the plate is currently shown — i.e. whether the window is one
    /// band larger than the image on every side.
    private var isPlated = false

    init(imageURL: URL,
         frame: NSRect,
         imagePixelSize: CGSize,
         maxContentSize: CGSize,
         maxPixelSize: CGFloat,
         onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.imageAspect = imagePixelSize.height > 0
            ? imagePixelSize.width / imagePixelSize.height
            : 1
        self.minImageSize = PinnedWindowGeometry.minWindowSize(
            imagePixels: imagePixelSize, maxContentSize: maxContentSize)
        let band = PinnedWindowGeometry.plateBand
        self.maxImageSize = CGSize(width: max(maxContentSize.width - 2 * band, 1),
                                   height: max(maxContentSize.height - 2 * band, 1))
        super.init(
            // Not .resizable: the edges of a borderless window are a two-point
            // target nobody can find, and on a narrow pin they collide with the
            // drag-to-move. The plate's corners do the resizing instead.
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel      = true
        // Above normal windows but below menus and HUDs (which use .statusBar
        // and .screenSaver) — pins are content, they shouldn't cover chrome.
        level                = .floating
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque             = false
        backgroundColor      = .clear
        // No drop shadow. AppKit cuts one from whatever a transparent window's
        // content last drew and keeps that shape: the pin's outline changes
        // whenever the plate appears or the picture is resized, and the old
        // shadow stayed behind as a grey line with a rounding of its own,
        // visibly not the corner it sat under. Reshaping it on every change is
        // a race against the redraw — the capture thumbnail does without a
        // shadow too, and leans on its plate.
        hasShadow            = false
        hidesOnDeactivate    = false
        ignoresMouseEvents   = false
        isReleasedWhenClosed = false
        appearance           = NSAppearance(named: .darkAqua)

        // NSWindow clamps every setFrame to these, so they have to admit both
        // states: the picture at its floor inside the resting plate, and the
        // picture at its ceiling inside the hovered one. The picture's own
        // bounds are enforced by the resize math.
        let resting = PinnedWindowGeometry.restingBand
        minSize = CGSize(width: minImageSize.width + 2 * resting,
                         height: minImageSize.height + 2 * resting)
        maxSize = CGSize(width: maxImageSize.width + 2 * band,
                         height: maxImageSize.height + 2 * band)

        let view = PinnedScreenshotView(
            imageURL: imageURL,
            maxPixelSize: maxPixelSize,
            onClose: { [weak self] in self?.requestClose() },
            onHoverChanged: { [weak self] hovering in
                guard let self else { return }
                hovering ? self.installEsc() : self.removeEsc()
                self.setPlate(shown: hovering)
            }
        )
        contentView = PinnedHostingView(rootView: view)
    }

    // MARK: Hover plate

    /// Grows the window by one band on every side so the plate has somewhere to
    /// draw, leaving the image exactly where it was. The SwiftUI side insets its
    /// image by the same band in the same hover change, so the picture on screen
    /// does not move.
    private func setPlate(shown: Bool) {
        guard isPlated != shown else { return }
        isPlated = shown
        // Only the difference: the resting plate is already around the picture,
        // so the window gains what the hovered one adds on top of it.
        let growth = PinnedWindowGeometry.hoverGrowth
        setFrameWithoutAnimating(shown ? PinnedWindowGeometry.plated(frame, band: growth)
                                       : PinnedWindowGeometry.unplated(frame, band: growth))
        if let view = contentView as? PinnedHostingView {
            view.plateBand = shown ? PinnedWindowGeometry.plateBand : 0
            // The corner cursors only exist while the plate does.
            view.updateTrackingAreas()
        }
    }

    /// A frame change with no layer animation — sixty interpolations a second
    /// is a shimmer of its own during a live resize.
    private func setFrameWithoutAnimating(_ frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(frame, display: true)
        CATransaction.commit()
    }

    // MARK: Plate-corner resize

    /// Drags the given corner until the mouse comes up, keeping the opposite
    /// corner and the image's aspect fixed. Runs its own event loop the way
    /// `performDrag` does for moves, so the gesture cannot be interrupted by a
    /// SwiftUI re-render mid-drag.
    func resize(from corner: PinnedWindowGeometry.PlateZone, startingWith event: NSEvent) {
        let startFrame = frame
        let startMouse = NSEvent.mouseLocation
        let band = PinnedWindowGeometry.plateBand

        trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                    timeout: NSEvent.foreverDuration,
                    mode: .eventTracking) { tracked, stop in
            guard let tracked else { stop.pointee = true; return }
            if tracked.type == .leftMouseUp { stop.pointee = true; return }

            let mouse = NSEvent.mouseLocation
            let translation = CGSize(width: mouse.x - startMouse.x,
                                     height: mouse.y - startMouse.y)
            let resized = PinnedWindowGeometry.resized(startFrame,
                                                       corner: corner,
                                                       translation: translation,
                                                       imageAspect: self.imageAspect,
                                                       band: band,
                                                       minImageSize: self.minImageSize,
                                                       maxImageSize: self.maxImageSize)
            // Only the window: the picture is what is left of it after the
            // plate, so it follows in the same layout pass. Nothing here is
            // SwiftUI state, and nothing can therefore arrive a pass late.
            // Actions off so no layer interpolates its way to the new size —
            // sixty of those a second is a shimmer of its own.
            self.setFrameWithoutAnimating(resized)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Called by the controller before ordering out so the Esc monitors never
    /// outlive the pin (closing via Esc happens while hovered, i.e. installed).
    func prepareForClose() {
        removeEsc()
    }

    private func requestClose() {
        onClose()
    }

    // MARK: Esc handling

    // The panel never becomes key, so keyDown never routes to it; reuse the
    // capture overlays' EscObservation instead. Installed only while the
    // mouse is over this pin, so Esc closes exactly the hovered one.
    private func installEsc() {
        guard escObservation == nil else { return }
        escObservation = EscObservation { [weak self] in
            self?.requestClose()
        }
    }

    private func removeEsc() {
        escObservation?.cancel()
        escObservation = nil
    }
}

// MARK: - PinnedHostingView

/// Turns body-drags into window moves and plate-corner drags into resizes,
/// while leaving clicks, double-clicks and the context menu to SwiftUI (same
/// event split as `ThumbnailHostingView`).
final class PinnedHostingView: NSHostingView<PinnedScreenshotView> {
    /// Width of the plate currently drawn around the image; 0 while the pointer
    /// is away and there is no plate to grab. Set by the panel on hover.
    var plateBand: CGFloat = 0

    required init(rootView: PinnedScreenshotView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Point in the bottom-left origin the geometry works in. NSHostingView is
    /// flipped, so a raw converted point would mirror top and bottom — and a
    /// drag on the visual top-left corner would resize from the bottom one.
    private func geometryPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: isFlipped ? bounds.height - point.y : point.y)
    }

    /// Corner rect in this view's own coordinates, wherever its origin is.
    private func cornerRect(top: Bool, left: Bool, reach: CGFloat) -> NSRect {
        let x = left ? bounds.minX : bounds.maxX - reach
        let atTop = isFlipped ? bounds.minY : bounds.maxY - reach
        let atBottom = isFlipped ? bounds.maxY - reach : bounds.minY
        return NSRect(x: x, y: top ? atTop : atBottom, width: reach, height: reach)
    }

    // The zone is read from the first drag event rather than remembered from
    // the press: whichever branch it takes swallows the rest of the gesture in
    // its own tracking loop, so there is nothing to carry between events — and
    // nothing that can go stale if SwiftUI eats a press.
    override func mouseDragged(with event: NSEvent) {
        guard let panel = window as? PinnedScreenshotPanel else {
            window?.performDrag(with: event)
            return
        }
        let zone = plateBand > 0
            ? PinnedWindowGeometry.zone(at: geometryPoint(event),
                                        in: bounds.size,
                                        band: plateBand)
            : .body
        if zone == .body {
            panel.performDrag(with: event)
        } else {
            panel.resize(from: zone, startingWith: event)
        }
    }

    // MARK: Cursors

    /// The four corners, in the order their tracking areas refer to them.
    private static let corners: [(top: Bool, left: Bool, position: NSCursor.FrameResizePosition)] = [
        (false, true,  .bottomLeft),
        (false, false, .bottomRight),
        (true,  true,  .topLeft),
        (true,  false, .topRight)
    ]

    /// Marks our own tracking areas so SwiftUI's are left alone.
    private static let cornerKey = "pinPlateCorner"

    /// Diagonal resize cursors over the plate's corners — the only thing saying
    /// the corners do something the rest of the plate doesn't. Tracking areas
    /// rather than cursor rects: a pin never becomes key, and cursor rects are
    /// dead in a window that isn't.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?[Self.cornerKey] != nil {
            removeTrackingArea(area)
        }
        guard plateBand > 0 else { return }
        let reach = PinnedWindowGeometry.cornerReach
        for (index, corner) in Self.corners.enumerated() {
            addTrackingArea(NSTrackingArea(
                rect: cornerRect(top: corner.top, left: corner.left, reach: reach),
                options: [.activeAlways, .cursorUpdate],
                owner: self,
                userInfo: [Self.cornerKey: index]
            ))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?[Self.cornerKey] as? Int,
              Self.corners.indices.contains(index)
        else { return super.cursorUpdate(with: event) }
        NSCursor.frameResize(position: Self.corners[index].position, directions: .all).set()
    }
}

// MARK: - PinnedScreenshotView

struct PinnedScreenshotView: View {
    let imageURL: URL
    let maxPixelSize: CGFloat
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var loader = ThumbnailLoader()
    @State private var isHovered = false
    /// The title bar's own state, moved a beat by `withAnimation` rather than
    /// by an `.animation(_:value:)` on `isHovered` — the one departure from the
    /// thumbnail, which needs none of this because its panel does not change
    /// size when the pointer arrives. That modifier animates everything the bar
    /// does when the hover changes, and here the plate widens in the same
    /// breath: the picture's trailing edge lands a fraction elsewhere and the
    /// badge pinned to it visibly travelled in X as well as Y, as if something
    /// invisible were scaling under it. Driven from here, only the slide is
    /// animated and the rest of the layout settles in the frame it happens.
    @State private var isBadgeShown = false

    private let cornerRadius: CGFloat = 10

    /// The plate's width: a hairline at rest, a grabbable band under the
    /// pointer. The picture is what is left of the window after it, which is
    /// the whole trick: during a resize the window changes and the picture
    /// follows it inside the same layout pass, with nothing to fall behind.
    /// Holding the picture's size as state instead — and setting it beside
    /// every `setFrame` — put it one pass behind the window for the length of a
    /// drag, and the band pulsed with every event: a tremor of its own, in
    /// place of the one that was fixed before it.
    private var band: CGFloat {
        isHovered ? PinnedWindowGeometry.plateBand : PinnedWindowGeometry.restingBand
    }

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    Color.black.opacity(0.45)
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The capture thumbnail's title bar, as it is there: the badge rides in
        // on a gradient that darkens the top edge under it, which is what keeps
        // a white glyph legible over a bright capture. One badge instead of two
        // — a pin has nothing to pin — and it lives inside the clip so it can
        // wait out of sight above the top edge.
        //
        // Over the picture's corner rather than the plate's: the plate's four
        // corners are the resize grips, and a badge would sit on one of them.
        .overlay(alignment: .top) {
            // A hair off the picture's corner, the same on both sides and the
            // top: flush against a rounded corner is not a place for a badge.
            BadgeBar(isShown: isBadgeShown, inset: 2) {
                HStack(spacing: 0) {
                    Spacer()
                    ArchiveDeleteBadge(accessibilityLabelOverride: "Close", action: onClose)
                        .frame(width: 28, height: 28)
                        .help("Close")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // The window grew by this much when the pointer arrived, so the picture
        // keeps the size and the place it had — the plate widens around it.
        .padding(band)
        // The plate the capture thumbnail already uses, on two errands here: a
        // hairline that stands the pin off its background in place of the drop
        // shadow, widening under the pointer into something to grab that isn't
        // the picture. Its corners stay concentric with the picture's — one
        // band further out, one band wider a radius.
        .background {
            RoundedRectangle(cornerRadius: cornerRadius + band, style: .continuous)
                .fill(Color.black.opacity(0.72))
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture(count: 2) { onClose() }
        .contextMenu {
            MenuCommandButton("Edit", icon: .edit) {
                EditorWindowController.shared.open(url: imageURL)
            }
            MenuCommandButton("Copy", icon: .copy) {
                NSPasteboard.general.writeImage(at: imageURL)
            }
            MenuCommandButton("Show in Finder", icon: .finder) {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            }
            Divider()
            MenuCommandButton("Unpin", icon: .unpin) { onClose() }
            if PinnedScreenshotController.shared.count > 1 {
                MenuCommandButton("Close All Pins", icon: .unpinAll) {
                    PinnedScreenshotController.shared.closeAll()
                }
            }
        }
        .onHover { hovering in
            // The plate and the window it lives in change on the spot; only the
            // badge is given a beat, and only for the slide.
            isHovered = hovering
            // The thumbnail's spring, to the number.
            withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
                isBadgeShown = hovering
            }
            onHoverChanged(hovering)
        }
        // No blanket animation on the hover state: it would take the padding
        // with it and ease the picture between two sizes while the window has
        // already jumped. The stroke and the badge ask for their own fade,
        // above; the geometry stays instant.
        .task(id: imageURL) { loader.load(imageURL: imageURL, maxPixelSize: maxPixelSize) }
        .managedLocale()
        .accessibilityLabel("Pinned screenshot")
    }
}
