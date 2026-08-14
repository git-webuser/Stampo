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
    private func geometry(fitScale: CGFloat = 0.5) -> ImageScreenGeometry {
        ImageScreenGeometry(
            screenRect: NSRect(x: screen.frame.minX + 100,
                               y: screen.frame.minY + 80,
                               width: 400, height: 300),
            fitScale: fitScale
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
        let full = ImageScreenGeometry(
            screenRect: NSRect(x: screen.frame.minX + 10,
                               y: screen.frame.minY + 10,
                               width: 800, height: 600),
            fitScale: 1.0
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

    @Test func adegenerateScaleCannotDivideByZero() {
        let geo = geometry(fitScale: 0)
        #expect(geo.imagePixelRect(from: CGRect(x: 0, y: 0, width: 10, height: 10),
                                   screen: screen) == .zero)
    }
}
