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

    @Test func theTranslatorArtworkIsReachable() {
        // The exported Translator shape is 168 tall against the Archive's 89,
        // and the two straight sides run to 142.4 where the Archive's run to
        // 63.4. Both fall out of one number.
        let extra: CGFloat = 168 - 89
        let final = points(PanelMorphShape.archiveFrames[6])
        let drop = extra * PanelMorphShape.extraFactor(at: 1)

        #expect(final[10].y + drop == 142.4)
        #expect(final[19].y + drop == 168)
        // Untouched: the flare that seats into the notch.
        #expect(final[9] == (x: 15, y: 15))
        #expect(final[30] == (x: 521, y: 15))
    }

    @Test func aShortTranslationIsAllowedToBeShorterThanTheArchive() {
        // A one-line translation asks for a body well under the archive's row,
        // so the extra height goes negative. The bottom corner spans 25.6pt in
        // the final frame; the floor has to leave room for it.
        let shortest = NotchTranslateView.minBodyHeight
        #expect(shortest > 89 - 63.4, "the corner curve would be squashed")
        #expect(shortest < NotchTranslateView.maxBodyHeight)
    }
}
