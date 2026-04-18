import AppKit
import ImageIO
import OSLog

// MARK: - ScreenshotService

final class ScreenshotService {
    private let fm = FileManager.default
    private(set) var lastCaptureURL: URL?

    private let thumbnailHUD = ScreenshotThumbnailHUD()

    /// Called when a capture completes successfully. Passes the final file URL.
    var onCaptured: ((URL) -> Void)?

    /// Called when user taps the thumbnail HUD — should open tray.
    var onThumbnailTapped: (() -> Void)?

    /// Called when user deletes a screenshot from the thumbnail HUD. Passes the deleted file URL.
    var onDelete: ((URL) -> Void)?

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
            guard ok else {
                Log.capture.error("screencapture failed, args: \(args)")
                UserFacingError.present(.screenCaptureFailed(reason: nil))
                return
            }
            guard self.fm.fileExists(atPath: tmpURL.path) else {
                Log.capture.error("output file missing: \(tmpURL.path)")
                UserFacingError.present(.screenCaptureFailed(
                    reason: "No output file was produced."))
                return
            }
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
        guard ok else {
            Log.capture.error("screencapture failed, args: \(args)")
            UserFacingError.present(.screenCaptureFailed(reason: nil))
            return
        }
        guard fm.fileExists(atPath: tmpURL.path) else {
            Log.capture.error("output file missing: \(tmpURL.path)")
            UserFacingError.present(.screenCaptureFailed(
                reason: "No output file was produced."))
            return
        }
        handleCapturedFile(at: tmpURL, preferredScreen: preferredScreen)
    }

    private func handleCapturedFile(at tmpURL: URL, preferredScreen: NSScreen?) {
        do {
            let finalURL = try AppSettings.withSaveDirectoryAccess { outputDir in
                let dest = uniqueDestURL(in: outputDir, filename: makeFilename())
                try fm.moveItem(at: tmpURL, to: dest)
                return dest
            }

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
            // Move failed — keep the temp file as a fallback but warn the user.
            lastCaptureURL = tmpURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Permission/bookmark failure routes to the centralized error
                // presenter so the user gets a single, throttled alert with a
                // remediation button (open NotchShot Settings).
                if case AppSettingsError.securityScopeAccessDenied(let url) = error {
                    UserFacingError.present(.saveDirectoryInaccessible(url: url))
                } else {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Screenshot saved to temporary folder"
                    alert.informativeText = "Could not save to the selected folder: \(error.localizedDescription)\n\nThe file was kept in the temporary folder instead."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }

                self.thumbnailHUD.onDelete = { [weak self] in self?.onDelete?(tmpURL) }
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
                if process.terminationStatus != 0 {
                    Log.capture.error("screencapture exited with status \(process.terminationStatus), args: \(arguments)")
                }
                return process.terminationStatus == 0
            } catch {
                Log.capture.error("screencapture launch failed: \(error), args: \(arguments)")
                return false
            }
        }
    }

    private func makeFilename() -> String {
        AppSettings.resolveFilename(
            preset:  AppSettings.filenamePreset,
            date:    Date(),
            counter: AppSettings.nextCaptureCounter(),
            format:  AppSettings.fileFormat
        )
    }

    /// Returns a destination URL that does not collide with any existing file.
    /// Appends " 2", " 3", etc. on conflict.
    private func uniqueDestURL(in dir: URL, filename: String) -> URL {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext  = URL(fileURLWithPath: filename).pathExtension
        let url  = dir.appendingPathComponent(filename)
        guard fm.fileExists(atPath: url.path) else { return url }
        for n in 2..<1000 {
            let candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private func fileExtension() -> String {
        let fmt = AppSettings.fileFormat
        return fmt == "jpg" ? "jpg" : (fmt == "tiff" ? "tiff" : "png")
    }

    private func appendFormatFlag(to args: inout [String]) {
        args.append(contentsOf: ["-t", AppSettings.fileFormat])
    }
}

// FrontmostWindowResolver lives in FrontmostWindowResolver.swift
// ScreenshotSoundPlayer lives in ScreenshotSoundPlayer.swift
