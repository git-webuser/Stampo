import AppKit
import ScreenCaptureKit

enum WindowFrameSourceError: Error, LocalizedError {
    case permissionDenied
    case windowUnavailable
    case invalidFrame
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return LocaleManager.shared.string("Grant Screen Recording access to Stampo, then try again.")
        case .windowUnavailable: return LocaleManager.shared.string("The selected window is no longer available.")
        // Not shown: a scrolling capture that meets it takes the window as it is.
        case .invalidFrame: return "The selected window has no capturable image."
        case .captureFailed(let reason): return reason
        }
    }
}

/// Captures one selected window into memory. It deliberately has no file
/// output path; only the final assembled image is handed to ScreenshotService.
actor WindowFrameSource {
    private var cachedWindow: SCWindow?
    private var cachedID: CGWindowID?
    private var cacheExpiry = Date.distantPast

    func capture(windowID: CGWindowID, scale: CGFloat = 1) async throws -> CaptureFrame {
        guard CGPreflightScreenCaptureAccess() else { throw WindowFrameSourceError.permissionDenied }
        let window = try await resolveWindow(windowID)
        let width = Int((window.frame.width * scale).rounded())
        let height = Int((window.frame.height * scale).rounded())
        guard width >= 40, height >= 40, width <= 12_000, height <= 12_000,
              width * height <= 25_000_000 else {
            throw WindowFrameSourceError.invalidFrame
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
        }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: configuration)
            guard let frame = CaptureFrame(image: image) else { throw WindowFrameSourceError.invalidFrame }
            return frame
        } catch let error as WindowFrameSourceError {
            throw error
        } catch {
            throw WindowFrameSourceError.captureFailed(error.localizedDescription)
        }
    }

    private func resolveWindow(_ id: CGWindowID) async throws -> SCWindow {
        if let cachedWindow, cachedID == id, Date() < cacheExpiry { return cachedWindow }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw WindowFrameSourceError.windowUnavailable
            }
            cachedWindow = window
            cachedID = id
            cacheExpiry = Date().addingTimeInterval(2)
            return window
        } catch let error as WindowFrameSourceError {
            throw error
        } catch {
            throw WindowFrameSourceError.captureFailed(error.localizedDescription)
        }
    }
}
