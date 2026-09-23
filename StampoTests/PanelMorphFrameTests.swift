import CoreGraphics
import Testing
@testable import Stampo

/// The panel grows past the Archive by moving the lower half of every keyframe
/// down, never by scaling. `extraFactor` is what keeps that in step with the
/// drawn frames, and it is a formula with no obvious right answer — so the
/// relationship it encodes is pinned here rather than left to be rediscovered.
@MainActor
@Suite struct PanelMorphFrameTests {

    private func points(_ frame: [CGFloat]) -> [(x: CGFloat, y: CGFloat)] {
        stride(from: 0, to: frame.count, by: 2).map { (frame[$0], frame[$0 + 1]) }
    }

    private func height(_ frame: [CGFloat]) -> CGFloat {
        points(frame).map(\.y).max() ?? 0
    }

    @Test func framesAreTheShapeThePathExpects() {
        #expect(PanelMorphShape.archiveFrames.count == 7)
        for frame in PanelMorphShape.archiveFrames {
            // 42 points, of which `path(in:)` uses 41 — the trailing pair is
            // never read, the subpath is closed instead.
            #expect(frame.count == 84)
        }
        #expect(PanelMorphShape.archiveFrames.map(height) == [34, 45, 56, 67, 78, 89, 89])
    }

    @Test func extraHeightArrivesInStepWithTheDrawnFrames() {
        // Frame i sits at progress i/6 and has covered i/5 of the climb from
        // the 34pt strip to the full 89. Anything else would let the extra
        // height lag the artwork and then snap at the end.
        for i in 0...5 {
            let progress = CGFloat(i) / 6
            #expect(abs(PanelMorphShape.extraFactor(at: progress) - CGFloat(i) / 5) < 0.0001,
                    "frame \(i)")
        }
    }

    @Test func extraHeightIsFullyArrivedBeforeTheLastFrame() {
        // Frames 5 and 6 are both 89 tall — the last step is a settle, not a
        // growth — so the extra height must already be complete at frame 5.
        #expect(PanelMorphShape.extraFactor(at: 5.0 / 6) == 1)
        #expect(PanelMorphShape.extraFactor(at: 1) == 1)
    }

    @Test func closedPanelIsNeverStretched() {
        // At rest the panel is the bare notch strip, whatever height the route
        // it is about to open would want.
        #expect(PanelMorphShape.extraFactor(at: 0) == 0)
        #expect(PanelMorphShape.extraFactor(at: -1) == 0)
    }

    @Test func theTallestTranslationOnlyLengthensTheSides() {
        // The tallest translation is 168 tall against the Archive's 89. The
        // straight sides run down to where the bottom corner starts — 168 less
        // its 36.8pt span (23 at 60% smoothing) — and both numbers fall out of
        // the one extra height.
        let extra: CGFloat = 168 - 89
        let final = points(PanelMorphShape.archiveFrames[6])
        let drop = extra * PanelMorphShape.extraFactor(at: 1)

        #expect(abs(final[10].y + drop - 131.2) < 0.0001)
        #expect(final[19].y + drop == 168)
        // Untouched: the flare that seats into the notch.
        #expect(abs(final[9].x - 15) < 0.0001 && abs(final[9].y - 15) < 0.0001)
        #expect(abs(final[30].x - 521) < 0.0001 && abs(final[30].y - 15) < 0.0001)
    }

    @Test func aShortTranslationIsAllowedToBeShorterThanTheArchive() {
        // A one-line translation asks for a body well under the archive's row,
        // so the extra height goes negative. The floor has to leave room for
        // the bottom corner's span in the final frame.
        let shortest = NotchTranslateView.minBodyHeight
        let final = points(PanelMorphShape.archiveFrames[6])
        #expect(shortest > 89 - final[10].y, "the corner curve would be squashed")
        #expect(shortest < NotchTranslateView.maxBodyHeight)
    }

    @Test(arguments: [false, true])
    func theSidesNeverFoldOnTheShortestTranslation(wide: Bool) {
        // A one-line translation pulls the lower half up by 15pt. In every
        // frame of the morph the flare has to end above where the bottom
        // corner begins, on both sides, or the side would fold back on itself.
        // The wide flares reach further down, so they are held to it too.
        let extra = 34 + NotchTranslateView.minBodyHeight - 89
        let frames = wide ? PanelMorphShape.wideArchiveFrames : PanelMorphShape.archiveFrames
        for (i, frame) in frames.enumerated() {
            let p = points(frame)
            let drop = extra * PanelMorphShape.extraFactor(at: CGFloat(i) / 6)
            #expect(p[10].y + drop > p[9].y, "left side, frame \(i)")
            #expect(p[29].y + drop > p[30].y, "right side, frame \(i)")
        }
    }

    @Test func theWideShoulderHoldsTheReferenceFlare() {
        // The point of widening: the open panel's flare is the reference's
        // own, 16 at 60%, with nothing given up to fit — it spans 25.6 of 26.
        let final = points(PanelMorphShape.wideArchiveFrames[6])
        let flare = SmoothCorner(radius: PanelCorners.flareShare * PanelCorners.ceiling,
                                 smoothing: PanelCorners.smoothing)
        #expect(flare.fitting(PanelCorners.wideShoulder).radius == flare.radius)
        #expect(abs(final[9].x - PanelCorners.wideShoulder) < 0.0001)
        #expect(abs(final[9].y - flare.span) < 0.0001)
        // The flare starts inside the frame, not past its edge.
        #expect(final[0].x > -0.0001)
        // The bottom corners are the same as in the narrow panel.
        let narrow = points(PanelMorphShape.archiveFrames[6])
        #expect(abs(final[10].y - narrow[10].y) < 0.0001)
    }

    @Test func aWidenedPanelMovesItsContentInByWhatItGained() {
        #expect(NotchMetrics.flareGain(false) == 0)
        #expect(NotchMetrics.flareGain(true) == PanelCorners.wideShoulder - PanelCorners.shoulder)
    }

    // MARK: Corners

    @Test func cornersStopGrowingAtTheShortestOpenPanel() {
        // The reference's proportions hold up to the height of a one-line
        // translation and no further, which is what keeps its bottom corner
        // inside the shortest body. Move the floor and this has to move too.
        #expect(PanelCorners.ceiling == 34 + NotchTranslateView.minBodyHeight)
        #expect(abs(PanelCorners.bottomShare * PanelCorners.ceiling - 23) < 0.0001)
        #expect(abs(PanelCorners.flareShare * PanelCorners.ceiling - 16) < 0.0001)
    }

    @Test func aFlareTooWideForTheShoulderKeepsItsSmoothing() {
        // Figma, short of room, gives up smoothing first; the panel gives up
        // radius instead, because the smoothing is the point of the shape.
        let fitted = SmoothCorner(radius: 16, smoothing: 0.6).fitting(PanelCorners.shoulder)
        #expect(fitted.smoothing == 0.6)
        #expect(abs(fitted.span - PanelCorners.shoulder) < 0.0001)
        #expect(SmoothCorner(radius: 5, smoothing: 0.6).fitting(PanelCorners.shoulder).radius == 5)
    }

    @Test func theCornersAreFigmasCornerSmoothing() {
        // Built from the radii Figma was given, the keyframes come out as the
        // ones Figma exported, to its three decimals. The Archive's flare is
        // Figma's own give: 10 at 60% needs 16pt, the shoulder has 15, and
        // Figma drops the smoothing to 50% to make it fit.
        let main = PanelCorners.keyframe(height: 34,
                                         flare: SmoothCorner(radius: 5, smoothing: 0.6),
                                         bottom: SmoothCorner(radius: 10, smoothing: 0.6))
        let archive = PanelCorners.keyframe(height: 89,
                                            flare: SmoothCorner(radius: 10, smoothing: 0.5),
                                            bottom: SmoothCorner(radius: 16, smoothing: 0.6))
        for (built, exported) in [(main, Self.figmaMain), (archive, Self.figmaArchive)] {
            #expect(built.count == exported.count)
            let worst = zip(built, exported).map { abs($0 - $1) }.max() ?? .infinity
            #expect(worst < 0.001)
        }
    }

    /// The Main and Archive keyframes as Figma exported them, before the
    /// corners were built in code.
    private static let figmaMain: [CGFloat] =
        [7,0, 9.80026,0, 11.2004,0, 12.27,0.545, 13.2108,1.024, 13.9757,1.789, 14.455,2.730, 15,3.800, 15,5.200, 15,8,
         15,18,
         15,23.601, 15,26.401, 16.090,28.540, 17.049,30.422, 18.579,31.951, 20.460,32.910, 22.599,34, 25.400,34, 31,34,
         505,34,
         510.601,34, 513.401,34, 515.54,32.910, 517.422,31.951, 518.951,30.422, 519.910,28.540, 521,26.401, 521,23.601, 521,18,
         521,8,
         521,5.200, 521,3.800, 521.545,2.730, 522.024,1.789, 522.789,1.024, 523.730,0.545, 524.800,0, 526.200,0, 529,0,
         536,0, 0,0]

    private static let figmaArchive: [CGFloat] =
        [0,0, 4.659,0, 6.989,0, 8.827,0.761, 11.277,1.776, 13.224,3.723, 14.239,6.173, 15,8.011, 15,10.341, 15,15,
         15,63.4,
         15,72.361, 15,76.841, 16.744,80.264, 18.278,83.274, 20.726,85.722, 23.736,87.256, 27.159,89, 31.639,89, 40.6,89,
         495.4,89,
         504.361,89, 508.841,89, 512.264,87.256, 515.274,85.722, 517.722,83.274, 519.256,80.264, 521,76.841, 521,72.361, 521,63.4,
         521,15,
         521,10.341, 521,8.011, 521.761,6.173, 522.776,3.723, 524.723,1.776, 527.173,0.761, 529.011,0, 531.341,0, 536,0,
         536,0, 0,0]
}
