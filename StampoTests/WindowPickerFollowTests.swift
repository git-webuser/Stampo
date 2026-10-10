import CoreGraphics
import Testing
@testable import Stampo

/// The window picker is one window over one display and follows the pointer to
/// the next: what it needs to know — which display the pointer is on, and where
/// a point of that display's view is in the window list's coordinates — is
/// arithmetic on frames, so it is tested on frames and not on the displays this
/// machine happens to have.
@Suite struct WindowPickerFollowTests {
    /// A laptop, and a taller monitor to its right whose bottom edge is lower
    /// than the laptop's (AppKit's coordinates: origin at the bottom left of the
    /// primary display, y up), and one above the laptop.
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let monitor = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
    private let above = CGRect(x: 0, y: 900, width: 1440, height: 900)

    @Test func theDisplayUnderThePointerIsTheOneWhoseFrameHoldsIt() {
        let frames = [laptop, monitor, above]
        func screen(_ x: CGFloat, _ y: CGFloat) -> Int? {
            ScreenUnderPointer.index(of: CGPoint(x: x, y: y), in: frames)
        }
        // Well inside each.
        #expect(screen(700, 450) == 0)
        #expect(screen(2400, 400) == 1)
        #expect(screen(700, 1300) == 2)
        // The monitor is taller: its part below the laptop's bottom edge is its own.
        #expect(screen(1500, -170) == 1)
        // Below the laptop, where no display is.
        #expect(screen(700, -10) == nil)
        // Left of everything, and past everything.
        #expect(screen(-1, 450) == nil)
        #expect(screen(4000, 450) == nil)
    }

    @Test func aPointOnTheLineTwoDisplaysShareIsOnTheOneItHasEntered() {
        let frames = [laptop, monitor, above]
        func screen(_ x: CGFloat, _ y: CGFloat) -> Int? {
            ScreenUnderPointer.index(of: CGPoint(x: x, y: y), in: frames)
        }
        // Going right: the last point of the laptop, then the first of the monitor.
        #expect(screen(1439.99, 450) == 0)
        #expect(screen(1440, 450) == 1)
        // Going up: the laptop's last row, then the display above it.
        #expect(screen(700, 899.99) == 0)
        #expect(screen(700, 900) == 2)
        // The laptop's top edge at the monitor's side: the monitor is lower, so
        // y = 900 is past its top edge as well, and on neither.
        #expect(screen(2000, 900) == nil)
        // The outer edges: held on the left and bottom, not on the right and top.
        #expect(screen(0, 0) == 0)
        #expect(screen(3360, 400) == nil)
        // No displays, or none under the point.
        #expect(ScreenUnderPointer.index(of: CGPoint(x: 5, y: 5), in: []) == nil)
    }

    /// Where a point of the view on the second display is in the window list's
    /// coordinates (origin at the top left of the primary display, y down), and
    /// where a window found there is in the view: the frame of the display the
    /// overlay is on, and the primary's height, are all it takes.
    @Test func theHighlightIsFoundInTheCoordinatesOfTheDisplayTheOverlayIsOn() {
        let primaryHeight = laptop.height
        // The same view point on the laptop and on the monitor.
        let point = CGPoint(x: 100, y: 200)
        let onLaptop = viewPointToCGPoint(point, screenFrame: laptop, primaryHeight: primaryHeight)
        let onMonitor = viewPointToCGPoint(point, screenFrame: monitor, primaryHeight: primaryHeight)
        #expect(onLaptop == CGPoint(x: 100, y: 700))
        // 1440 to the right, and the monitor's bottom is 180 below the laptop's.
        #expect(onMonitor == CGPoint(x: 1540, y: 880))

        // A window of the monitor's, in the list's coordinates, in its view.
        let window = CGRect(x: 1500, y: 700, width: 400, height: 300)
        let inView = cgRectToViewRect(window, screenFrame: monitor, primaryHeight: primaryHeight)
        #expect(inView == CGRect(x: 60, y: 80, width: 400, height: 300))
        // The point that is in the window on the screen is in the highlight in the view.
        #expect(window.contains(onMonitor))
        #expect(inView.contains(point))
        // The laptop's frame would have put it elsewhere entirely.
        let wrong = cgRectToViewRect(window, screenFrame: laptop, primaryHeight: primaryHeight)
        #expect(wrong.minX == 1500 && !wrong.contains(point))
        // A round trip: the view's corners come back to the window's.
        let topLeft = viewPointToCGPoint(CGPoint(x: inView.minX, y: inView.maxY),
                                         screenFrame: monitor, primaryHeight: primaryHeight)
        #expect(topLeft == CGPoint(x: window.minX, y: window.minY))
    }
}
