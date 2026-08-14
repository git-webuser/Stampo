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

        override var isOpaque: Bool { false }

        /// Purely a measuring device: it must never take a click away from the
        /// canvas underneath it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
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

        func report() {
            guard let window, bounds.width > 0, bounds.height > 0 else {
                onChange?(nil)
                return
            }
            onChange?(window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
