import CoreGraphics
import Testing
@testable import Stampo

/// Tiles that stuck: a panel pinned to the viewport rides with the page until it
/// reaches its place and stays there, so two frames put it less far apart than
/// the page (`FrameMatcher.isSticking`). Wikipedia's "Contents" and "Appearance"
/// stood 38 px apart in 2026-10-11-193039 whatever the page did.
///
/// A frame is 480 pixels wide, so that a sample of the matcher's grid is ten
/// pixels, and `height` high. Each of the five columns of tiles shows its own
/// stretch of page, scrolled as far as `shift` says.
@Suite struct StickingTilesTests {
    let width = 480

    enum Fill {
        /// Noise, page rows within `rows` only: white elsewhere.
        case noise(shift: Int, rows: Range<Int> = 0..<10_000)
        /// Horizontal stripes 80 rows apart: they fit a distance at every repeat
        /// of the pattern, so no distance is theirs alone.
        case stripes(shift: Int)
        case blank
    }

    private func frame(height: Int, _ columns: [Fill]) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                // The tile column of the sample this pixel stands for.
                let column = min(width / 10 - 1, x / 10) * FrameMatcher.tileColumns / (width / 10)
                let value: UInt8
                switch columns[column] {
                case .noise(let shift, let rows): value = rows.contains(y + shift) ? SeamScenes.page(y + shift, x) : 255
                case .stripes(let shift): value = (y + shift) % 80 < 40 ? 60 : 200
                case .blank: value = 255
                }
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// The panels at the sides, the page between them.
    private func sticky(edges: Int, centre: Int, height: Int = 1200) -> (CaptureFrame, CaptureFrame) {
        let still = Fill.noise(shift: 0)
        let before = frame(height: height, [still, still, still, still, still])
        let after = frame(height: height, [.noise(shift: edges), .noise(shift: centre), .noise(shift: centre),
                                           .noise(shift: centre), .noise(shift: edges)])
        return (before, after)
    }

    @Test func aTileSticksBetweenStandingStillAndTheOffsetLessItsNearRange() {
        // 800: near range 32.
        #expect(FrameMatcher.isSticking(38, offset: 800))
        #expect(FrameMatcher.isSticking(437, offset: 800))
        #expect(FrameMatcher.isSticking(767, offset: 800))
        // Within the near range it is near, not sticking.
        #expect(!FrameMatcher.isSticking(768, offset: 800))
        #expect(!FrameMatcher.isSticking(800, offset: 800))
        // Standing still, or past the offset, is not sticking.
        #expect(!FrameMatcher.isSticking(0, offset: 800))
        #expect(!FrameMatcher.isSticking(900, offset: 800))
        #expect(FrameMatcher.stickingNeedsExact == 2)
    }

    /// 02→03 of 193039: the page 800 on, the panels 38.
    @Test func panelsThatStuckAreNeitherForTheOffsetNorAgainstIt() throws {
        let (before, after) = sticky(edges: 38, centre: 800)
        let evidence = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                             offset: 800, searchLimit: 1047)
        #expect(evidence.sticking == 4, "\(evidence)")
        #expect(evidence.against == 0 && evidence.consistent == 6, "\(evidence)")
        #expect(!evidence.contradicted)

        let match = try FrameMatcher.match(previous: before, current: after, axis: .vertical, maximumOffset: 1047)
        #expect(match.offset == 800)
        #expect(match.sticking > 0, "\(match)")
    }

    /// Without them the same frames: the panels know better, and the step is
    /// refused as it was.
    @Test func withLessThanTwoExactTilesTheyKnowBetter() {
        // One tile of the page has anything in it, and it is exact at 800 and at
        // no other: the panels' four tiles are against it.
        let still = Fill.noise(shift: 0)
        let before = frame(height: 1200, [still, still, still, still, still])
        let after = frame(height: 1200, [.noise(shift: 38), .blank, .noise(shift: 800, rows: 800..<1100), .blank,
                                         .noise(shift: 38)])
        let evidence = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                             offset: 800, searchLimit: 1047)
        #expect(evidence.consistent == 1, "\(evidence)")
        #expect(evidence.sticking == 0 && evidence.against >= 2, "\(evidence)")
        #expect(evidence.contradicted)
    }

    /// 2026-10-11-134734 step 01: 552 asked, from a calibration that was wrong.
    /// Two tiles found 399 and nothing else; the tiles that "agree" with 552 are
    /// stripes that fit every repeat of their pattern.
    @Test func tilesThatAgreeByARepeatDoNotLetTheOthersStick() {
        let before = frame(height: 800, [.stripes(shift: 0), .noise(shift: 0), .noise(shift: 0),
                                         .stripes(shift: 0), .stripes(shift: 0)])
        let after = frame(height: 800, [.stripes(shift: 552), .noise(shift: 399), .noise(shift: 399),
                                        .stripes(shift: 552), .stripes(shift: 552)])
        let evidence = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                             offset: 552, searchLimit: 700)
        #expect(evidence.consistent >= 3, "\(evidence)")
        #expect(evidence.sticking == 0 && evidence.against >= 2, "\(evidence)")
        #expect(evidence.contradicted)
    }

    /// A panel that stopped a little short of the offset is a near tile, as
    /// before; one that stopped well short is sticking.
    @Test func aPanelAFewPixelsShortIsNearAndOneWellShortSticks() {
        let (nearBefore, nearAfter) = sticky(edges: 780, centre: 800)
        let nearEvidence = FrameMatcher.evidence(previous: nearBefore, current: nearAfter, axis: .vertical,
                                                 offset: 800, searchLimit: 1047)
        #expect(nearEvidence.near == 4 && nearEvidence.sticking == 0 && nearEvidence.against == 0, "\(nearEvidence)")

        let (farBefore, farAfter) = sticky(edges: 700, centre: 800)
        let farEvidence = FrameMatcher.evidence(previous: farBefore, current: farAfter, axis: .vertical,
                                                offset: 800, searchLimit: 1047)
        #expect(farEvidence.near == 0 && farEvidence.sticking == 4 && farEvidence.against == 0, "\(farEvidence)")
    }

    /// A panel that stuck beside one that went further than the offset is not
    /// a panel that stopped: the tiles that know better are a different line of
    /// something, and all of them are against, as before (`ParallaxMatchTests`).
    @Test func aPanelThatStuckIsAgainstBesideOneThatWentFurther() {
        let still = Fill.noise(shift: 0)
        let before = frame(height: 1400, [still, still, still, still, still])
        let after = frame(height: 1400, [.noise(shift: 38), .noise(shift: 800), .noise(shift: 800),
                                         .noise(shift: 800), .noise(shift: 900)])
        let evidence = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                             offset: 800, searchLimit: 1047)
        #expect(evidence.sticking == 0, "\(evidence)")
        #expect(evidence.against >= 4, "\(evidence)")
        #expect(evidence.consistent == 6, "\(evidence)")
    }

    /// A panel that went the other way, or further, is against, whatever the rest.
    @Test func aPanelThatWentFurtherThanTheOffsetIsAgainstIt() {
        let (before, after) = sticky(edges: 900, centre: 800, height: 1400)
        let evidence = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                             offset: 800, searchLimit: 1047)
        #expect(evidence.sticking == 0, "\(evidence)")
        #expect(evidence.against > 0, "\(evidence)")
    }
}
