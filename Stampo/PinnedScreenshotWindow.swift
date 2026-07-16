import AppKit
import SwiftUI

// MARK: - PinnedScreenshotPanel

/// A single screenshot pinned above all normal windows: borderless, floating,
/// visible on every Space, never steals focus. One instance per pin — unlike
/// `ScreenshotThumbnailHUD`, which reuses a single transient panel.
final class PinnedScreenshotPanel: NSPanel {
    private var escMonitors: [Any] = []
    private var onClose: () -> Void

    init(imageURL: URL,
         frame: NSRect,
         imagePixelSize: CGSize,
         maxContentSize: CGSize,
         onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
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

        // Edge-resize keeps the image proportions; the floor and ceiling stop
        // a pin from becoming an unusable sliver or outgrowing the screen.
        contentAspectRatio = imagePixelSize
        let ar = max(imagePixelSize.width, 1) / max(imagePixelSize.height, 1)
        let minSide: CGFloat = 120
        minSize = ar >= 1
            ? NSSize(width: minSide * ar, height: minSide)
            : NSSize(width: minSide, height: minSide / ar)
        maxSize = maxContentSize

        let view = PinnedScreenshotView(
            imageURL: imageURL,
            onClose: { [weak self] in self?.requestClose() },
            onHoverChanged: { [weak self] hovering in
                hovering ? self?.installEsc() : self?.removeEsc()
            }
        )
        contentView = PinnedHostingView(rootView: view)
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
    // capture overlays' global+local monitor pair instead. Installed only
    // while the mouse is over this pin, so Esc closes exactly the hovered one.
    private func installEsc() {
        guard escMonitors.isEmpty else { return }
        installEscMonitors(into: &escMonitors) { [weak self] in
            self?.requestClose()
        }
    }

    private func removeEsc() {
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
    }
}

// MARK: - PinnedHostingView

/// Turns body-drags into window moves while leaving clicks, double-clicks and
/// the context menu to SwiftUI (same event split as `ThumbnailHostingView`).
final class PinnedHostingView: NSHostingView<PinnedScreenshotView> {
    required init(rootView: PinnedScreenshotView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - PinnedScreenshotView

struct PinnedScreenshotView: View {
    let imageURL: URL
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var loader = ThumbnailLoader()
    @State private var isHovered = false
    @State private var isCloseBadgePressed = false

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
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(isHovered ? 0.35 : 0.15), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            TrayDeleteBadge(action: onClose, isPressed: $isCloseBadgePressed)
                .frame(width: 24, height: 24)
                .padding(2)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .help("Close")
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(count: 2) { onClose() }
        .contextMenu {
            Button("Edit") {
                EditorWindowController.shared.open(url: imageURL)
            }
            Button("Copy") {
                NSPasteboard.general.writeImage(at: imageURL)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            }
            Divider()
            Button("Unpin") { onClose() }
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChanged(hovering)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .task(id: imageURL) { loader.load(imageURL: imageURL, maxPixelSize: 2048) }
        .managedLocale()
        .accessibilityLabel("Pinned screenshot")
    }
}
