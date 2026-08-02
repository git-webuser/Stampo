import AppKit
import Testing
@testable import Stampo

@Suite struct ThumbnailHUDGeometryTests {

    private let inset = ThumbnailHUDGeometry.inset
    private let maxBox = ThumbnailHUDGeometry.maxImageBox
    private let minBox = ThumbnailHUDGeometry.minImageBox

    /// The point of sizing the picture first: whatever the capture's shape, the
    /// plate around it is the same width on all four sides.
    @Test func theBandIsTheSameOnEverySide() {
        for pixels in [CGSize(width: 2560, height: 1600),   // laptop screen
                       CGSize(width: 1200, height: 1200),   // square
                       CGSize(width: 400, height: 900),     // a tall window
                       CGSize(width: 3000, height: 240),    // a strip
                       CGSize(width: 90, height: 1400)] {   // a sliver
            let layout = ThumbnailHUDGeometry.layout(imagePixels: pixels)
            #expect(layout.panelSize.width - layout.imageBox.width == 2 * inset)
            #expect(layout.panelSize.height - layout.imageBox.height == 2 * inset)
        }
    }

    @Test func ordinaryCapturesAreShownWholeAtTheirOwnAspect() {
        for pixels in [CGSize(width: 2560, height: 1600),
                       CGSize(width: 1920, height: 1080),
                       CGSize(width: 1200, height: 1200),
                       CGSize(width: 600, height: 1200)] {
            let layout = ThumbnailHUDGeometry.layout(imagePixels: pixels)
            #expect(!layout.cropsToFill, "\(pixels) should not need a crop")
            let aspect = pixels.width / pixels.height
            #expect(abs(layout.imageBox.width / layout.imageBox.height - aspect) < 0.01)
            #expect(layout.imageBox.width <= maxBox.width + 0.5)
            #expect(layout.imageBox.height <= maxBox.height + 0.5)
        }
    }

    /// Past the floor the picture can no longer keep its aspect at this size,
    /// and that is exactly when it starts filling the box instead.
    @Test func slitsFillTheBoxRatherThanShrinkToAThread() {
        let strip = ThumbnailHUDGeometry.layout(imagePixels: CGSize(width: 3000, height: 240))
        #expect(strip.cropsToFill)
        #expect(strip.imageBox.height == minBox.height)
        #expect(strip.imageBox.width == maxBox.width)

        let sliver = ThumbnailHUDGeometry.layout(imagePixels: CGSize(width: 90, height: 1400))
        #expect(sliver.cropsToFill)
        #expect(sliver.imageBox.width == minBox.width)
        #expect(sliver.imageBox.height == maxBox.height)
    }

    /// The crop is only ever the difference the floor introduced, so it starts
    /// at nothing on the threshold — no visible jump between two captures a
    /// pixel apart in shape.
    @Test func theCropStartsAtNothingOnTheThreshold() {
        let wideThreshold = maxBox.width / minBox.height          // ≈ 4.64 : 1
        let justInside = ThumbnailHUDGeometry.layout(
            imagePixels: CGSize(width: wideThreshold * 100 - 1, height: 100))
        #expect(!justInside.cropsToFill)
        #expect(abs(justInside.imageBox.height - minBox.height) < 0.1)

        let justPast = ThumbnailHUDGeometry.layout(
            imagePixels: CGSize(width: wideThreshold * 100 + 1, height: 100))
        #expect(justPast.cropsToFill)
        #expect(abs(justPast.imageBox.height - minBox.height) < 0.1)

        let tallThreshold = minBox.width / maxBox.height          // ≈ 1 : 2.25
        let tallInside = ThumbnailHUDGeometry.layout(
            imagePixels: CGSize(width: tallThreshold * 100 + 1, height: 100))
        #expect(!tallInside.cropsToFill)
        let tallPast = ThumbnailHUDGeometry.layout(
            imagePixels: CGSize(width: tallThreshold * 100 - 1, height: 100))
        #expect(tallPast.cropsToFill)
    }

    @Test func thePanelNeverLeavesItsBounds() {
        for pixels in [CGSize(width: 8000, height: 60), CGSize(width: 60, height: 8000),
                       CGSize(width: 5120, height: 2880), CGSize(width: 10, height: 10)] {
            let panel = ThumbnailHUDGeometry.layout(imagePixels: pixels).panelSize
            #expect(panel.width <= maxBox.width + 2 * inset + 0.5)
            #expect(panel.height <= maxBox.height + 2 * inset + 0.5)
            #expect(panel.width >= minBox.width + 2 * inset - 0.5)
            #expect(panel.height >= minBox.height + 2 * inset - 0.5)
        }
    }

    /// A file whose dimensions could not be read still gets a sane panel.
    @Test func unreadableDimensionsFallBackToTheFullBox() {
        let layout = ThumbnailHUDGeometry.layout(imagePixels: .zero)
        #expect(layout.imageBox == maxBox)
        #expect(!layout.cropsToFill)
    }

    /// Concentric roundings: the picture's corner is the plate's minus the band
    /// it sits in, or the dark frame looks wider at the corners than along the
    /// straight runs.
    @Test func theTwoRoundingsAreConcentric() {
        #expect(ThumbnailHUDGeometry.imageRadius
                == ThumbnailHUDGeometry.plateRadius - ThumbnailHUDGeometry.inset)
    }
}
