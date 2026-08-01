import AppKit
import SwiftUI

// MARK: - PinnedWindowGeometry

/// Pure sizing/placement math for pinned screenshot windows, kept free of
/// AppKit window state so it is unit-testable.
enum PinnedWindowGeometry {
    /// Shortest allowed side of a freshly created pin.
    static let minSide: CGFloat = 140
    /// A new pin never exceeds this fraction of the visible screen.
    static let screenFraction: CGFloat = 0.5
    /// Initial scale relative to the image pixel size.
    static let initialFraction: CGFloat = 0.35
    static let cascadeOffset: CGFloat = 28
    static let margin: CGFloat = 24

    /// Initial window size: `initialFraction` of the image, clamped to at most
    /// `screenFraction` of the visible screen and at least `minSide` on the
    /// shorter side, preserving aspect ratio throughout. When a pathologically
    /// thin image cannot satisfy both bounds, the screen clamp wins.
    static func initialSize(imagePixels: CGSize, visibleFrame: CGRect) -> CGSize {
        guard imagePixels.width > 0, imagePixels.height > 0,
              visibleFrame.width > 0, visibleFrame.height > 0
        else { return CGSize(width: minSide, height: minSide) }

        let ar = imagePixels.width / imagePixels.height
        var w = imagePixels.width * initialFraction
        var h = w / ar

        let shortSide = min(w, h)
        if shortSide < minSide {
            let scale = minSide / shortSide
            w *= scale
            h *= scale
        }

        let maxW = visibleFrame.width * screenFraction
        let maxH = visibleFrame.height * screenFraction
        if w > maxW { w = maxW; h = w / ar }
        if h > maxH { h = maxH; w = h * ar }

        return CGSize(width: w, height: h)
    }

    /// Anchors in the top-right corner of the visible frame and steps each
    /// subsequent pin down-left by `cascadeOffset`, wrapping back to the
    /// anchor when the cascade would leave the screen margins.
    static func origin(size: CGSize, visibleFrame: CGRect, cascadeIndex: Int) -> CGPoint {
        let anchorX = visibleFrame.maxX - margin - size.width
        let anchorY = visibleFrame.maxY - margin - size.height
        var x = anchorX
        var y = anchorY
        for _ in 0..<max(cascadeIndex, 0) {
            x -= cascadeOffset
            y -= cascadeOffset
            if x < visibleFrame.minX + margin || y < visibleFrame.minY + margin {
                x = anchorX
                y = anchorY
            }
        }
        return CGPoint(x: x, y: y)
    }

    /// Shortest allowed side when the user resizes an existing pin (smaller
    /// than `minSide` so a pin can be tucked away without closing it).
    static let minResizeSide: CGFloat = 120

    /// Minimum window size for edge-resize: `minResizeSide` on the short side
    /// with the aspect preserved, but never exceeding `maxContentSize` — a
    /// 40:1 banner would otherwise demand a minimum wider than the screen and
    /// deadlock resize between the window's min and max constraints.
    static func minWindowSize(imagePixels: CGSize, maxContentSize: CGSize) -> CGSize {
        let ar = max(imagePixels.width, 1) / max(imagePixels.height, 1)
        var s = ar >= 1
            ? CGSize(width: minResizeSide * ar, height: minResizeSide)
            : CGSize(width: minResizeSide, height: minResizeSide / ar)
        if maxContentSize.width > 0, s.width > maxContentSize.width {
            let k = maxContentSize.width / s.width
            s.width *= k
            s.height *= k
        }
        if maxContentSize.height > 0, s.height > maxContentSize.height {
            let k = maxContentSize.height / s.height
            s.width *= k
            s.height *= k
        }
        return s
    }

    /// Shrinks and shifts `frame` as needed so it lies inside `visibleFrame`.
    static func clampedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        var f = frame
        f.size.width = min(f.width, visibleFrame.width)
        f.size.height = min(f.height, visibleFrame.height)
        f.origin.x = min(max(f.minX, visibleFrame.minX), visibleFrame.maxX - f.width)
        f.origin.y = min(max(f.minY, visibleFrame.minY), visibleFrame.maxY - f.height)
        return f
    }
}

// MARK: - PinnedScreenshotController

/// Owns every "pinned to screen" screenshot window. Singleton on the same
/// grounds as `EditorWindowController.shared`: the archive cell, the thumbnail
/// HUD, and the global hotkey all reach it directly without threading
/// callbacks through `NotchPanelController`.
///
/// Pins are deliberately ephemeral (not persisted across launches): they are
/// working-memory references while the user works, and the archive already
/// provides durable recall of recent captures.
final class PinnedScreenshotController {
    static let shared = PinnedScreenshotController()

    private var pins: [UUID: PinnedScreenshotPanel] = [:]
    private var fileWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private let feedbackHUD = TextCaptureHUD()
    /// Monotonic while any pin is alive — `pins.count` would reuse an index
    /// after "pin A, pin B, close A", landing the next pin exactly on top of B.
    private var cascadeIndex = 0
    /// Carbon keeps firing hot-key events while the combo is held; without a
    /// guard, holding ⌃⌥⌘P machine-guns identical pins of the last capture.
    private var lastHotkeyPin: (url: URL, at: TimeInterval)?

    var count: Int { pins.count }

    /// Test hook: current frames of all live pins.
    var windowFrames: [NSRect] { pins.values.map(\.frame) }

    private init() {
        // Pins are static windows that never morph or track the notch, so the
        // full panel-recreation dance from NotchPanelController is not needed;
        // re-asserting z-order after Space changes and wake is enough. If
        // "ghost pin" reports ever appear, escalate to the
        // invalidatePanelAfterEnvironmentChange pattern.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            workspaceObservers.append(center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.reassertPins()
            })
        }
    }

    @discardableResult
    func pin(url: URL, on screen: NSScreen? = nil) -> UUID? {
        // When no screen is given (archive / thumbnail HUD context menus), use
        // the screen under the mouse: for a nonactivating LSUIElement panel,
        // NSScreen.main is the *other* app's key-window screen, which on a
        // multi-monitor setup is often not where the user just clicked.
        let mouse = NSEvent.mouseLocation
        guard let target = screen
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return nil }

        let pixels = imagePixelSize(at: url)
        let vf = target.visibleFrame
        let size = PinnedWindowGeometry.initialSize(imagePixels: pixels, visibleFrame: vf)
        let origin = PinnedWindowGeometry.origin(size: size, visibleFrame: vf,
                                                 cascadeIndex: cascadeIndex)
        cascadeIndex += 1
        let frame = PinnedWindowGeometry.clampedFrame(
            NSRect(origin: origin, size: size), to: vf)

        // Decode enough pixels for the largest window this screen can host at
        // its backing scale — a fixed cap would render large pins on Retina/4K
        // softer than the original. (If the pin is later dragged to a denser
        // screen it keeps this budget; acceptable for v1.)
        let maxPixelSize = ceil(max(vf.width, vf.height) * target.backingScaleFactor)

        let id = UUID()
        let panel = PinnedScreenshotPanel(
            imageURL: url,
            frame: frame,
            imagePixelSize: pixels,
            maxContentSize: vf.size,
            maxPixelSize: maxPixelSize,
            onClose: { [weak self] in self?.close(id: id) }
        )
        pins[id] = panel
        startWatching(url: url, id: id)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        return id
    }

    /// Hotkey entry point: pins the most recent capture, or shows a toast when
    /// there is nothing to pin — a silent global hotkey reads as broken.
    func pinLastCapture(
        url: URL?,
        on screen: NSScreen?,
        eventTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            feedbackHUD.show(.noScreenshotToPin, on: screen)
            return
        }
        // Debounce key-repeat; a deliberate second pin of the same capture
        // still works after a moment (or immediately via the context menus).
        if let last = lastHotkeyPin, last.url == url,
           eventTime - last.at < 0.8 {
            // Repeat events keep moving the quiet-period boundary forward, so
            // holding the shortcut never leaks one pin every 0.8 seconds.
            lastHotkeyPin = (url, eventTime)
            return
        }
        lastHotkeyPin = (url, eventTime)
        pin(url: url, on: screen)
    }

    func close(id: UUID) {
        fileWatchers.removeValue(forKey: id)?.cancel()
        guard let panel = pins.removeValue(forKey: id) else { return }
        panel.prepareForClose()
        panel.orderOut(nil)
        if pins.isEmpty { cascadeIndex = 0 }
    }

    func closeAll() {
        for id in Array(pins.keys) { close(id: id) }
    }

    private func reassertPins() {
        for panel in pins.values { panel.orderFrontRegardless() }
    }

    // MARK: File watching

    /// A pin showing a trashed file is misleading — close it, matching the
    /// archive's behavior for deleted screenshots.
    private func startWatching(url: URL, id: UUID) {
        let path = url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            if !FileManager.default.fileExists(atPath: path) {
                self?.close(id: id)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }

        fileWatchers[id] = source
        source.resume()
    }

    // MARK: Image metadata

    // Reads pixel dimensions inside the active security scope so CGImageSource
    // can open sandboxed files in user-chosen save directories.
    private func imagePixelSize(at url: URL) -> CGSize {
        let fallback = CGSize(width: 1200, height: 800)
        let result = try? AppSettings.withSaveDirectoryAccess { _ -> CGSize in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let pw = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let ph = props[kCGImagePropertyPixelHeight] as? NSNumber,
                  pw.intValue > 0, ph.intValue > 0
            else { return fallback }
            return CGSize(width: pw.intValue, height: ph.intValue)
        }
        return result ?? fallback
    }
}
