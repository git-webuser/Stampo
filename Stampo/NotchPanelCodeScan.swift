import AppKit
import OSLog
import Vision

// MARK: - CodeRecognition

enum CodeRecognition {
    /// Runs Vision barcode detection locally and returns the highest-confidence
    /// non-empty text payload. The result is never interpreted as a URL.
    static func payload(in imageURL: URL) throws -> String {
        let handler = VNImageRequestHandler(url: imageURL)
        return try payload(using: handler)
    }

    /// CGImage overload used by the editor, where the selected region already
    /// exists in memory and does not need a temporary file.
    static func payload(in cgImage: CGImage) throws -> String {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        return try payload(using: handler)
    }

    private static func payload(using handler: VNImageRequestHandler) throws -> String {
        // Leave `symbologies` at Vision's default so QR and the other barcode
        // formats supported by the running macOS release are all recognized.
        let request = VNDetectBarcodesRequest()
        try handler.perform([request])

        return (request.results ?? [])
            .sorted { $0.confidence > $1.confidence }
            .compactMap(\.payloadStringValue)
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

// MARK: - CodeCaptureCoordinator

/// Owns the capture → Vision barcode detection → clipboard → HUD pipeline for
/// the "Scan Code" action. The recognized payload is treated strictly as
/// plain text: it is never opened, linkified, or fetched from the network.
final class CodeCaptureCoordinator {
    private(set) var isInFlight: Bool = false
    private let hud = TextCaptureHUD()
    private let capturer = ScreenshotCapturer()

    /// Called with the recognized payload on success — the owner stores it in
    /// the tray using the existing text-entity path.
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
    func recognizeCode(in rect: CGRect, on screen: NSScreen?) {
        guard !isInFlight else { return }
        isInFlight = true
        // Carry only the value-type display ID across the background closure;
        // NSScreen itself is main-thread-bound and not Sendable.
        let displayID = screen?.displayID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let payload = self.captureAndRecognize(rect)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInFlight else { return }
                self.isInFlight = false
                let resultScreen = displayID.flatMap { id in
                    NSScreen.screens.first { $0.displayID == id }
                }
                switch payload {
                case .some(let payload) where !payload.isEmpty:
                    // Copy as an inert string only. In particular, URL-shaped
                    // payloads are not opened or resolved.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    self.addText(payload)
                    self.hud.show(.codeCopied, on: resultScreen)
                case .some:
                    // Detection completed successfully, but the selection did
                    // not contain a barcode with a text payload.
                    self.hud.show(.noCodeFound, on: resultScreen)
                case .none:
                    // Capture or Vision failed and was already logged. Avoid a
                    // misleading "not found" message for an unavailable image.
                    break
                }
            }
        }
    }

    /// Blocking: captures the selected rect to a temporary image and runs a
    /// `VNDetectBarcodesRequest`. Returns nil on capture/Vision failure and an
    /// empty string when no readable payload was found.
    private func captureAndRecognize(_ rect: CGRect) -> String? {
        guard let tmpURL = capturer.captureRectToTemp(rect) else {
            if !capturer.lastCaptureWasCancelled && !capturer.lastCaptureWasBusy {
                Log.capture.error("code scan capture failed: \(rect.debugDescription)")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            return try CodeRecognition.payload(in: tmpURL)
        } catch {
            Log.capture.error("code recognition failed: \(error)")
            return nil
        }
    }
}

// MARK: - Code scan orchestration

extension NotchPanelController {
    /// Launches the same area-selection overlay used by Capture Text, then runs
    /// barcode detection instead of OCR on the selected region.
    @MainActor
    func scanCode(on screen: NSScreen? = nil) {
        if let screen {
            currentScreen = screen
            updateScreenMetrics(for: screen)
        }
        guard !isInPreSelection, !codeCapture.isInFlight else { return }
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
                    self?.codeCapture.recognizeCode(in: rect, on: target)
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
