import AppKit
import Testing
@testable import Stampo

/// What the menu bar actually shows, read back from the pixels.
///
/// Both of these were found by eye and would have been found by nothing else:
/// the paths were right, the layers were right, and the drawing was wrong.
@MainActor @Suite struct MascotViewTests {

    private let zoom = 8

    private func render(_ state: MascotState) -> NSBitmapImageRep? {
        let view = MascotStatusView(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
        view.appearance = NSAppearance(named: .darkAqua)
        view.setState(state)
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 22 * zoom, pixelsHigh: 18 * zoom,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let layer = view.layer else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(zoom), y: CGFloat(zoom))
        layer.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func isInked(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let colour = rep.colorAt(x: x, y: y) else { return false }
        return colour.alphaComponent > 0.4 && colour.brightnessComponent > 0.5
    }

    /// Nothing runs down the middle of the hare's face.
    ///
    /// The outline has a sharp notch between the ears, and a shape layer joins
    /// its lines with a miter unless told otherwise: the two nearly parallel
    /// strokes meeting there grew a spike ten line-widths long, straight down
    /// the face and past the eyes. The body it replaced was a squircle, so
    /// nothing had ever asked the question.
    @Test func theNotchBetweenTheEarsIsNotASpike() throws {
        let rep = try #require(render(.sleeping))
        // The middle of the face, between where the notch ends and where the
        // eyes begin — clean in the drawing, and where the spike ran. Below the
        // eyes there is nowhere to look: their own stroke reaches the middle.
        let middle = 11 * zoom
        for y in (10 * zoom + 4)..<(12 * zoom) {
            for x in (middle - 1)...(middle + 1) {
                #expect(!isInked(rep, x, y),
                        "ink at \(x),\(y): the notch is drawing a spike again")
            }
        }
    }

    /// The carve in the eye is a highlight, not a pupil: it stays away from
    /// what the hare is looking at, the way a light does not move when an eye
    /// does. Looking one way the eye is the mirror of looking the other.
    ///
    /// Read from the path rather than from the pixels: the eye travels with
    /// the gaze, and every window drawn around it at fixed coordinates catches
    /// either the body's wall or the notch between the ears, both of which
    /// outweigh a two-point eye.
    @Test func theGlintSitsAwayFromTheGaze() throws {
        func eye(_ state: MascotState) throws -> (span: ClosedRange<CGFloat>, first: CGFloat) {
            let view = MascotStatusView(frame: NSRect(x: 0, y: 0, width: 22, height: 18))
            view.setState(state)
            var points: [CGPoint] = []
            try #require(view.eyePathsForTesting.0)
                .applyWithBlock { points.append($0.pointee.points[0]) }
            let xs = points.map(\.x)
            let low = try #require(xs.min()), high = try #require(xs.max())
            return (low...high, try #require(xs.first))
        }

        let left = try eye(.colorPicking(.leftCenter))
        let right = try eye(.colorPicking(.rightCenter))

        // The same eye, the same width, in two places.
        let width = left.span.upperBound - left.span.lowerBound
        #expect(abs((right.span.upperBound - right.span.lowerBound) - width) < 0.01)
        #expect(right.span.lowerBound > left.span.lowerBound, "the eye did not follow the gaze")

        // And drawn as each other's mirror: what is a fraction `f` across one
        // is `1 - f` across the other.
        let acrossLeft = (left.first - left.span.lowerBound) / width
        let acrossRight = (right.first - right.span.lowerBound) / width
        #expect(abs(acrossLeft + acrossRight - 1) < 0.02,
                "the eye is drawn the same way whichever way the hare looks")
    }

    /// Every state draws something, which is the least a mascot can do.
    @Test func everyStateDrawsAHare() throws {
        for state in [MascotState.sleeping, .awake, .waiting, .countdown,
                      .colorPicking(.leftUp), .celebrating] {
            let rep = try #require(render(state))
            var inked = 0
            for y in 0..<(18 * zoom) where inked == 0 {
                for x in 0..<(22 * zoom) where isInked(rep, x, y) { inked += 1 }
            }
            #expect(inked > 0, "\(state) drew nothing at all")
        }
    }
}
