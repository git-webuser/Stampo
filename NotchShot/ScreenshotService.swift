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
            let tmpURL = self.fm.temporaryDirectory
                .appendingPathComponent("notchshot-\(UUID().uuidString).png")
            var args = baseArgs
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
        let tmpURL = fm.temporaryDirectory
            .appendingPathComponent("notchshot-\(UUID().uuidString).png")

        var args: [String] = ["-x"]

        switch mode {
        case .selection:
            args.append(contentsOf: ["-i", "-s"])
        case .window:
            if let windowID = FrontmostWindowResolver.frontmostWindowID() {
                args.append(contentsOf: ["-l", String(windowID)])
            } else {
                args.append(contentsOf: ["-i", "-w"])
            }
        case .screen:
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
        let outputDir = saveDirectory()
        let finalURL = outputDir.appendingPathComponent(makeFilename())

        do {
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: tmpURL, to: finalURL)

            lastCaptureURL = finalURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ScreenshotSoundPlayer.play()
                NSPasteboard.general.writeImage(at: finalURL)
                self.thumbnailHUD.show(imageURL: finalURL, on: preferredScreen)
                self.onCaptured?(finalURL)
            }
        } catch {
            lastCaptureURL = tmpURL
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                ScreenshotSoundPlayer.play()
                NSPasteboard.general.writeImage(at: tmpURL)
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

    /// Default save location is Downloads. Will be user-configurable via Settings later.
    private func saveDirectory() -> URL {
        fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
    }

    private func makeFilename() -> String {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.dateComponents(in: .current, from: Date())
        let months = ["JAN","FEB","MAR","APR","MAY","JUN",
                      "JUL","AUG","SEP","OCT","NOV","DEC"]
        let mon = months[max(0, min((d.month ?? 1) - 1, 11))]
        // Format: MAR·25-19·34·55  (interpunct U+00B7 as time separator)
        return String(
            format: "%@\u{00B7}%02d-%02d\u{00B7}%02d\u{00B7}%02d.png",
            mon,
            d.day ?? 0,
            d.hour ?? 0,
            d.minute ?? 0,
            d.second ?? 0
        )
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
