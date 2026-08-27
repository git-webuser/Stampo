import AppKit
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Stampo

/// The idle loop, written to a GIF so it can be watched rather than imagined.
///
/// A morph is a matter of timing as much as of shape: the same two poses read
/// as a twitch, a stretch or a shrug depending on how long the journey takes
/// and where it pauses. Nothing in a sheet of frames says which.
@Suite struct MascotLoopProbe {

    /// One beat of the loop: where to be, how long to take getting there, and
    /// how long to stay once arrived.
    private struct Beat {
        let pose: String
        let travel: Double
        let hold: Double
    }

    @Test func idle() throws {
        let poses = Dictionary(uniqueKeysWithValues: MascotArtwork.agreeingPaths()
            .map { ($0.name, $0.path) })

        // Ears first: the hare is awake, listens, flicks one ear, settles.
        let beats = [
            Beat(pose: "awake",        travel: 0.0,  hold: 1.6),
            Beat(pose: "earsWide",     travel: 0.22, hold: 0.5),
            Beat(pose: "awake",        travel: 0.26, hold: 1.1),
            Beat(pose: "foldedRight",  travel: 0.20, hold: 0.4),
            Beat(pose: "foldedLeft",   travel: 0.30, hold: 0.4),
            Beat(pose: "awake",        travel: 0.24, hold: 1.8)
        ]

        let fps = 30.0
        let scale: CGFloat = 10          // the 12pt box drawn at 120
        let side = Int(MascotArtwork.side * scale)
        let url = URL(fileURLWithPath: "/tmp/mascot-idle.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 0, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        /// Fast away, slow to settle — an ear does not travel at a constant
        /// speed and neither should the morph.
        func eased(_ t: Double) -> CGFloat {
            CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
        }

        var previous = try #require(poses[beats[0].pose])
        for beat in beats {
            let target = try #require(poses[beat.pose])
            let travelFrames = Int((beat.travel * fps).rounded())
            let holdFrames = Int((beat.hold * fps).rounded())
            for frame in 0..<max(travelFrames, 0) {
                let t = eased(Double(frame + 1) / Double(travelFrames))
                let between = try #require(previous.interpolated(to: target, at: t))
                add(between, to: destination, side: side, scale: scale, seconds: 1 / fps)
            }
            for _ in 0..<holdFrames {
                add(target, to: destination, side: side, scale: scale, seconds: 1 / fps)
            }
            previous = target
        }
        #expect(CGImageDestinationFinalize(destination))
        print("LOOP /tmp/mascot-idle.gif")
    }

    /// One frame: the pose, and the two eyes that make it a face.
    private func add(_ pose: VectorPath, to destination: CGImageDestination,
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

        context.setFillColor(CGColor(gray: 1, alpha: 0.92))
        for centre in [MascotArtwork.Eye.left, MascotArtwork.Eye.right] {
            context.fillEllipse(in: CGRect(x: centre.x - 1, y: centre.y - 1, width: 2, height: 2))
        }
        guard let image = context.makeImage() else { return }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: seconds]
        ] as CFDictionary)
    }
}
