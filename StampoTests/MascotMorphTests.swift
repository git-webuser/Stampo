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
        // Only the poses that face the same way. A pose and its mirror image
        // cannot be morphed into each other: every point travels straight to
        // its counterpart across the axis, so at halfway they all meet on it
        // and the hare is a vertical line. Turning to face the other way is a
        // flip of the layer, not a change of shape.
        let all = MascotArtwork.agreeingPaths()
        let facing = Set(MascotArtwork.poses.filter { !$0.mirrored }.map(\.name))
        let poses = all.filter { facing.contains($0.name) }
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

    /// Why the sheet above leaves the mirrors out.
    ///
    /// A pose and its mirror image agree on their structure, so nothing refuses
    /// the morph — and at halfway every point has travelled straight to its
    /// counterpart across the axis, which is to say they have all arrived on
    /// the axis. The hare is a vertical line. Turning to face the other way is
    /// a flip of the layer, not a change of shape, and it is also the truer
    /// animation: the hare turns rather than melting.
    @Test func aPoseAndItsMirrorCollapseIntoALine() throws {
        let poses = MascotArtwork.agreeingPaths()
        let right = try #require(poses.first { $0.name == "earsWide" })
        let left = try #require(poses.first { $0.name == "earsWideLeft" })

        let halfway = try #require(right.path.interpolated(to: left.path, at: 0.5))
        let box = halfway.cgPath.boundingBoxOfPath
        #expect(box.width < 1, "the mirrors did not collapse — has the pairing changed?")
        #expect(box.height > 8, "…but it is still as tall as the hare")

        // Where they face the same way, the middle of the journey is a hare.
        let folded = try #require(poses.first { $0.name == "foldedRight" })
        let travelling = try #require(right.path.interpolated(to: folded.path, at: 0.5))
        #expect(travelling.cgPath.boundingBoxOfPath.width > 8)
    }
}
