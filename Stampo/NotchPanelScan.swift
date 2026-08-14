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
    private nonisolated let capturer = ScreenshotCapturer()

    /// Called once per finding on success — each barcode payload separately,
    /// then the recognized text — the owner stores them in the archive.
    var addText: (String, Bool) -> Void = { _, _ in }

    /// Called with the recognized prose when the scan was run with ⌃ — the
    /// owner has the archive the translation lands in. Payloads never reach
    /// this: a Wi-Fi config or a tracking number is a value, not language.
    /// Second argument is the language ⇥ chose on the overlay, or nil to let
    /// the ordinary rule decide.
    var translate: (String, Locale.Language?) -> Void = { _, _ in }

    /// Stops an active scan without showing a result HUD. A result that arrives
    /// after cancellation is discarded on the main thread.
    @MainActor
    func cancel() {
        guard isInFlight else { return }
        isInFlight = false
        capturer.terminateCurrentCapture()
        hud.hide(animated: false)
    }

    /// `joinsLines` glues the recognized text back into paragraphs instead of
    /// keeping every line break the layout happened to produce. The editor has
    /// a control for this; the overlay carries it as a mode toggled with ⌥ and
    /// shown on the frame (see `NotchPanelController.scan`).
    @MainActor
    func scan(in rect: CGRect, on screen: NSScreen?, joinsLines: Bool,
              translates: Bool = false, into language: Locale.Language? = nil) {
        guard !isInFlight else { return }
        isInFlight = true
        // Carry only the value-type display ID across the background closure;
        // NSScreen itself is main-thread-bound and not Sendable.
        let displayID = screen?.displayID
        let configuration = ScreenshotCaptureConfiguration.current

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.captureAndRecognize(
                rect,
                joinsLines: joinsLines,
                configuration: configuration
            )
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
                // The archive inserts each entry at the top, so add in reverse:
                // the visually-topmost finding ends up as the topmost archive entry.
                for entry in result.archiveEntries.reversed() {
                    self.addText(entry.string, entry.isCode)
                }
                // The scan toast is skipped when translating: the translation
                // has its own outcome — a new entry, or a toast of its own if
                // the pack is missing — and two toasts in a row for one gesture
                // read as something having gone wrong.
                if translates && !result.text.isEmpty {
                    self.translate(result.text, language)
                } else {
                    self.hud.show(Self.outcome(for: result), on: resultScreen)
                }
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
    private nonisolated func captureAndRecognize(
        _ rect: CGRect,
        joinsLines: Bool,
        configuration: ScreenshotCaptureConfiguration
    ) -> ScanRecognition.Result? {
        let captureResult = capturer.captureRectToTemp(rect, configuration: configuration)
        guard case .success(let tmpURL, _) = captureResult else {
            switch captureResult {
            case .failed(let failure):
                Log.capture.error("scan capture failed: \(failure.localizedDescription, privacy: .public)")
            case .cancelled, .busy, .success:
                break
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            return try ScanRecognition.scan(in: tmpURL, joinsLines: joinsLines)
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
            let selectionToken = self.makePanelTransitionToken()
            self.selectionOverlay.onSelected = { [weak self] rect in
                guard let self else { return }
                guard self.animationGenerationMatches(selectionToken),
                      case .preSelection(.selection) = self.state
                else { return }
                // Neither modifier is sampled here. Both are toggles the
                // overlay tracks with its own event monitor, so the answer is
                // simply whatever the frame was showing when the mouse came up
                // — see `installModifierMonitor` for why a held key could not
                // be tracked reliably in the first place.
                //
                // Joining is the default: line breaks from someone else's
                // layout are noise in text you are about to paste somewhere
                // else, so ⌥ is what *keeps* them, for the block where the
                // breaks are the content (verse, code, a table column).
                //
                // Translating always joins, whatever the mode says, because
                // machine translation of line fragments returns damage and
                // `joinParagraphs` exists precisely to hand it whole sentences.
                // The two modes are mutually exclusive on the overlay for the
                // same reason.
                let mode = self.selectionOverlay.selectionMode
                let translates = mode == .translate
                let joinsLines = mode != .keepLineBreaks
                // Read here with the mode and for the same reason: it is
                // whatever the badge was saying when the mouse came up. Nil
                // unless ⇥ was pressed, which leaves the ordinary rule — into
                // the primary language, or out of it — to decide.
                let into = self.selectionOverlay.translationTarget
                self.state = .hidden
                // Let WindowServer remove the overlay from the framebuffer
                // before capturing the selected area.
                self.schedulePanelAction(after: 0.1,
                                         token: selectionToken,
                                         requiresVisible: false) { [weak self] in
                    guard let self, case .hidden = self.state else { return }
                    self.scanCapture.scan(in: rect, on: target,
                                         joinsLines: joinsLines,
                                         translates: translates, into: into)
                }
            }
            self.selectionOverlay.onCancelled = { [weak self] in
                guard let self, self.animationGenerationMatches(selectionToken) else { return }
                self.invalidatePanelTransitionActions()
                self.state = .hidden
            }
            // Only the scanner has modes, so only the scanner's overlay
            // advertises them.
            self.selectionOverlay.showsScanModes = true
            self.selectionOverlay.start(on: target)
        }

        if isVisible && !needsSpaceRebind {
            hideAnimated(reason: .captureStart) { begin() }
        } else {
            begin()
        }
    }
}
