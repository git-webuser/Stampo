import AppKit
import Testing
@testable import Stampo

/// The editor's scanner reports a selection in the screen's coordinates and
/// crops the document in its own pixels. Everything that makes zoom, scroll and
/// a multi-display layout work lives in that one conversion, so it is asserted
/// directly rather than through the canvas.
@MainActor
@Suite struct EditorScanGeometryTests {

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    /// An image drawn at half size, parked away from the display's corner so a
    /// conversion that forgot to subtract the origin cannot pass by accident.
    private func geometry(fitScale: CGFloat = 0.5,
                          origin: CGPoint? = nil) -> ImageScreenGeometry {
        let start = origin ?? CGPoint(x: screen.frame.minX + 100,
                                      y: screen.frame.minY + 80)
        let rect = NSRect(origin: start, size: CGSize(width: 400, height: 300))
        return ImageScreenGeometry(
            screenRect: rect,
            fitScale: fitScale,
            baseDrawSize: CGSize(width: 800, height: 600),
            viewport: CGSize(width: 900, height: 700),
            visibleScreenRect: rect
        )
    }

    @Test func selectingTheWholeImageYieldsTheWholeImage() {
        let geo = geometry()
        let everything = screenRectToCGRect(geo.screenRect, screen: screen)
        let pixels = geo.imagePixelRect(from: everything, screen: screen)

        #expect(pixels.minX == 0)
        #expect(pixels.minY == 0)
        #expect(pixels.width == 800)
        #expect(pixels.height == 600)
    }

    /// Global CG coordinates and the annotation model's pixel space both grow
    /// downward. A flip smuggled into the conversion would mirror every scan
    /// about the image's middle — which looks like a plausible region, just not
    /// the one the user drew.
    @Test func draggingDownTheScreenMovesDownTheImage() {
        let geo = geometry()
        let imageCG = screenRectToCGRect(geo.screenRect, screen: screen)
        let atTop = CGRect(x: imageCG.minX, y: imageCG.minY, width: 10, height: 10)
        let lower = atTop.offsetBy(dx: 0, dy: 50)

        let topPixels = geo.imagePixelRect(from: atTop, screen: screen)
        let lowerPixels = geo.imagePixelRect(from: lower, screen: screen)

        #expect(topPixels.minY == 0)
        #expect(lowerPixels.minY == topPixels.minY + 100)
    }

    /// Zoom is not a special case: it changes where the image sits and how big
    /// it is drawn, and the same selection relative to the image has to come
    /// back as the same pixels at any scale.
    @Test func theSameRegionOfTheImageSurvivesAChangeOfZoom() {
        let half = geometry(fitScale: 0.5)
        let fullRect = NSRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10,
                              width: 800, height: 600)
        let full = ImageScreenGeometry(
            screenRect: fullRect,
            fitScale: 1.0,
            baseDrawSize: CGSize(width: 800, height: 600),
            viewport: CGSize(width: 900, height: 700),
            visibleScreenRect: fullRect
        )

        func quarterOfImage(_ geo: ImageScreenGeometry) -> CGRect {
            let cg = screenRectToCGRect(geo.screenRect, screen: screen)
            return CGRect(x: cg.minX, y: cg.minY,
                          width: cg.width / 2, height: cg.height / 2)
        }

        #expect(
            half.imagePixelRect(from: quarterOfImage(half), screen: screen)
            == full.imagePixelRect(from: quarterOfImage(full), screen: screen)
        )
    }

    /// The overlay is re-framed while it is armed — zoom, pan, a dragged
    /// window — so the mapping has to be read from where the image is at drop
    /// time. Selecting the same spot on screen after the image moved must name
    /// a different part of it.
    @Test func aMovedImageMapsTheSameScreenPointElsewhere() {
        let before = geometry()
        let after = geometry(origin: CGPoint(x: before.screenRect.minX + 40,
                                             y: before.screenRect.minY))
        let onScreen = CGRect(
            x: screenRectToCGRect(before.screenRect, screen: screen).minX + 100,
            y: screenRectToCGRect(before.screenRect, screen: screen).minY + 20,
            width: 10, height: 10
        )

        let pixelsBefore = before.imagePixelRect(from: onScreen, screen: screen)
        let pixelsAfter = after.imagePixelRect(from: onScreen, screen: screen)

        #expect(pixelsBefore.minX == 200)
        // The image slid 40pt right, so the same screen point is 40pt — 80px at
        // this scale — further left within it.
        #expect(pixelsAfter.minX == pixelsBefore.minX - 80)
        #expect(pixelsAfter.minY == pixelsBefore.minY)
    }

    @Test func adegenerateScaleCannotDivideByZero() {
        let geo = geometry(fitScale: 0)
        #expect(geo.imagePixelRect(from: CGRect(x: 0, y: 0, width: 10, height: 10),
                                   screen: screen) == .zero)
    }

    /// The canvas re-renders constantly, and each render asks the reporter to
    /// measure again. If an unchanged rect were still handed on, the owner's
    /// `@State` write would schedule the render that measures it again.
    @Test func theReporterStaysQuietWhenNothingMoved() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = ImageScreenFrameReporter.ReporterView(
            frame: NSRect(x: 10, y: 10, width: 100, height: 80)
        )
        var reports = 0
        view.onChange = { _ in reports += 1 }
        window.contentView?.addSubview(view)

        view.report()
        let afterFirst = reports
        view.report()
        view.report()

        #expect(afterFirst >= 1)
        #expect(reports == afterFirst)

        view.setFrameOrigin(NSPoint(x: 40, y: 10))
        #expect(reports == afterFirst + 1)
    }

    /// Zoomed in, the image is bigger than the area it is drawn in and hangs
    /// off every side. The overlay is sized to the visible part, or it would
    /// cover the toolbar and the context bar above the canvas.
    @Test func theVisibleRectClipsAnImageLargerThanItsViewport() {
        let screenRect = NSRect(x: 500, y: 400, width: 1000, height: 800)
        // Drawn 1000×800 inside a 600×500 area, hanging 200pt off the left and
        // 150pt off the top.
        let clipped = ImageScreenGeometry.visibleScreenRect(
            image: screenRect,
            imageViewRect: CGRect(x: -200, y: -150, width: 1000, height: 800),
            viewport: CGSize(width: 600, height: 500)
        )

        #expect(clipped.width == 600)
        #expect(clipped.height == 500)
        // 200pt in from the left edge of the image...
        #expect(clipped.minX == screenRect.minX + 200)
        // ...and 150pt down from its top, which is the *high* edge on screen.
        #expect(clipped.maxY == screenRect.maxY - 150)
    }

    /// An image smaller than its viewport is entirely visible, so clipping must
    /// hand back exactly where it is.
    @Test func theVisibleRectLeavesAFittedImageAlone() {
        let screenRect = NSRect(x: 500, y: 400, width: 200, height: 150)
        let clipped = ImageScreenGeometry.visibleScreenRect(
            image: screenRect,
            imageViewRect: CGRect(x: 50, y: 40, width: 200, height: 150),
            viewport: CGSize(width: 600, height: 500)
        )
        #expect(clipped == screenRect)
    }

    /// Three surfaces zoom the canvas — the pinch gesture, the toolbar's ±, and
    /// the scan overlay's forwarded pinch. The bounds were written out twice
    /// before they moved here.
    @Test func zoomIsClampedToOneRange() {
        #expect(EditorViewportGeometry.clampedZoom(100) == 8)
        #expect(EditorViewportGeometry.clampedZoom(0) == 0.25)
        #expect(EditorViewportGeometry.clampedZoom(2) == 2)
    }
}
