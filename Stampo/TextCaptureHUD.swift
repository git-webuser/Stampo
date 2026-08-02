import AppKit
import SwiftUI

// MARK: - TextCaptureHUD

/// Transient toast confirming the outcome of a capture or editor action.
/// Deliberately separate from ColorPickerHUD — that one is a live
/// cursor-following preview; this is a fire-and-forget confirmation.
final class TextCaptureHUD {
    enum Outcome {
        case copied
        case saved
        /// Carries the scanned payload so the toast can preview what actually
        /// landed on the clipboard — unlike OCR, the user never saw this text.
        case codeCopied(payload: String)
        /// Multi-finding scan: two or more codes, or codes mixed with text.
        case scanCopied(codes: Int, includesText: Bool)
        /// Unified editor scanner found neither a code nor text in the region.
        case nothingRecognized
        /// "Pin last screenshot" hotkey fired with nothing captured yet.
        case noScreenshotToPin
        /// "Share last item" hotkey fired on an empty archive.
        case nothingToShare
        /// A folder headed for the share sheet couldn't be zipped (unreadable,
        /// or a location the app has no permission for).
        case shareNotPrepared
        /// Shown only while a slow folder is being zipped for the share sheet.
        case preparingShare
        /// A drop on the AirDrop plate that AirDrop refused to take.
        case airDropUnavailable
    }

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    /// Collapses multiline payloads (vCard, Wi-Fi) to one displayable line and
    /// caps the length — the visible toast only ever fits ~40 characters, so
    /// measuring a multi-kilobyte payload would be wasted work.
    static func payloadPreview(_ payload: String) -> String {
        String(payload.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(256))
    }

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
                    .fixedSize()
            case .saved:
                statusRow(title: "Saved", systemName: "checkmark.circle", iconOpacity: 0.8)
                    .fixedSize()
            case .codeCopied(let payload):
                VStack(spacing: 3) {
                    statusRow(title: "Code Copied", systemName: "checkmark.circle", iconOpacity: 0.8)
                        .fixedSize()
                    // Secondary preview of the clipboard contents. Verbatim keeps
                    // URL-shaped payloads inert; middle truncation preserves the
                    // scheme+host and tail of long URLs.
                    Text(verbatim: TextCaptureHUD.payloadPreview(payload))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 280)
                }
            case .scanCopied(let codes, let includesText):
                Group {
                    if includesText {
                        statusRow(title: "\(codes) codes and text copied",
                                  systemName: "checkmark.circle", iconOpacity: 0.8)
                    } else {
                        statusRow(title: "\(codes) codes copied",
                                  systemName: "checkmark.circle", iconOpacity: 0.8)
                    }
                }
                .fixedSize()
            case .nothingRecognized:
                statusRow(title: "Nothing recognized", systemName: "doc.viewfinder", iconOpacity: 0.6)
                    .fixedSize()
            case .noScreenshotToPin:
                statusRow(title: "No recent screenshot", systemName: "pin.slash", iconOpacity: 0.6)
                    .fixedSize()
            case .nothingToShare:
                statusRow(title: "Nothing to share", systemName: "square.and.arrow.up", iconOpacity: 0.6)
                    .fixedSize()
            case .preparingShare:
                statusRow(title: "Preparing to share…", systemName: "shippingbox", iconOpacity: 0.6)
                    .fixedSize()
            case .airDropUnavailable:
                statusRow(title: "AirDrop isn't available", systemName: "airplayaudio", iconOpacity: 0.6)
                    .fixedSize()
            case .shareNotPrepared:
                statusRow(title: "Couldn't prepare the folder for sharing",
                          systemName: "folder.badge.questionmark", iconOpacity: 0.6)
                    .fixedSize()
            }
        }
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
