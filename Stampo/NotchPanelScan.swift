import AppKit
import OSLog
import Vision

// MARK: - ScanCaptureCoordinator

/// Owns the capture → Vision recognition → clipboard → HUD pipeline for the
/// panel's unified "Scan" action: one pass over the selected region finds every
/// QR/barcode payload and all readable text. Payloads are treated strictly as
/// plain text: never opened, linkified, or fetched from the network.
final class ScanCaptureCoordinator {
    private(set) var isInFlight: Bool = false
    private let hud = TextCaptureHUD()
    private let capturer = ScreenshotCapturer()

    /// Called once per finding on success — each barcode payload separately,
    /// then the recognized text — the owner stores them in the tray.
    var addText: (String) -> Void = { _ in }

    /// Stops an active scan without showing a result HUD. A result that arrives
    /// after cancellation is discarded on the main thread.
    @MainActor
    func cancel() {
        guard isInFlight else { return }
        isInFlight = false
        capturer.terminateCurrentCapture()
        hud.hide(animated: false)
    }

    @MainActor
    func scan(in rect: CGRect, on screen: NSScreen?) {
        guard !isInFlight else { return }
        isInFlight = true
        // Carry only the value-type display ID across the background closure;
        // NSScreen itself is main-thread-bound and not Sendable.
        let displayID = screen?.displayID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.captureAndRecognize(rect)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInFlight else { return }
                self.isInFlight = false
                let resultScreen = displayID.flatMap { id in
                    NSScreen.screens.first { $0.displayID == id }
                }
                guard let result else {
                    // Capture or Vision failed and was already logged. Avoid a
                    // misleading "nothing" message for an unavailable image.
                    return
                }
                guard !result.isEmpty else {
                    self.hud.show(.nothingRecognized, on: resultScreen)
                    return
                }
                // Copy as inert text only. In particular, URL-shaped payloads
                // are not opened or resolved.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.clipboardText, forType: .string)
                // The tray inserts each entry at the top, so add in reverse:
                // the topmost finding ends up as the topmost tray entry.
                if !result.text.isEmpty { self.addText(result.text) }
                for payload in result.codePayloads.reversed() { self.addText(payload) }
                self.hud.show(Self.outcome(for: result), on: resultScreen)
            }
        }
    }

    /// HUD toast for a non-empty result: the single-finding cases keep the
    /// existing toasts (payload preview included), anything richer reports
    /// counts.
    static func outcome(for result: ScanRecognition.Result) -> TextCaptureHUD.Outcome {
        switch (result.codePayloads.count, result.text.isEmpty) {
        case (0, _):
            return .copied
        case (1, true):
            return .codeCopied(payload: result.codePayloads[0])
        case (let codes, let noText):
            return .scanCopied(codes: codes, includesText: !noText)
        }
    }

    /// Blocking: captures the selected rect to a temporary image and runs the
    /// combined barcode + text recognition. Returns nil on capture/Vision
    /// failure and an empty result when nothing readable was found.
    private func captureAndRecognize(_ rect: CGRect) -> ScanRecognition.Result? {
        guard let tmpURL = capturer.captureRectToTemp(rect) else {
            if !capturer.lastCaptureWasCancelled && !capturer.lastCaptureWasBusy {
                Log.capture.error("scan capture failed: \(rect.debugDescription)")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            return try ScanRecognition.scan(in: tmpURL)
        } catch {
            Log.capture.error("scan recognition failed: \(error)")
            return nil
        }
    }
}

// MARK: - Scan orchestration

extension NotchPanelController {
    /// Launches the area-selection overlay and runs the unified scanner on the
    /// selected region. Mirrors `captureDirectly(mode: .selection)` for the
    /// overlay part and `pickColor()` for the hide-panel-first part.
    @MainActor
    func scan(on screen: NSScreen? = nil) {
        if let screen {
            currentScreen = screen
            updateScreenMetrics(for: screen)
        }
        guard !isInPreSelection, !scanCapture.isInFlight else { return }
        guard let target = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            self.state = .preSelection(.selection)
            self.selectionOverlay.onSelected = { [weak self] rect in
                guard let self else { return }
                self.state = .hidden
                // Let WindowServer remove the overlay from the framebuffer
                // before capturing the selected area.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.scanCapture.scan(in: rect, on: target)
                }
            }
            self.selectionOverlay.onCancelled = { [weak self] in
                self?.state = .hidden
            }
            self.selectionOverlay.start(on: target)
        }

        if isVisible && !needsSpaceRebind {
            hideAnimated(reason: .captureStart) { begin() }
        } else {
            begin()
        }
    }
}
