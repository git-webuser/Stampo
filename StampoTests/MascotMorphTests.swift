import AppKit
import Testing
@testable import Stampo

/// The stand: every pose, and every step of the travel between them, drawn
/// into one sheet.
///
/// A morph is judged by whether the shape stays a hare while it moves, and
/// nothing but an eye can judge that — two paths can agree on their structure
/// and still turn inside out on the way. The steps are computed the way
/// CoreAnimation computes them, every control point moving in a straight line
/// towards its opposite number, so what is drawn here is what the menu bar
/// will show.
///
/// Not a test: it writes a picture and passes. Run it on its own —
///
///     xcodebuild test -only-testing:StampoTests/MascotStandProbe …
///
/// — and look at /tmp/mascot-stand.png.
@Suite struct MascotMorphTests {

    @Test func everyPoseTravelsToTheNextWithoutFallingApart() throws {
        let poses = MascotArtwork.agreeingPaths()
        let scale: CGFloat = 6
        let cell = Int(MascotArtwork.side * scale) + 8
        let steps = 5                       // t = 0, ¼, ½, ¾, 1
        let rows = poses.count              // each pose travelling to the next
        let width = cell * steps, height = cell * rows

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let ctx = context.cgContext
        ctx.setFillColor(CGColor(gray: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (row, pose) in poses.enumerated() {
            let next = poses[(row + 1) % poses.count]
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps - 1)
                guard let between = pose.path.interpolated(to: next.path, at: t) else {
                    Issue.record("\(pose.name) → \(next.name) cannot be walked at all")
                    continue
                }
                ctx.saveGState()
                // Top-left origin for the artwork, inside its own cell.
                ctx.translateBy(x: CGFloat(step * cell) + 4,
                                y: CGFloat(height - row * cell) - 4)
                ctx.scaleBy(x: scale, y: -scale)
                ctx.addPath(between.cgPath)
                ctx.setStrokeColor(CGColor(gray: 1, alpha: step == 0 || step == steps - 1 ? 0.95 : 0.55))
                ctx.setLineWidth(1)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/mascot-facing.png"))
        print("STAND /tmp/mascot-facing.png \(width)x\(height)")
    }

    /// The trap the mirrored poses used to fall into, and the way out.
    ///
    /// A mirror alone keeps the anchors in the order they were written, so
    /// every point's partner sits directly across the axis — and the morph
    /// walks them all onto it: at halfway the hare is a vertical line, eleven
    /// points tall and none wide. Travelling the mirror backwards puts the
    /// anchors back in anatomical order, and then the same journey lowers one
    /// ear while the other rises, which is what it should have been describing
    /// all along.
    @Test func aMirroredPoseMorphsByChangingShapeRatherThanCollapsing() throws {
        let wide = try #require(VectorPath.parse(
            MascotArtwork.earsWide.replacingOccurrences(of: "\n", with: "")))

        // Mirrored the plain way: the two agree on their structure, nothing
        // refuses the morph, and the middle of it is a line.
        let acrossTheAxis = wide.mirrored(in: MascotArtwork.side)
        let collapsing = try #require(wide.interpolated(to: acrossTheAxis, at: 0.5))
        #expect(collapsing.cgPath.boundingBoxOfPath.width < 1)
        #expect(collapsing.cgPath.boundingBoxOfPath.height > 8)

        // Mirrored for morphing: the middle of the journey is a hare.
        let anatomical = wide.mirroredForMorphing(in: MascotArtwork.side)
        let travelling = try #require(wide.interpolated(to: anatomical, at: 0.5))
        let box = travelling.cgPath.boundingBoxOfPath
        #expect(box.width > 8, "the hare lost its width on the way")
        #expect(box.height > 8, "the hare lost its height on the way")
        // And it is still standing where the poses stand.
        #expect(box.minX > -0.01 && box.maxX < MascotArtwork.side + 0.01)
    }

    /// Travelling a path backwards draws the same path.
    @Test func reversingChangesTheOrderAndNothingElse() throws {
        let path = try #require(VectorPath.parse(
            MascotArtwork.earsUp.replacingOccurrences(of: "\n", with: "")))
        let back = path.reversed()
        #expect(back.structure == path.structure)
        #expect(back.reversed() == path, "twice round is not where it started")
        #expect(back.start == path.cgPath.currentPoint, "it does not start where the other ended")
    }
}
