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
        hasShadow            = true
        hidesOnDeactivate    = false
        ignoresMouseEvents   = false
        isReleasedWhenClosed = false
        appearance           = NSAppearance(named: .darkAqua)

        // NSWindow clamps every setFrame to these, so they have to admit both
        // states: the bare image at its floor and the plated window at its
        // ceiling. The image's own bounds are enforced by the resize math.
        minSize = minImageSize
        maxSize = CGSize(width: maxImageSize.width + 2 * band,
                         height: maxImageSize.height + 2 * band)

        let view = PinnedScreenshotView(
            imageURL: imageURL,
            maxPixelSize: maxPixelSize,
            imageSize: frame.size,   // at rest the window is exactly the picture
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
        let band = PinnedWindowGeometry.plateBand
        // The picture's size is not touched here — that is the whole point.
        setFrame(shown ? PinnedWindowGeometry.plated(frame, band: band)
                       : PinnedWindowGeometry.unplated(frame, band: band),
                 display: true)
        if let view = contentView as? PinnedHostingView {
            view.plateBand = shown ? band : 0
            // The corner cursors only exist while the plate does.
            view.updateTrackingAreas()
        }
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
            // Picture first, window second: setFrame lays the content view out
            // on the spot, so it picks up the new size in the same step rather
            // than filling the new frame for a beat.
            (self.contentView as? PinnedHostingView)?.rootView.imageSize =
                PinnedWindowGeometry.unplated(resized, band: band).size
            self.setFrame(resized, display: true)
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
    /// The picture's size in points, and the one thing here that never follows
    /// the window. The window is this plus a band on every side while the plate
    /// is up, so plating cannot scale or move what is on screen — only a resize
    /// changes this value, and then the window follows it, not the other way
    /// round. Deriving it from the window instead (fill, minus a padding) puts
    /// the picture one layout pass behind every frame change, which is visible
    /// as a jump in the image and in the corner radii.
    var imageSize: CGSize
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var loader = ThumbnailLoader()
    @State private var isHovered = false
    @State private var isCloseBadgePressed = false

    private let cornerRadius: CGFloat = 10

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
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.35 : 0.15), lineWidth: 1)
        )
        // Badge over the image's corner, not the plate's: the plate's four
        // corners are the resize grips, and a badge would sit on one of them.
        .overlay(alignment: .topTrailing) {
            ArchiveDeleteBadge(accessibilityLabelOverride: "Close",
                            action: onClose,
                            isPressed: $isCloseBadgePressed)
                .frame(width: 24, height: 24)
                .padding(2)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .help("Close")
        }
        // Centred in whatever the window currently is: at rest the window is
        // exactly the picture, while hovered it is one band larger all round.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The plate the capture thumbnail already uses, on the same errand:
        // something to grab that isn't the picture. Only while hovered — a pin
        // at rest is the image and nothing else. Its corners are concentric
        // with the picture's: one band further out, one band wider a radius.
        .background {
            RoundedRectangle(cornerRadius: cornerRadius + PinnedWindowGeometry.plateBand,
                             style: .continuous)
                .fill(Color.black.opacity(0.72))
                .opacity(isHovered ? 1 : 0)
                // Not faded in: the window grows in one step, and a plate
                // easing in behind it lags the edge it is supposed to be.
                .animation(nil, value: isHovered)
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
            isHovered = hovering
            onHoverChanged(hovering)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .task(id: imageURL) { loader.load(imageURL: imageURL, maxPixelSize: maxPixelSize) }
        .managedLocale()
        .accessibilityLabel("Pinned screenshot")
    }
}
