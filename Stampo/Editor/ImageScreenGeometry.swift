import AppKit
import SwiftUI

// MARK: - ImageScreenGeometry

/// Where the fitted image currently sits on screen, and the scale it is drawn
/// at. The editor's scanner opens its overlay over exactly this rect, so the
/// overlay covers the image and nothing else: the window's own controls stay
/// live, and a selection cannot leave the image because the panel *is* the
/// image.
///
/// `screenRect` is in AppKit screen coordinates (bottom-left origin).
/// `fitScale` converts image pixels to drawn points, so the way back from a
/// selection to pixels is a division by it.
struct ImageScreenGeometry: Equatable {
    var screenRect: NSRect
    var fitScale: CGFloat
    /// The canvas's drawn size at zoom 1, and the size of the area available
    /// for it. Both are already computed by the canvas every layout pass, and
    /// the scanner needs them to hand a forwarded pinch or Space-drag back to
    /// the same clamping the canvas's own gestures use. The image may occupy a
    /// smaller or offset rect inside that canvas when presentation is active.
    var baseDrawSize: CGSize
    var viewport: CGSize
    /// The part of the image that is actually on screen.
    ///
    /// Zoomed in, the image is larger than the area it is drawn in and hangs
    /// off every side — including up, over the toolbar and the context bar. An
    /// overlay sized to the whole image would cover those, so it is sized to
    /// this instead. Mapping a selection still uses `screenRect`: where the
    /// image *is* does not change because part of it is out of view.
    var visibleScreenRect: NSRect

    /// Clips the image's screen rect to the area it is drawn in.
    ///
    /// The two spaces disagree about which way is up — the canvas measures down
    /// from its top left, the screen up from its bottom left — so the clip is
    /// computed in view space and the resulting inset applied from the screen
    /// rect's *top* edge.
    static func visibleScreenRect(image screenRect: NSRect,
                                  imageViewRect: CGRect,
                                  viewport: CGSize) -> NSRect {
        let visible = imageViewRect.intersection(CGRect(origin: .zero, size: viewport))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return .zero }
        let insetLeft = visible.minX - imageViewRect.minX
        let insetTop = visible.minY - imageViewRect.minY
        return NSRect(x: screenRect.minX + insetLeft,
                      y: screenRect.maxY - insetTop - visible.height,
                      width: visible.width,
                      height: visible.height)
    }

    /// A selection the overlay reported in global CG coordinates → the image's
    /// own pixels, which is what the scanner crops with.
    ///
    /// No vertical flip: global CG coordinates and the annotation model's pixel
    /// space both grow downward from a top-left origin. The only step is
    /// subtracting where the image starts and dividing by how large it is being
    /// drawn — which is why zoom and scroll need no special handling. They move
    /// and resize this rect, and the arithmetic follows.
    func imagePixelRect(from cgRect: CGRect, screen: NSScreen) -> CGRect {
        guard fitScale > 0 else { return .zero }
        let imageCG = screenRectToCGRect(screenRect, screen: screen)
        return CGRect(
            x: (cgRect.minX - imageCG.minX) / fitScale,
            y: (cgRect.minY - imageCG.minY) / fitScale,
            width: cgRect.width / fitScale,
            height: cgRect.height / fitScale
        )
    }
}

// MARK: - ImageScreenFrameReporter

/// Reports its own frame in screen coordinates as it moves.
///
/// Placed over the drawn image, this answers "where is the image on screen"
/// without anyone doing the coordinate arithmetic by hand. SwiftUI measures
/// from the top left of a window, AppKit from the bottom left of a screen, and
/// a hand-rolled chain through both — plus the window's own origin — is the
/// kind of code that lands a scan somewhere plausible but wrong. `NSView`
/// already knows how to answer this, so it is asked.
struct ImageScreenFrameReporter: NSViewRepresentable {
    var onChange: (NSRect?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ReporterView else { return }
        view.onChange = onChange
        view.report()
    }

    final class ReporterView: NSView {
        var onChange: ((NSRect?) -> Void)?

        /// What was last handed to `onChange`, so an unchanged rect is not
        /// reported again.
        ///
        /// `updateNSView` calls `report()` on every render of the canvas, and
        /// the owner writes the result into `@State`, which publishes on
        /// assignment rather than on change — so reporting an identical rect
        /// schedules the render that reports it again. The `Bool` distinguishes
        /// "never reported" from "reported nil".
        private var lastReported: (rect: NSRect?, sent: Bool) = (nil, false)

        private var windowObservers: [NSObjectProtocol] = []

        override var isOpaque: Bool { false }

        /// Purely a measuring device: it must never take a click away from the
        /// canvas underneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindow()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        isolated deinit {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
        }

        /// A window moving changes where the image is without changing this
        /// view's frame inside it, so none of the overrides above fire and the
        /// last reported rect silently describes the old position. Dragging the
        /// window and then scanning would land the region offset by exactly how
        /// far it travelled.
        private func observeWindow() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            guard let window else { return }

            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification,
                         NSWindow.didResizeNotification,
                         NSWindow.didChangeScreenNotification] {
                windowObservers.append(
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    }
                )
            }
        }

        func report() {
            let rect: NSRect?
            if let window, bounds.width > 0, bounds.height > 0 {
                rect = window.convertToScreen(convert(bounds, to: nil))
            } else {
                rect = nil
            }

            guard !lastReported.sent || lastReported.rect != rect else { return }
            lastReported = (rect, true)
            onChange?(rect)
        }
    }
}
