import AppKit
import OSLog

// MARK: - ScreenshotService

final class ScreenshotService {
    private let capturer = ScreenshotCapturer()
    private let store    = ScreenshotFileStore()
    private(set) var lastCaptureURL: URL?

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    /// Called when a capture completes successfully. Passes the final file URL.
    var onCaptured: ((URL) -> Void)?

    /// Called when user taps the thumbnail HUD — should open tray.
    var onThumbnailTapped: (() -> Void)?

    /// Called when user deletes a screenshot from the thumbnail HUD.
    var onDelete: ((URL) -> Void)?

    init() {
        thumbnailHUD.onTapped = { [weak self] in
            self?.onThumbnailTapped?()
        }
    }

    /// Прерывает текущий запущенный screencapture(1), если он активен.
    /// Безопасно вызывать с любого потока; используется при sleep/wake/display change.
    func cancelCurrentCapture() {
        capturer.terminateCurrentCapture()
    }

    func capture(mode: CaptureMode, delaySeconds: Int, preferredScreen: NSScreen?) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.runCapture(mode: mode, preferredScreen: preferredScreen)
        }
        if delaySeconds > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .seconds(delaySeconds),
                execute: workItem
            )
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
        }
    }

    func captureRect(_ rect: CGRect, preferredScreen: NSScreen?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let tmpURL = self.capturer.captureRectToTemp(rect) {
                self.handleCapturedFile(at: tmpURL, preferredScreen: preferredScreen)
            } else if !self.capturer.lastCaptureWasCancelled && !self.capturer.lastCaptureWasBusy {
                Log.capture.error("captureRect failed: \(rect.debugDescription)")
                UserFacingError.present(.screenCaptureFailed(reason: nil))
            }
        }
    }

    func captureWindowID(_ windowID: CGWindowID, preferredScreen: NSScreen?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if let tmpURL = self.capturer.captureWindowIDToTemp(windowID) {
                self.handleCapturedFile(at: tmpURL, preferredScreen: preferredScreen)
            } else if !self.capturer.lastCaptureWasCancelled && !self.capturer.lastCaptureWasBusy {
                Log.capture.error("captureWindowID failed: \(windowID)")
                UserFacingError.present(.screenCaptureFailed(reason: nil))
            }
        }
    }

    // MARK: - Private

    private func runCapture(mode: CaptureMode, preferredScreen: NSScreen?) {
        if let tmpURL = capturer.captureToTemp(mode: mode, preferredScreen: preferredScreen) {
            handleCapturedFile(at: tmpURL, preferredScreen: preferredScreen)
        } else if !capturer.lastCaptureWasCancelled && !capturer.lastCaptureWasBusy {
            // Не показываем ошибку если capture был отменён или отклонён как дублирующий.
            Log.capture.error("capture failed for mode: \(String(describing: mode))")
            UserFacingError.present(.screenCaptureFailed(reason: nil))
        }
    }

    private func handleCapturedFile(at tmpURL: URL, preferredScreen: NSScreen?) {
        do {
            let finalURL = try store.moveToFinalDestination(from: tmpURL)
            lastCaptureURL = finalURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if AppSettings.playSound { ScreenshotSoundPlayer.play() }
                if AppSettings.copyToClipboard { NSPasteboard.general.writeImage(at: finalURL) }
                self.thumbnailHUD.onDelete = { [weak self] in self?.onDelete?(finalURL) }
                self.thumbnailHUD.show(imageURL: finalURL, on: preferredScreen)
                self.onCaptured?(finalURL)
            }
        } catch {
            lastCaptureURL = tmpURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Screenshot saved to temporary folder")
                alert.informativeText = String(localized: "Could not save to the selected folder: \(error.localizedDescription)\n\nThe file was kept in the temporary folder instead.")
                alert.addButton(withTitle: String(localized: "OK"))
                alert.runModal()
                self.thumbnailHUD.onDelete = { [weak self] in self?.onDelete?(tmpURL) }
                self.thumbnailHUD.show(imageURL: tmpURL, on: preferredScreen)
                self.onCaptured?(tmpURL)
            }
        }
    }
}

// FrontmostWindowResolver lives in FrontmostWindowResolver.swift
// ScreenshotSoundPlayer     lives in ScreenshotSoundPlayer.swift
