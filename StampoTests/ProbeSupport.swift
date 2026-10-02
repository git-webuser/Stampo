import AppKit
import SwiftUI

/// The harness for probes: throwaway tests that put a real view on screen and
/// hand back a picture of it, so a layout or an animation is looked at and
/// measured before anyone is asked to check it by hand.
///
/// When to reach for it, and the traps around it, are in
/// `.claude/skills/ui-evidence/SKILL.md`. Everything is written to
/// `/tmp/stampo-probes/`, and each call prints the path it wrote.
@MainActor
enum Probe {

    static let folder = URL(fileURLWithPath: "/tmp/stampo-probes", isDirectory: true)

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: On screen

    /// Hosts a SwiftUI view in a borderless window in the middle of the screen
    /// and waits for it to lay out. Take it down with `orderOut(nil)`.
    static func onScreen(_ view: some View, size: NSSize,
                         appearance: NSAppearance.Name? = nil) -> NSWindow {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        return onScreen(hosting, size: size, appearance: appearance)
    }

    /// The same for an AppKit view.
    ///
    /// Centred and floating rather than at the origin: `film` records a patch
    /// of the screen, and in the corner that patch is under the Dock.
    static func onScreen(_ view: NSView, size: NSSize,
                         appearance: NSAppearance.Name? = nil) -> NSWindow {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: (screen.midX - size.width / 2).rounded(),
                           y: (screen.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        // Layout, not async work: pumping the run loop is the right tool here.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        return window
    }

    // MARK: Pictures

    /// The window as the screen shows it, text and SF Symbols included — which
    /// `cacheDisplay` and `layer.render(in:)` both leave out.
    @discardableResult
    static func shoot(_ window: NSWindow, _ name: String) throws -> URL {
        let url = try output("\(name).png")
        try run("/usr/sbin/screencapture", ["-x", "-o", "-l\(window.windowNumber)", url.path])
        print("PROBE \(url.path)")
        return url
    }

    /// Records the window's patch of screen in real time while `change` runs,
    /// then cuts it into numbered frames and one storyboard — frames left to
    /// right, top to bottom, `fps` of them a second.
    ///
    /// Real time on purpose. SwiftUI drives its own animations, so the stopped
    /// layer clock that holds Core Animation still (`MascotViewTests`) does not
    /// hold them. The first frames are the state before `change`: recording
    /// takes a moment to start, so `change` waits for it.
    @discardableResult
    static func film(_ window: NSWindow, _ name: String, seconds: Double = 1.5, fps: Int = 30,
                     columns: Int = 8, change: () -> Void) async throws -> URL {
        let movie = try output("\(name).mov")
        let lead = 0.3
        let recorder = Process()
        recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        recorder.arguments = ["-x", "-v", "-V\(Int((lead + seconds).rounded(.up)))",
                              "-R\(screenRect(of: window))", movie.path]
        try recorder.run()
        try await Task.sleep(for: .seconds(lead))
        change()
        // Sleeping, not waiting on the process: the main thread has to stay
        // free, or the animation being filmed never gets drawn.
        while recorder.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard recorder.terminationStatus == 0, FileManager.default.fileExists(atPath: movie.path) else {
            throw Failure(description: "screencapture could not record \(movie.path)")
        }

        let frames = folder.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let width = Int(window.frame.width)
        // screencapture records past -V; the tail after the change has settled
        // is dead weight in a storyboard.
        let length = String(lead + seconds)
        try run(ffmpeg, ["-y", "-loglevel", "error", "-i", movie.path, "-t", length,
                         "-vf", "fps=\(fps),scale=\(width):-2", "\(frames.path)/%03d.png"])
        let count = try FileManager.default.contentsOfDirectory(atPath: frames.path).count
        let rows = max(1, (count + columns - 1) / columns)

        let storyboard = try output("\(name)-storyboard.png")
        try run(ffmpeg, ["-y", "-loglevel", "error", "-i", movie.path, "-t", length, "-frames:v", "1",
                         "-vf", "fps=\(fps),scale=\(width):-2,tile=\(columns)x\(rows):padding=4:color=gray",
                         storyboard.path])
        print("PROBE \(storyboard.path) · \(count) frames at \(fps) fps in \(frames.path)/ · the change lands near frame \(Int(lead * Double(fps)) + 1)")
        return storyboard
    }

    // MARK: Measuring

    /// A picture as raw RGBA, for measuring — heights of controls, gaps,
    /// baselines — rather than judging by eye.
    struct Bitmap {
        let width: Int
        let height: Int
        fileprivate let bytes: [UInt8]

        /// The pixel `x` across and `y` down from the top-left corner.
        subscript(x x: Int, y y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    static func bitmap(_ url: URL) throws -> Bitmap {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "cannot read \(url.path)")
        }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure(description: "cannot decode \(url.path)") }
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    // MARK: Plumbing

    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"

    private static func output(_ file: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// `screencapture -R` wants points from the top-left of the main display;
    /// AppKit counts from the bottom-left.
    private static func screenRect(of window: NSWindow) -> String {
        let top = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
        return "\(Int(window.frame.minX)),\(Int(top)),\(Int(window.frame.width)),\(Int(window.frame.height))"
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw Failure(description: "\(tool) is not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "\(tool) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
        }
    }
}
