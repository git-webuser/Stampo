import AppKit
import SwiftUI

// MARK: - TextCaptureHUD

/// Transient toast confirming the outcome of a text/code-capture session.
/// Deliberately separate from ColorPickerHUD — that one is a live
/// cursor-following preview; this is a fire-and-forget confirmation.
final class TextCaptureHUD {
    enum Outcome {
        case copied
        case noTextFound
        case codeCopied
        case noCodeFound
    }

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    deinit {
        hideWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    func show(_ outcome: Outcome, on screen: NSScreen?, autoHideAfter delay: TimeInterval = 1.4) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: TextCaptureHUDView(outcome: outcome))
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        self.panel = panel

        if let target = screen ?? NSScreen.main {
            let f = target.visibleFrame
            let size = hosting.frame.size
            panel.setFrameOrigin(NSPoint(
                x: f.midX - size.width / 2,
                y: f.minY + f.height * 0.18
            ))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide(animated: Bool = true) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel?.orderOut(nil)
                self?.panel = nil
            })
        } else {
            panel.orderOut(nil)
            self.panel = nil
        }
    }
}

// MARK: - Content view

private struct TextCaptureHUDView: View {
    let outcome: TextCaptureHUD.Outcome

    var body: some View {
        Group {
            switch outcome {
            case .copied:
                statusRow(title: "Copied", systemName: "checkmark.circle", iconOpacity: 0.8)
            case .noTextFound:
                statusRow(title: "No text found", systemName: "text.viewfinder", iconOpacity: 0.6)
            case .codeCopied:
                statusRow(title: "Code Copied", systemName: "checkmark.circle", iconOpacity: 0.8)
            case .noCodeFound:
                statusRow(title: "No code found", systemName: "qrcode.viewfinder", iconOpacity: 0.6)
            }
        }
        .fixedSize()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .padding(12)
    }

    private func statusRow(title: LocalizedStringKey, systemName: String, iconOpacity: Double) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(iconOpacity))
        }
    }
}
