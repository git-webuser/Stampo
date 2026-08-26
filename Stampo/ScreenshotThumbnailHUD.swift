import AppKit
import SwiftUI

// MARK: - ThumbnailHUDGeometry

/// Pure layout math for the capture thumbnail, kept free of AppKit state so it
/// is unit-testable — the same arrangement as `PinnedWindowGeometry`.
///
/// The picture is sized first and the panel is that plus a band on every side,
/// never the other way round: sizing the panel to the capture's aspect and then
/// insetting the picture inside it leaves the band uneven for every shape but
/// one (a 16:10 capture came out with 12.8 pt down the sides against 8 pt top
/// and bottom).
enum ThumbnailHUDGeometry {
    /// The plate showing around the picture on every side.
    static let inset: CGFloat = 8
    /// Corner radius of the plate; the picture's own is this minus the inset,
    /// so the two roundings are concentric.
    static let plateRadius: CGFloat = 16
    static var imageRadius: CGFloat { plateRadius - inset }

    /// Largest and smallest the picture itself may be. The floor is what the
    /// chrome needs: two 28 pt badges side by side in the bar that slides in
    /// across the top, plus the band.
    static let maxImageBox = CGSize(width: 204, height: 144)
    static let minImageBox = CGSize(width: 64, height: 44)

    struct Layout: Equatable {
        /// Where the picture is drawn, inside the panel, band excluded.
        var imageBox: CGSize
        /// True when the capture is too far from square to be shown whole at
        /// this size: it fills the box and is clipped instead of shrinking to a
        /// thread down the middle of a plate.
        var cropsToFill: Bool

        var panelSize: CGSize {
            CGSize(width: imageBox.width + 2 * inset, height: imageBox.height + 2 * inset)
        }
    }

    /// Aspect-fits the capture into `maxImageBox`, then raises whichever side
    /// falls under the floor. Raising a side is exactly what makes a crop
    /// necessary — and only by as much as was raised, so the crop starts at
    /// nothing on the threshold and grows from there rather than jumping.
    static func layout(imagePixels: CGSize) -> Layout {
        guard imagePixels.width > 0, imagePixels.height > 0 else {
            return Layout(imageBox: maxImageBox, cropsToFill: false)
        }
        let aspect = imagePixels.width / imagePixels.height
        var box = aspect >= maxImageBox.width / maxImageBox.height
            ? CGSize(width: maxImageBox.width, height: maxImageBox.width / aspect)
            : CGSize(width: maxImageBox.height * aspect, height: maxImageBox.height)

        let cropped = box.width < minImageBox.width || box.height < minImageBox.height
        box.width = max(box.width, minImageBox.width)
        box.height = max(box.height, minImageBox.height)
        return Layout(imageBox: box, cropsToFill: cropped)
    }
}

// MARK: - ScreenshotThumbnailHUD

@MainActor
final class ScreenshotThumbnailHUD {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    /// Called when user taps the thumbnail — intended to open archive.
    var onTapped: (() -> Void)?

    /// Called when user deletes the screenshot from the context menu — intended to sync archive.
    var onDelete: (() -> Void)?

    // Reads image pixel dimensions inside the active security scope so CGImageSource
    // can open sandboxed files in user-chosen save directories.
    private func thumbnailLayout(for imageURL: URL) -> ThumbnailHUDGeometry.Layout {
        let fallback = ThumbnailHUDGeometry.layout(imagePixels: .zero)

        let result = try? AppSettings.withSaveDirectoryAccess { _ in
            guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let pwNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let phNum = props[kCGImagePropertyPixelHeight] as? NSNumber
            else { return fallback }

            return ThumbnailHUDGeometry.layout(
                imagePixels: CGSize(width: pwNum.intValue, height: phNum.intValue))
        }
        return result ?? fallback
    }

    func show(imageURL: URL, on screen: NSScreen?) {
        guard AppSettings.showThumbnailHUD else { return }
        self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil

            let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
            let layout = self.thumbnailLayout(for: imageURL)
            let frame = self.frameBottomRight(size: layout.panelSize, on: screen)

            if self.panel == nil {
                self.panel = self.makePanel(frame: frame)
            }

            guard let panel = self.panel else { return }
            panel.setFrame(frame, display: true)

            let view = ScreenshotThumbnailView(
                imageURL: imageURL,
                layout: layout,
                onDismiss: { [weak self] in self?.hide(animated: true) },
                onDelete: { [weak self] in self?.onDelete?() },
                onHoverChanged: { [weak self] hovering, pinned in
                    guard let self else { return }
                    if hovering {
                        self.dismissWorkItem?.cancel()
                        self.dismissWorkItem = nil
                    } else if !pinned {
                        self.scheduleAutoHide()
                    }
                },
                onPin: { [weak self] in
                    // Cancel auto-dismiss while pinned.
                    self?.dismissWorkItem?.cancel()
                    self?.dismissWorkItem = nil
                },
                onUnpin: { [weak self] in
                    // Resume timer from now with the full configured delay.
                    self?.scheduleAutoHide()
                }
            )

            // Always create a fresh hosting view so @State resets.
            let hosting = ThumbnailHostingView(rootView: view)
            hosting.fileURL = imageURL
            // When the user swipes the thumbnail away, cancel auto-hide and order out.
            hosting.onDismiss = { [weak self] in self?.hide(animated: false) }
            panel.contentView = hosting

            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }

        self.scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.hide(animated: true) }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.thumbnailDismissDelay, execute: work)
    }

    private func hide(animated: Bool) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        guard let panel else { return }

        if !animated {
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            Task { @MainActor [weak panel] in panel?.orderOut(nil) }
        }
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel    = true
        p.level              = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque           = false
        p.backgroundColor    = .clear
        p.hasShadow          = false
        p.hidesOnDeactivate  = false
        p.ignoresMouseEvents = false
        p.appearance         = NSAppearance(named: .darkAqua)
        return p
    }

    private func frameBottomRight(size: CGSize, on screen: NSScreen?) -> NSRect {
        guard let screen else {
            return NSRect(x: 0, y: 0, width: size.width, height: size.height)
        }
        let vf = screen.visibleFrame
        let margin: CGFloat = 18
        let x = vf.maxX - margin - size.width
        let y = vf.minY + margin
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - ThumbnailHostingView

/// NSHostingView subclass that handles both rightward-swipe dismiss and
/// AppKit-based file drag (NSDraggingSource via a delegate object).
///
/// All drag logic lives here so SwiftUI's DragGesture never competes with
/// system gestures (Mission Control, Spaces) or AppKit drag sessions.
///
/// Dismiss vs. file-drag disambiguation:
///   • elapsed < 200 ms when dist ≥ 8 px  →  dismiss swipe (panel slides right)
///   • elapsed ≥ 200 ms, velocity < 600 px/s  →  file drag (AppKit session)
final class ThumbnailHostingView: NSHostingView<ScreenshotThumbnailView> {

    var fileURL: URL?
    /// Called after the panel has been animated off-screen by a dismiss swipe.
    var onDismiss: (() -> Void)?

    private let dragSource            = DragSource()
    private var fileDragStarted       = false
    private var mouseDownScreenPoint  = NSPoint.zero
    private var mouseDownTime         = Date()

    required init(rootView: ScreenshotThumbnailView) {
        super.init(rootView: rootView)
        dragSource.onSessionEnded = { [weak self] in
            DispatchQueue.main.async { self?.fileDragStarted = false }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Mouse tracking

    override func mouseDown(with event: NSEvent) {
        mouseDownTime        = Date()
        mouseDownScreenPoint = NSEvent.mouseLocation
        fileDragStarted      = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !fileDragStarted else { return }

        let screen  = NSEvent.mouseLocation
        let dx      = screen.x - mouseDownScreenPoint.x
        let dy      = screen.y - mouseDownScreenPoint.y
        let dist    = hypot(dx, dy)
        let elapsed = Date().timeIntervalSince(mouseDownTime)

        // After holding ≥ 200 ms the user may drag the file.
        if let url = fileURL,
           elapsed >= 0.20,
           dist >= 8,
           dist / max(elapsed, 0.001) < 600 {
            startFileDrag(url: url, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }

    // MARK: File drag

    private func startFileDrag(url: URL, event: NSEvent) {
        fileDragStarted = true

        // In the format the user picked, like every other way a capture leaves
        // — a capture already in it is dragged as itself, untouched.
        let dragged     = CaptureExport.fileURL(for: url)
        let item        = NSDraggingItem(pasteboardWriter: dragged as NSURL)
        let previewSize = NSSize(width: max(bounds.width * 0.75, 1),
                                 height: max(bounds.height * 0.75, 1))
        let dragImage   = NSImage(size: previewSize, flipped: false) { _ in true }
        item.setDraggingFrame(NSRect(origin: .zero, size: previewSize), contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: dragSource)
    }
}

// Separate NSDraggingSource because NSHostingView already inherits the
// conformance from NSView and its draggingSession methods are public (not open).
private final class DragSource: NSObject, NSDraggingSource {
    var accessedURL: URL?
    var onSessionEnded: (() -> Void)?

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        accessedURL = nil
        onSessionEnded?()
    }
}

// MARK: - ScreenshotThumbnailView

struct ScreenshotThumbnailView: View {
    let imageURL: URL
    /// Where the picture goes inside the panel, and whether it has to be
    /// cropped to get there. Decided once, by the HUD that sized the panel, so
    /// the band around the picture is the same 8 pt the panel was built with.
    var layout: ThumbnailHUDGeometry.Layout = ThumbnailHUDGeometry.layout(imagePixels: .zero)
    let onDismiss: () -> Void
    let onDelete: () -> Void
    let onHoverChanged: (_ hovering: Bool, _ isPinned: Bool) -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void

    @State private var loader = ThumbnailLoader()
    @State private var isPinned = false
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            RoundedRectangle(cornerRadius: ThumbnailHUDGeometry.plateRadius, style: .continuous)
                .fill(Color.black.opacity(0.72))

            // Screenshot image, in the box the panel was sized around: the
            // plate is then the same width on every side by construction. A
            // capture too far from square to be shown whole at this size fills
            // the box and is clipped — see ThumbnailHUDGeometry.
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: layout.cropsToFill ? .fill : .fit)
                    .frame(width: layout.imageBox.width, height: layout.imageBox.height)
                    .clipShape(RoundedRectangle(cornerRadius: ThumbnailHUDGeometry.imageRadius,
                                                style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: ThumbnailHUDGeometry.imageRadius,
                                         style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    // Centred in the panel: the ZStack aligns to the top for
                    // the title bar's sake, which is not where a picture goes.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Screenshot")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(10)
            }

            // Title bar — slides in from the top edge on hover, clipped by the
            // rounded rectangle so it never overlaps outside. Inset towards the
            // picture's corners rather than the plate's, where a pin's badge
            // sits; half the band, because on a panel this small the full one
            // pushes the badges further in than they look right.
            BadgeBar(isShown: isHovered, inset: ThumbnailHUDGeometry.inset / 2) {
                HStack(spacing: 0) {
                    ArchiveDeleteBadge(
                        systemName: "pin.circle.fill",
                        isOn: isPinned,
                        action: {
                            isPinned.toggle()
                            isPinned ? onPin() : onUnpin()
                        }
                    )
                    .frame(width: 28, height: 28)
                    .help(isPinned ? "Unpin" : "Pin")

                    Spacer()

                    ArchiveDeleteBadge(action: { onDismiss() })
                        .frame(width: 28, height: 28)
                        .help("Close")
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isHovered)
        }
        // clipShape keeps the sliding bar clipped to the rounded rectangle —
        // the bar slides in from above the top edge without ever appearing outside.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Stroke drawn after clip so it renders at full width on the edge.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isPinned ? Color.white.opacity(0.28) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            switch AppSettings.thumbnailClickAction {
            case .editor:
                EditorWindowController.open(url: imageURL)
            case .preview:
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open(imageURL, configuration: cfg)
            }
            if !isPinned { onDismiss() }
        }
        .contextMenu {
            MenuCommandButton("Edit", icon: .edit) {
                EditorWindowController.open(url: imageURL)
                if !isPinned { onDismiss() }
            }
            MenuCommandButton("Copy", icon: .copy) {
                NSPasteboard.general.writeImage(at: imageURL)
            }
            // Distinct from the HUD's own pin badge, which merely keeps the
            // HUD from auto-dismissing — this creates a floating pin window.
            MenuCommandButton("Pin to Screen", icon: .pin) {
                PinnedScreenshotController.shared.pin(url: imageURL)
                if !isPinned { onDismiss() }
            }
            MenuCommandButton("Show in Finder", icon: .finder) {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            }
            Divider()
            MenuCommandButton("Move to Trash", icon: .trash, role: .destructive) {
                NSWorkspace.shared.recycle([imageURL]) { _, _ in
                    DispatchQueue.main.async {
                        onDelete()
                        onDismiss()
                    }
                }
            }
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering, isPinned)
        }
        .task(id: imageURL) { loader.load(imageURL: imageURL, maxPixelSize: 440) }
        .managedLocale()
    }
}
