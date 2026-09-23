import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Stampo

/// Two ways for the ears to answer a pointer, written out as film so the
/// difference can be seen rather than argued about.
///
/// The pointer sweeps from the far left of the screen to the far right and
/// back. In one strip the near ear folds away from it; in the other the ears
/// spread towards the far side. Both are the same journey, the same timing —
/// only which pose the lean reaches for differs.
@Suite struct MascotLeanProbe {

    @Test func sweep() throws {
        let poses = Dictionary(uniqueKeysWithValues: MascotArtwork.agreeingPaths()
            .map { ($0.name, $0.path) })

        try write(named: "fold", left: try #require(poses["earFoldedLeft"]),
                  middle: try #require(poses["earsUp"]),
                  right: try #require(poses["earFoldedRight"]))
        try write(named: "spread", left: try #require(poses["earsSpreadLeft"]),
                  middle: try #require(poses["earsUp"]),
                  right: try #require(poses["earsSpreadRight"]))
        print("LEAN /tmp/mascot-lean-fold.gif /tmp/mascot-lean-spread.gif")
    }

    /// One sweep: pointer far left, through the middle, to far right and back.
    private func write(named name: String, left: VectorPath,
                       middle: VectorPath, right: VectorPath) throws {
        let fps = 30.0, seconds = 4.0
        let scale: CGFloat = 10
        let side = Int(MascotArtwork.side * scale)
        let url = URL(fileURLWithPath: "/tmp/mascot-lean-\(name).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 0, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frames = Int(seconds * fps)
        for frame in 0..<frames {
            // Where the pointer is: −1 far left, +1 far right, there and back.
            let phase = Double(frame) / Double(frames)
            let pointer = CGFloat(sin(phase * 2 * .pi))
            // The ears lean away from it, and the eyes follow it.
            let lean = pointer < 0
                ? middle.interpolated(to: left, at: -pointer)
                : middle.interpolated(to: right, at: pointer)
            guard let pose = lean else { continue }
            add(pose, gaze: pointer, to: destination, side: side, scale: scale, seconds: 1 / fps)
        }
        #expect(CGImageDestinationFinalize(destination))
    }

    private func add(_ pose: VectorPath, gaze: CGFloat, to destination: CGImageDestination,
                     side: Int, scale: CGFloat, seconds: Double) {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.13, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: scale, y: -scale)

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.92))
        context.setLineWidth(1)
        context.setLineJoin(.round)
        context.addPath(pose.cgPath)
        context.strokePath()

        // The eyes look where the pointer is — half a point of travel, which is
        // all a two-point eye has room for.
        context.setFillColor(CGColor(gray: 1, alpha: 0.92))
        for centre in [MascotArtwork.Eye.left, MascotArtwork.Eye.right] {
            let x = centre.x + gaze * 0.5
            context.fillEllipse(in: CGRect(x: x - 1, y: centre.y - 1, width: 2, height: 2))
        }
        guard let image = context.makeImage() else { return }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: seconds]
        ] as CFDictionary)
    }
}
