import CoreGraphics
import Foundation
import os

#if DEBUG
import ImageIO
import UniformTypeIdentifiers

/// The frames and the steps of a scrolling capture, written to disk to be taken
/// apart afterwards. Debug builds only, and only when asked for:
///
///     defaults write com.hex000.Stampo scrollCaptureDumpFrames -bool YES
///
/// One folder per capture, under the app's caches: `ScrollDump/<date-time>/`.
/// In it `00-before.png` (the whole window), `00-probe.png`, a `NN-step.png`
/// for every step, `final.png`, and `steps.txt` with a line for each. The
/// writing happens on a utility queue, in order, so that it does not change
/// the rhythm of the capture it records.
nonisolated final class ScrollFrameDump: Sendable {
    static let defaultsKey = "scrollCaptureDumpFrames"

    let directory: URL
    private let queue = DispatchQueue(label: "com.hex000.Stampo.scroll-dump", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    @MainActor
    static var isEnabled: Bool { AppSettings.store.bool(forKey: defaultsKey) }

    /// A dump for a capture starting now, or nil when the flag is off or the
    /// folder cannot be made.
    @MainActor
    static func begin() -> ScrollFrameDump? {
        guard isEnabled,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "com.hex000.Stampo"
        let folder = caches.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("ScrollDump", isDirectory: true)
            .appendingPathComponent(directoryName(for: Date()), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Log.capture.error("scroll dump folder could not be made: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        Log.capture.notice("scroll frames are written to \(folder.path, privacy: .public)")
        return ScrollFrameDump(directory: folder)
    }

    /// `2026-10-08-143005`: sorts as time does, and has nothing a path minds.
    static func directoryName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d-%02d%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// `name.png` in the folder.
    func save(_ frame: CaptureFrame, as name: String) {
        queue.async { [directory] in
            guard let image = frame.cgImage else { return }
            Self.writePNG(image, to: directory.appendingPathComponent("\(name).png"))
        }
    }

    func save(_ image: CGImage, as name: String) {
        queue.async { [directory] in
            Self.writePNG(image, to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// One more line of `steps.txt`.
    func step(_ line: String) {
        queue.async { [directory] in
            let url = directory.appendingPathComponent("steps.txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Waits for what has been queued to be written.
    func flush() {
        queue.sync {}
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            Log.capture.error("scroll dump could not write \(url.lastPathComponent, privacy: .public)")
        }
    }
}

private extension CaptureFrame {
    nonisolated var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CaptureFrame.bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
#else
/// Release builds write nothing: see the Debug one.
nonisolated final class ScrollFrameDump: Sendable {
    @MainActor
    static var isEnabled: Bool { false }
    @MainActor
    static func begin() -> ScrollFrameDump? { nil }
    func save(_ frame: CaptureFrame, as name: String) {}
    func save(_ image: CGImage, as name: String) {}
    func step(_ line: String) {}
}
#endif
