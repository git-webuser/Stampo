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
    private var scrollingSession: ScrollingCaptureSession?
    private var captureInProgress = false

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    /// Called when a capture completes successfully. Passes the final file URL.
    var onCaptured: ((URL) -> Void)?

    /// Called when user taps the thumbnail HUD — should open archive.
    var onThumbnailTapped: (() -> Void)?

    /// Called when user deletes a screenshot from the thumbnail HUD.
    var onDelete: ((URL) -> Void)?

    /// Called when a capture is cancelled by the user (e.g. Esc during window picker).
    var onCancelled: (() -> Void)?

    /// Whether Stampo's own visible UI is over a Quartz point. A scrolling
    /// capture never scrolls through it.
    var scrollingOwnUICovers: ((CGPoint) -> Bool)?

    /// The notch panel's window number, the one window of ours a scrolling
    /// capture looks through.
    var scrollingIgnoredWindows: (() -> Set<CGWindowID>)?

    /// What the notch strip should show while a scrolling capture runs.
    var onScrollingStatus: ((ScrollCaptureStatus) -> Void)?

    /// The scrolling capture is over — saved, cancelled or failed — and the
    /// strip can leave.
    var onScrollingEnded: (() -> Void)?

    var isScrolling: Bool { scrollingSession != nil }

    /// Done on the strip: save what is collected.
    func finishScrolling() { scrollingSession?.finish() }

    /// ✕ on the strip: drop it.
    func cancelScrolling() { scrollingSession?.cancel() }

    init() {
        thumbnailHUD.onTapped = { [weak self] in
            self?.onThumbnailTapped?()
        }
    }

    /// Прерывает текущий запущенный screencapture(1), если он активен.
    /// Безопасно вызывать с любого потока; используется при sleep/wake/display change.
    nonisolated func cancelCurrentCapture() {
        capturer.terminateCurrentCapture()
        Task { @MainActor [weak self] in self?.scrollingSession?.cancel() }
    }

    /// Starts the single in-memory scrolling capture session. The final image
    /// enters the same store/publish pipeline as an ordinary screenshot.
    /// Returns false when another capture is already running; nothing starts.
    @discardableResult
    func captureScrolling(selection: WindowPickerSelection, axis: ScrollAxis, preferredScreen: NSScreen?) -> Bool {
        guard !captureInProgress, scrollingSession == nil else { return false }
        captureInProgress = true
        let session = ScrollingCaptureSession(selection: selection, axis: axis,
                                              excludeScrollbars: AppSettings.excludeScrollbars,
                                              lengthLimit: AppSettings.scrollLengthLimit,
                                              shrinkToFit: AppSettings.scrollShrinkToFit,
                                              ownUICovers: { [weak self] point in
                                                  self?.scrollingOwnUICovers?(point) ?? false
                                              },
                                              ignoredWindows: { [weak self] in
                                                  self?.scrollingIgnoredWindows?() ?? []
                                              })
        scrollingSession = session
        session.onStatus = { [weak self] status in self?.onScrollingStatus?(status) }
        session.onFinished = { [weak self] image in
            guard let self else { return }
            self.scrollingSession = nil
            self.saveScrollingImage(image, on: preferredScreen)
        }
        session.onCancelled = { [weak self] in
            self?.scrollingSession = nil
            self?.captureInProgress = false
            self?.onScrollingEnded?()
        }
        // Nothing to scroll through: the strip leaves and the window is
        // captured as the Window mode captures it — same settings, same
        // thumbnail, and an alert only if that fails too.
        session.onWindowScreenshotInstead = { [weak self] in
            guard let self else { return }
            self.scrollingSession = nil
            self.captureInProgress = false
            self.onScrollingEnded?()
            self.captureWindowID(selection.windowID, preferredScreen: preferredScreen)
        }
        session.start()
        return true
    }

    private func saveScrollingImage(_ image: CGImage, on screen: NSScreen?) {
        let store = self.store
        let format = AppSettings.fileFormat
        let service = self
        Task.detached(priority: .userInitiated) { [weak service] in
            do {
                let rep = NSBitmapImageRep(cgImage: image)
                let (type, properties) = ScreenshotFileStore.encoding(for: format)
                guard let data = rep.representation(using: type, properties: properties) else {
                    throw ScreenshotFileStore.SaveError.encodingFailed
                }
                let url = try store.saveEncodedImage(data, format: format)
                await service?.finishScrollingSave(url, on: screen)
            } catch {
                await MainActor.run { [weak service] in
                    service?.captureInProgress = false
                    let nsError = error as NSError
                    Log.capture.error("scroll capture failed at stage save · \(nsError.domain, privacy: .public) code \(nsError.code, privacy: .public)")
                    UserFacingError.present(Self.scrollingSaveErrorKind(error))
                    service?.onScrollingEnded?()
                }
            }
        }
    }

    static func scrollingSaveErrorKind(_ error: Error) -> UserFacingError.Kind {
        if let saveError = error as? ScreenshotFileStore.SaveError,
           case .encodingFailed = saveError {
            return .scrollingCaptureFailed(reason: LocaleManager.shared.string("Stampo couldn't encode the scrolling image."))
        }

        let nsError = error as NSError
        let isCocoaPermissionError = nsError.domain == NSCocoaErrorDomain
            && [CocoaError.Code.fileWriteNoPermission.rawValue,
                CocoaError.Code.fileReadNoPermission.rawValue].contains(nsError.code)
        let isPOSIXPermissionError = nsError.domain == NSPOSIXErrorDomain
            && [1, 13].contains(nsError.code) // EPERM or EACCES during the destination write
        if isCocoaPermissionError || isPOSIXPermissionError {
            return .saveDirectoryInaccessible(url: AppSettings.saveDirectoryURL)
        }
        return .scrollingCaptureFailed(reason: error.localizedDescription)
    }

    func capture(mode: CaptureMode, delaySeconds: Int, preferredScreen: NSScreen?) {
        guard !captureInProgress, scrollingSession == nil else { return }
        captureInProgress = true
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
        guard !captureInProgress, scrollingSession == nil else { return }
        captureInProgress = true
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
        guard !captureInProgress, scrollingSession == nil else { return }
        captureInProgress = true
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
        captureInProgress = false
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

    private func finishScrollingSave(_ url: URL, on screen: NSScreen?) {
        captureInProgress = false
        publish(url, on: screen)
        onScrollingEnded?()
    }
}
