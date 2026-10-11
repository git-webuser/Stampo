import CoreGraphics
import Foundation

/// An experiment with where a scrolling capture's wheel goes, for Debug builds
/// only: some pages send the wheel to the element under the real pointer rather
/// than under the point of the event, and a pointer left on a box with a scroll
/// of its own (the "Try it" example on MDN) turns the box, not the page.
///
///     defaults write com.hex000.Stampo scrollCaptureExperimentPointer -string strip
///     defaults write com.hex000.Stampo scrollCaptureExperimentPointer -string strip-pid
///     defaults delete com.hex000.Stampo scrollCaptureExperimentPointer
///
/// With a flag, once the probe has matched the pointer is moved to the strip's
/// left edge and the capture does not wait for it there; at the end it is put
/// back where it was. `strip` sends the wheel as it is sent now; `strip-pid`
/// posts it to the process of the window.
nonisolated enum ScrollPointerExperiment {
    static let defaultsKey = "scrollCaptureExperimentPointer"

    enum Mode: String {
        case strip
        case stripPid = "strip-pid"

        /// Whether the wheel goes to the process, not through the event tap.
        var postsToProcess: Bool { self == .stripPid }
    }

    /// The mode asked for. Always nil in a Release build.
    @MainActor
    static func current() -> Mode? {
        #if DEBUG
        return AppSettings.store.string(forKey: defaultsKey).flatMap(Mode.init(rawValue:))
        #else
        return nil
        #endif
    }

    /// Where the pointer is put: the left edge of the strip, in the middle of
    /// its height, a few points in.
    static func placement(strip: CGRect) -> CGPoint {
        CGPoint(x: strip.minX + 4, y: strip.midY)
    }

    /// Whether the pointer still stands where it was put.
    static func isAtPlacement(pointer: CGPoint, placed: CGPoint) -> Bool {
        abs(pointer.x - placed.x) <= 3 && abs(pointer.y - placed.y) <= 3
    }
}
