import AppKit
import OSLog

private nonisolated enum CaptureWorkerResult: Sendable {
    case success(URL, displayID: CGDirectDisplayID?)
    case temporary(URL, reason: String)
    case cancelled
    case busy
    case failed(String)
}

// UI-facing coordinator. The capture process and file move run in a detached
// worker, while every AppKit side effect is funneled back to the main actor.
@MainActor
final class ScreenshotService {
    private nonisolated let capturer = ScreenshotCapturer()
    private nonisolated let store = ScreenshotFileStore()
    private(set) var lastCaptureURL: URL?

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    /// Called when a capture completes successfully. Passes the final file URL.
    var onCaptured: ((URL) -> Void)?

    /// Called when user taps the thumbnail HUD — should open archive.
    var onThumbnailTapped: (() -> Void)?

    /// Called when user deletes a screenshot from the thumbnail HUD.
    var onDelete: ((URL) -> Void)?

    /// Called when a capture is cancelled by the user (e.g. Esc during window picker).
    var onCancelled: (() -> Void)?

    init() {
        thumbnailHUD.onTapped = { [weak self] in
            self?.onThumbnailTapped?()
        }
    }

    /// Прерывает текущий запущенный screencapture(1), если он активен.
    /// Безопасно вызывать с любого потока; используется при sleep/wake/display change.
    nonisolated func cancelCurrentCapture() {
        capturer.terminateCurrentCapture()
    }

    func capture(mode: CaptureMode, delaySeconds: Int, preferredScreen: NSScreen?) {
        let displayID = preferredScreen?.displayID
        let frontmostWindowID = mode == .window
            ? FrontmostWindowResolver.frontmostWindowID()
            : nil
        let configuration = ScreenshotCaptureConfiguration.current
        let capturer = self.capturer
        let store = self.store
        let worker = DispatchWorkItem {
            let result = Self.perform(
                mode: mode,
                displayID: displayID,
                frontmostWindowID: frontmostWindowID,
                configuration: configuration,
                capturer: capturer,
                store: store
            )
            Task { @MainActor [weak self] in
                self?.finish(result, preferredDisplayID: displayID)
            }
        }

        if delaySeconds > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .seconds(delaySeconds),
                execute: worker
            )
        } else {
            DispatchQueue.global(qos: .userInitiated).async(execute: worker)
        }
    }

    func captureRect(_ rect: CGRect, preferredScreen: NSScreen?) {
        let displayID = preferredScreen?.displayID
        let configuration = ScreenshotCaptureConfiguration.current
        let capturer = self.capturer
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.perform(
                rect: rect,
                configuration: configuration,
                capturer: capturer,
                store: store
            )
            Task { @MainActor [weak self] in
                self?.finish(result, preferredDisplayID: displayID)
            }
        }
    }

    func captureWindowID(_ windowID: CGWindowID, preferredScreen: NSScreen?) {
        let displayID = preferredScreen?.displayID
        let configuration = ScreenshotCaptureConfiguration.current
        let capturer = self.capturer
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.perform(
                windowID: windowID,
                configuration: configuration,
                capturer: capturer,
                store: store
            )
            Task { @MainActor [weak self] in
                self?.finish(result, preferredDisplayID: displayID)
            }
        }
    }

    // MARK: - Worker

    private nonisolated static func perform(
        mode: CaptureMode,
        displayID: CGDirectDisplayID?,
        frontmostWindowID: CGWindowID?,
        configuration: ScreenshotCaptureConfiguration,
        capturer: ScreenshotCapturer,
        store: ScreenshotFileStore
    ) -> CaptureWorkerResult {
        finish(
            capturer.captureToTemp(
                mode: mode,
                displayID: displayID,
                frontmostWindowID: frontmostWindowID,
                configuration: configuration
            ),
            store: store
        )
    }

    private nonisolated static func perform(
        rect: CGRect,
        configuration: ScreenshotCaptureConfiguration,
        capturer: ScreenshotCapturer,
        store: ScreenshotFileStore
    ) -> CaptureWorkerResult {
        finish(capturer.captureRectToTemp(rect, configuration: configuration), store: store)
    }

    private nonisolated static func perform(
        windowID: CGWindowID,
        configuration: ScreenshotCaptureConfiguration,
        capturer: ScreenshotCapturer,
        store: ScreenshotFileStore
    ) -> CaptureWorkerResult {
        finish(capturer.captureWindowIDToTemp(windowID, configuration: configuration), store: store)
    }

    private nonisolated static func finish(
        _ result: CaptureResult,
        store: ScreenshotFileStore
    ) -> CaptureWorkerResult {
        switch result {
        case .success(let tmpURL, let displayID):
            do {
                return .success(try store.moveToFinalDestination(from: tmpURL), displayID: displayID)
            } catch {
                return .temporary(tmpURL, reason: error.localizedDescription)
            }
        case .cancelled:
            return .cancelled
        case .busy:
            return .busy
        case .failed(let failure):
            return .failed(failure.localizedDescription)
        }
    }

    // MARK: - Main actor

    private func finish(_ result: CaptureWorkerResult, preferredDisplayID: CGDirectDisplayID?) {
        let preferredScreen = preferredDisplayID.flatMap { id in
            NSScreen.screens.first { $0.displayID == id }
        }

        switch result {
        case .success(let finalURL, let resultDisplayID):
            lastCaptureURL = finalURL
            let resultScreen = resultDisplayID.flatMap { id in
                NSScreen.screens.first { $0.displayID == id }
            }
            publish(finalURL, on: resultScreen ?? preferredScreen)

        case .temporary(let tmpURL, let reason):
            lastCaptureURL = tmpURL
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Screenshot saved to temporary folder")
            alert.informativeText = String(localized: "Could not save to the selected folder: \(reason)\n\nThe file was kept in the temporary folder instead.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            publish(tmpURL, on: preferredScreen)

        case .cancelled:
            onCancelled?()

        case .busy:
            // A second request is intentionally silent: the first capture owns
            // the user's interaction and the old behavior did not show an error.
            break

        case .failed(let reason):
            Log.capture.error("capture failed: \(reason, privacy: .public)")
            UserFacingError.present(.screenCaptureFailed(reason: reason))
        }
    }

    private func publish(_ url: URL, on screen: NSScreen?) {
        if AppSettings.playSound { ScreenshotSoundPlayer.play() }
        if AppSettings.copyToClipboard { NSPasteboard.general.writeImage(at: url) }
        thumbnailHUD.onDelete = { [weak self] in self?.onDelete?(url) }
        thumbnailHUD.show(imageURL: url, on: screen)
        onCaptured?(url)
    }
}
