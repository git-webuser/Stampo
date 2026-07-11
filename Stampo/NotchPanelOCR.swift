import AppKit
import OSLog
import Vision

// MARK: - TextCaptureCoordinator

/// Owns the capture → Vision recognition → clipboard → HUD pipeline for the
/// "Capture Text" (OCR) action. NotchPanelController holds one instance; the
/// area-selection overlay itself stays with the controller, which hands the
/// selected rect to `recognizeText(in:on:)`.
final class TextCaptureCoordinator {
    private(set) var isInFlight: Bool = false
    private let hud = TextCaptureHUD()
    private let capturer = ScreenshotCapturer()

    /// Called with the recognized text on success — the owner adds it to the tray.
    var addText: (String) -> Void = { _ in }

    /// Прерывает активную сессию распознавания без показа HUD.
    /// Вызывается из invalidatePanelAfterEnvironmentChange (sleep, display
    /// change и т. д.) — результат устаревшей сессии просто отбрасывается.
    @MainActor
    func cancel() {
        guard isInFlight else { return }
        isInFlight = false
        hud.hide(animated: false)
    }

    @MainActor
    func recognizeText(in rect: CGRect, on screen: NSScreen?) {
        guard !isInFlight else { return }
        isInFlight = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let text = self.captureAndRecognize(rect)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isInFlight else { return }
                self.isInFlight = false
                switch text {
                case .some(let text) where !text.isEmpty:
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self.addText(text)
                    self.hud.show(.copied, on: screen)
                case .some:
                    // Recognition ran but the selection had no readable text.
                    // The clipboard is left untouched.
                    self.hud.show(.noTextFound, on: screen)
                case .none:
                    // Capture or recognition failed — already logged; stay silent
                    // rather than claim "no text" about an image we never saw.
                    break
                }
            }
        }
    }

    /// Blocking: runs screencapture(1) into a temp file, feeds it to Vision,
    /// deletes the temp file. Returns nil on capture/recognition failure,
    /// "" when the image contained no readable text.
    private func captureAndRecognize(_ rect: CGRect) -> String? {
        guard let tmpURL = capturer.captureRectToTemp(rect) else {
            if !capturer.lastCaptureWasCancelled && !capturer.lastCaptureWasBusy {
                Log.capture.error("text capture failed: \(rect.debugDescription)")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let request = TextRecognition.makeRequest()
        let handler = VNImageRequestHandler(url: tmpURL)
        do {
            try handler.perform([request])
        } catch {
            Log.capture.error("text recognition failed: \(error)")
            return nil
        }

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Text capture orchestration

extension NotchPanelController {

    /// Launches the area-selection overlay and OCRs the selected region.
    /// Mirrors `captureDirectly(mode: .selection)` for the overlay part and
    /// `pickColor()` for the hide-panel-first part.
    @MainActor
    func captureText(on screen: NSScreen? = nil) {
        if let screen {
            currentScreen = screen
            updateScreenMetrics(for: screen)
        }
        guard !isInPreSelection, !textCapture.isInFlight else { return }
        guard let target = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let begin: () -> Void = { [weak self] in
            guard let self else { return }
            self.state = .preSelection(.selection)
            self.selectionOverlay.onSelected = { [weak self] rect in
                guard let self else { return }
                self.state = .hidden
                // The overlay panel was just dismissed but WindowServer may
                // still have it in the framebuffer for a frame or two — same
                // delay as the hotkey selection-screenshot path.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.textCapture.recognizeText(in: rect, on: target)
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
