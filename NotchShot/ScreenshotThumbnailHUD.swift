import AppKit
import SwiftUI

// MARK: - ScreenshotThumbnailHUD

final class ScreenshotThumbnailHUD {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private let size = CGSize(width: 220, height: 150)

    /// Called when user taps the thumbnail — intended to open tray.
    var onTapped: (() -> Void)?

    func show(imageURL: URL, on screen: NSScreen?) {
        guard AppSettings.showThumbnailHUD else { return }
        DispatchQueue.main.async {
            self.dismissWorkItem?.cancel()
            self.dismissWorkItem = nil

            let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
            let frame = self.frameBottomRight(on: screen)

            if self.panel == nil {
                self.panel = self.makePanel(frame: frame)
            }

            guard let panel = self.panel else { return }
            panel.setFrame(frame, display: true)

            let view = ScreenshotThumbnailView(
                imageURL: imageURL,
                onDismiss: { [weak self] in self?.hide(animated: true) },
                onTapped: { [weak self] in
                    self?.hide(animated: true)
                    self?.onTapped?()
                },
                onHoverChanged: { [weak self] hovering in
                    guard let self else { return }
                    if hovering {
                        self.dismissWorkItem?.cancel()
                        self.dismissWorkItem = nil
                    } else {
                        self.scheduleAutoHide()
                    }
                }
            )

            if let hosting = panel.contentView as? NSHostingView<ScreenshotThumbnailView> {
                hosting.rootView = view
            } else {
                panel.contentView = NSHostingView(rootView: view)
            }

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

    private func frameBottomRight(on screen: NSScreen?) -> NSRect {
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

// MARK: - ScreenshotThumbnailView

struct ScreenshotThumbnailView: View {
    let imageURL: URL
    let onDismiss: () -> Void
    let onTapped: () -> Void
    let onHoverChanged: (Bool) -> Void

    @StateObject private var loader = ThumbnailLoader()
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragging: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(radius: 18, y: 10)

            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
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
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .offset(dragOffset)
        .opacity(opacityForDrag)
        .scaleEffect(scaleForDrag)
        .gesture(dismissDragGesture)
        .onTapGesture {
            onTapped()
        }
        .onDrag {
            NSItemProvider(contentsOf: imageURL) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.writeImage(at: imageURL)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([imageURL])
            }
            Divider()
            Button("Delete") {
                do {
                    try FileManager.default.removeItem(at: imageURL)
                } catch {
                    #if DEBUG
                    print("[ThumbnailHUD] removeItem failed: \(error)")
                    #endif
                }
                onDismiss()
            }
        }
        .onHover { onHoverChanged($0) }
        .task(id: imageURL) { loader.load(imageURL: imageURL, maxPixelSize: 440) }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let t = value.translation
                let distance = hypot(t.width, t.height)
                if distance > 90 {
                    withAnimation(.easeIn(duration: 0.16)) {
                        dragOffset = CGSize(width: t.width * 2.2, height: t.height * 2.2)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                        onDismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private var opacityForDrag: Double {
        let d = min(1.0, Double(hypot(dragOffset.width, dragOffset.height) / 180.0))
        return 1.0 - 0.25 * d
    }

    private var scaleForDrag: CGFloat {
        let d = min(1.0, CGFloat(hypot(dragOffset.width, dragOffset.height) / 220.0))
        return 1.0 - 0.05 * d
    }
}
