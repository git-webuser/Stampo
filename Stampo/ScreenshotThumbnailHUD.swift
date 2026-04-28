import AppKit
import SwiftUI

// MARK: - ScreenshotThumbnailHUD

final class ScreenshotThumbnailHUD {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    /// Called when user taps the thumbnail — intended to open tray.
    var onTapped: (() -> Void)?

    /// Called when user deletes the screenshot from the context menu — intended to sync tray.
    var onDelete: (() -> Void)?

    // Reads image pixel dimensions inside the active security scope so CGImageSource
    // can open sandboxed files in user-chosen save directories.
    private func thumbnailSize(for imageURL: URL) -> CGSize {
        let maxW: CGFloat = 220, maxH: CGFloat = 160
        let minW: CGFloat = 80,  minH: CGFloat = 60
        let fallback = CGSize(width: maxW, height: maxH)

        let result = try? AppSettings.withSaveDirectoryAccess { _ in
            guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let pwNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let phNum = props[kCGImagePropertyPixelHeight] as? NSNumber
            else { return fallback }

            let pw = CGFloat(pwNum.intValue)
            let ph = CGFloat(phNum.intValue)
            guard pw > 0, ph > 0 else { return fallback }

            let ar = pw / ph
            var w = maxW
            var h = w / ar
            if h > maxH { h = maxH; w = h * ar }
            return CGSize(width: max(w, minW), height: max(h, minH))
        }
        return result ?? fallback
    }

    func show(imageURL: URL, on screen: NSScreen?) {
        guard AppSettings.showThumbnailHUD else { return }
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil

            let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
            let size = self.thumbnailSize(for: imageURL)
            let frame = self.frameBottomRight(size: size, on: screen)

            if self.panel == nil {
                self.panel = self.makePanel(frame: frame)
            }

            guard let panel = self.panel else { return }
            panel.setFrame(frame, display: true)

            let view = ScreenshotThumbnailView(
                imageURL: imageURL,
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
    }

    private func scheduleAutoHide() {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
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
            panel?.orderOut(nil)
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

        let item        = NSDraggingItem(pasteboardWriter: url as NSURL)
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
    let onDismiss: () -> Void
    let onDelete: () -> Void
    let onHoverChanged: (_ hovering: Bool, _ isPinned: Bool) -> Void
    let onPin: () -> Void
    let onUnpin: () -> Void

    @State private var loader = ThumbnailLoader()
    @State private var isPinned = false
    @State private var isHovered = false
    @State private var isPinBadgePressed = false
    @State private var isCloseBadgePressed = false

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))

            // Screenshot image
            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(12)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .padding(8)
                    )
            } else {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Screenshot")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(10)
            }

            // Title bar — slides in from the top edge on hover,
            // clipped by the rounded rectangle so it never overlaps outside.
            HStack(spacing: 0) {
                TrayDeleteBadge(
                    systemName: "pin.circle.fill",
                    isOn: isPinned,
                    action: {
                        isPinned.toggle()
                        isPinned ? onPin() : onUnpin()
                    },
                    isPressed: $isPinBadgePressed
                )
                .frame(width: 28, height: 28)
                .help(isPinned ? "Unpin" : "Pin")

                Spacer()

                TrayDeleteBadge(
                    action: { onDismiss() },
                    isPressed: $isCloseBadgePressed
                )
                .frame(width: 28, height: 28)
                .help("Close")
            }
            .padding(.horizontal, 2)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.5), Color.clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .offset(y: isHovered ? 0 : -34)
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
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open(imageURL, configuration: cfg)
            if !isPinned { onDismiss() }
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.writeImage(at: imageURL)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
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
