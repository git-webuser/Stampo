import AppKit
import ImageIO

// MARK: - ScreenshotService

final class ScreenshotService {
    private let fm = FileManager.default
    private(set) var lastCaptureURL: URL?

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    /// Called when a capture completes successfully. Passes the final file URL.
    var onCaptured: ((URL) -> Void)?

    /// Called when user taps the thumbnail HUD — should open tray.
    var onThumbnailTapped: (() -> Void)?

    init() {
        thumbnailHUD.onTapped = { [weak self] in
            self?.onThumbnailTapped?()
        }
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

    /// Capture a specific screen rectangle (CG coordinates: top-left origin).
    func captureRect(_ rect: CGRect, preferredScreen: NSScreen?) {
        let args = [
            "-x", "-R",
            "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        ]
        runCaptureWithArgs(args, preferredScreen: preferredScreen)
    }

    /// Capture a specific window by its CGWindowID.
    func captureWindowID(_ windowID: CGWindowID, preferredScreen: NSScreen?) {
        let args = ["-x", "-l", String(windowID)]
        runCaptureWithArgs(args, preferredScreen: preferredScreen)
    }

    private func runCaptureWithArgs(_ baseArgs: [String], preferredScreen: NSScreen?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ext = self.fileExtension()
            let tmpURL = self.fm.temporaryDirectory
                .appendingPathComponent("notchshot-\(UUID().uuidString).\(ext)")
            var args = baseArgs
            self.appendFormatFlag(to: &args)
            if AppSettings.includeCursor { args.append("-C") }
            args.append(tmpURL.path)
            let ok = self.runScreencapture(arguments: args)
            guard ok, self.fm.fileExists(atPath: tmpURL.path) else { return }
            self.handleCapturedFile(at: tmpURL, preferredScreen: preferredScreen)
        }
    }

    private func runCapture(mode: CaptureMode, preferredScreen: NSScreen?) {
        // screencapture (a child process) cannot write to sandbox-protected directories
        // like Downloads directly. We write to tmp first, then move via FileManager
        // which has the app's full entitlements including Downloads access.
        let ext = fileExtension()
        let tmpURL = fm.temporaryDirectory
            .appendingPathComponent("notchshot-\(UUID().uuidString).\(ext)")

        var args: [String] = ["-x"]
        appendFormatFlag(to: &args)

        switch mode {
        case .selection:
            if AppSettings.includeCursor { args.append("-C") }
            args.append(contentsOf: ["-i", "-s"])
        case .window:
            if AppSettings.includeCursor   { args.append("-C") }
            if !AppSettings.includeWindowShadow { args.append("-o") }
            if let windowID = FrontmostWindowResolver.frontmostWindowID() {
                args.append(contentsOf: ["-l", String(windowID)])
            } else {
                args.append(contentsOf: ["-i", "-w"])
            }
        case .screen:
            if AppSettings.includeCursor { args.append("-C") }
            if let displayID = preferredScreen?.displayID {
                args.append(contentsOf: ["-D", String(displayID)])
            }
        }

        args.append(tmpURL.path)

        let ok = runScreencapture(arguments: args)
        guard ok, fm.fileExists(atPath: tmpURL.path) else { return }
        handleCapturedFile(at: tmpURL, preferredScreen: preferredScreen)
    }

    private func handleCapturedFile(at tmpURL: URL, preferredScreen: NSScreen?) {
        let outputDir = AppSettings.saveDirectoryURL
        let finalURL  = outputDir.appendingPathComponent(makeFilename())

        do {
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: tmpURL, to: finalURL)

            lastCaptureURL = finalURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if AppSettings.playSound { ScreenshotSoundPlayer.play() }
                if AppSettings.copyToClipboard { NSPasteboard.general.writeImage(at: finalURL) }
                self.thumbnailHUD.show(imageURL: finalURL, on: preferredScreen)
                self.onCaptured?(finalURL)
            }
        } catch {
            // Move failed — keep the temp file as a fallback but warn the user.
            lastCaptureURL = tmpURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Screenshot saved to temporary folder"
                alert.informativeText = "Could not save to the selected folder: \(error.localizedDescription)\n\nThe file was kept in the temporary folder instead."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                self.thumbnailHUD.show(imageURL: tmpURL, on: preferredScreen)
                self.onCaptured?(tmpURL)
            }
        }
    }

    private func runScreencapture(arguments: [String]) -> Bool {
        autoreleasepool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
    }

    private func makeFilename() -> String {
        AppSettings.resolveFilename(
            template: AppSettings.filenameTemplate,
            date:     Date(),
            format:   AppSettings.fileFormat
        )
    }

    private func fileExtension() -> String {
        let fmt = AppSettings.fileFormat
        return fmt == "jpg" ? "jpg" : (fmt == "tiff" ? "tiff" : "png")
    }

    private func appendFormatFlag(to args: inout [String]) {
        args.append(contentsOf: ["-t", AppSettings.fileFormat])
    }
}

// MARK: - FrontmostWindowResolver

private enum FrontmostWindowResolver {
    static func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            guard let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  isOnscreen else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? UInt32
            else { continue }

            if let bounds = info[kCGWindowBounds as String] as? [String: Any] {
                let wAny = bounds["Width"]
                let hAny = bounds["Height"]
                let w: Double = (wAny as? Double) ?? Double((wAny as? CGFloat) ?? 0)
                let h: Double = (hAny as? Double) ?? Double((hAny as? CGFloat) ?? 0)
                if w <= 0 || h <= 0 { continue }
                if (w < 60 && h < 60) || (w * h < 3600) { continue }
            }

            return CGWindowID(windowNumber)
        }
        return nil
    }
}

// MARK: - ScreenshotSoundPlayer

enum ScreenshotSoundPlayer {
    static func play() {
        // Primary: system sound by name — works across macOS versions without path coupling
        if let sound = NSSound(named: "Screen Capture") {
            sound.play()
            return
        }
        // Fallback: known file paths for macOS 12–14
        let candidates: [String] = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aiff",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/screenshot.aiff",
            "/System/Library/Library/Sounds/Screen Capture.aiff",
            "/System/Library/Sounds/Glass.aiff"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                sound.play()
                return
            }
        }
        NSSound.beep()
    }
}
