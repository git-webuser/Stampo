import CoreGraphics
import Testing
@testable import Stampo

@Suite struct ScrollSecondLookTests {
    private func frame(width: Int, height: Int, value: (Int, Int, Int) -> UInt8) -> CaptureFrame {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value(x, y, channel) }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    @Test func aFlatFrameBecomesNeutralInEveryColorChannel() {
        let source = frame(width: 17, height: 13) { _, _, channel in UInt8(30 + channel * 75) }
        let result = ScrollBackgroundFilter.highPass(source, radius: 8)
        #expect(result.width == source.width && result.height == source.height)
        #expect(result.colorSpace == source.colorSpace)
        for i in stride(from: 0, to: result.pixels.count, by: 4) {
            #expect(Array(result.pixels[i..<(i + 3)]) == [128, 128, 128])
            #expect(result.pixels[i + 3] == source.pixels[i + 3])
        }
    }

    @Test func anEdgeSurvivesAndClipsAtTheChannelLimits() {
        let source = frame(width: 21, height: 11) { x, _, _ in x < 10 ? 0 : 255 }
        let result = ScrollBackgroundFilter.highPass(source, radius: 3)
        #expect(result[9, 5, 0] < 30)
        #expect(result[10, 5, 0] > 225)
        #expect(result[2, 5, 0] == 128)
        #expect(result[18, 5, 0] == 128)
        let impulse = frame(width: 5, height: 5) { x, y, _ in x == 2 && y == 2 ? 255 : 0 }
        #expect(ScrollBackgroundFilter.highPass(impulse, radius: 2)[2, 2, 0] == 255)
        let dip = frame(width: 5, height: 5) { x, y, _ in x == 2 && y == 2 ? 0 : 255 }
        #expect(ScrollBackgroundFilter.highPass(dip, radius: 2)[2, 2, 0] == 0)
    }

    @Test func aSmoothGradientVanishesAwayFromTheClippedBorder() {
        let source = frame(width: 37, height: 29) { x, y, _ in UInt8(20 + x * 2 + y * 3) }
        let result = ScrollBackgroundFilter.highPass(source, radius: 8)
        for y in 8..<21 {
            for x in 8..<29 { #expect(result[x, y, 0] == 128) }
        }
        #expect(abs(Int(result[0, 0, 0]) - 128) <= 20)
    }

    @Test func oddSizesAndARadiusLargerThanTheFrameUseTheClippedBoxMean() {
        let source = frame(width: 7, height: 3) { x, y, channel in UInt8(x * 13 + y * 29 + channel * 7) }
        for radius in [0, 2, 99] {
            let result = ScrollBackgroundFilter.highPass(source, radius: radius)
            for y in 0..<source.height {
                for x in 0..<source.width {
                    for c in 0..<3 {
                        var sum = 0, count = 0
                        for yy in max(0, y - radius)..<min(source.height, y + radius + 1) {
                            for xx in max(0, x - radius)..<min(source.width, x + radius + 1) {
                                sum += Int(source[xx, yy, c]); count += 1
                            }
                        }
                        let reference = UInt8(max(0, min(255, (128 + Double(source[x, y, c]) - Double(sum) / Double(count)).rounded())))
                        #expect(result[x, y, c] == reference)
                    }
                }
            }
        }
    }

    private func page(_ offset: Int, stripes: Bool = false) -> CaptureFrame {
        frame(width: 500, height: 800) { x, y, _ in
            let py = y + offset
            let line = py / 28, glyph = (x - 210) / 16
            let seed = (line * 71 + glyph * 43 + line * glyph * 13) % 127
            let text = x >= 210 && py % 28 < 13
                && (x % 16 < 3 || py % 28 == seed % 11) && seed % 5 != 0
            let heading = x > 15 && x < 170 && y > 330 && y < 365 && (x % 12 < 4 || y % 11 < 3)
            let content = stripes ? py % 80 < 10 : text || heading
            // Mark the stripes by contrast so the matcher can identify the
            // true repeat; the calibration gate, not ambiguity, must refuse it.
            let ink = stripes ? 70 - (py / 80 % 3) * 25 : 70
            return UInt8(20 + y / 5 + (content ? ink : 0))
        }
    }

    private func inspect(_ before: CaptureFrame, _ after: CaptureFrame, expected: Int? = 300,
                         axis: ScrollAxis = .vertical, raw: FrameMatcher.StepEvidence? = nil,
                         frameChanged: Bool = true) -> ScrollSecondLook.Result {
        let evidence = raw ?? FrameMatcher.evidence(previous: before, current: after, axis: axis,
                                                    offset: expected, searchLimit: 450)
        return ScrollSecondLook.inspect(previous: before, current: after, axis: axis,
                                        maximumOffset: 450, searchLimit: 450, expected: expected,
                                        radius: 8, raw: evidence, frameChanged: frameChanged)
    }

    @Test func movingTextOnAViewportGradientIsPlacedDespiteAFixedHeading() throws {
        let before = page(0), after = page(300)
        #expect(throws: (any Error).self) {
            try FrameMatcher.match(previous: before, current: after, axis: .vertical, maximumOffset: 450)
        }
        let raw = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                        offset: 300, searchLimit: 450)
        #expect(raw.consistent == 0 && raw.against == 0)
        #expect(ScrollStepDecision.provingStop(standing: raw.standing, pinned: []) > 0)
        let result = inspect(before, after, raw: raw)
        let match = try #require(result.match)
        #expect(abs(match.offset - 300) <= FrameMatcher.nearRange(of: 300))
        #expect(result.note == " · second look: match \(match.offset)")
        // The accepted offset lays the original colors, not the filtered copy.
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: before)
        try assembler.append(after, movement: match.offset)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image.height == before.height + match.offset)
        #expect(image[250, image.height - 20, 0] == after[250, after.height - 20, 0])
    }

    @Test func theSameTextWithoutMotionStillProvesAStop() {
        let source = page(0)
        let result = inspect(source, source)
        #expect(result.match == nil)
        #expect(result.consistent == 0)
        let raw = FrameMatcher.evidence(previous: source, current: source, axis: .vertical,
                                        offset: 300, searchLimit: 450)
        #expect(decide(raw, secondLookConsistent: result.consistent, frameUnchanged: false) == .stationary)
    }

    @Test func aMatchOutsideFourPercentOfTheCalibrationIsRefused() throws {
        let before = page(0), after = page(300)
        let filtered = try FrameMatcher.match(previous: ScrollBackgroundFilter.highPass(before, radius: 8),
                                              current: ScrollBackgroundFilter.highPass(after, radius: 8),
                                              axis: .vertical, maximumOffset: 450)
        #expect(abs(filtered.offset - 230) > FrameMatcher.nearRange(of: 230))
        #expect(inspect(before, after, expected: 230).match == nil)
        #expect(inspect(before, after, expected: 290).match != nil)
    }

    @Test func aStripeMatchOutsideFourPercentOfTheCalibrationIsRefused() throws {
        let before = page(0, stripes: true), after = page(220, stripes: true)
        #expect(before != after)
        let filtered = try FrameMatcher.match(previous: ScrollBackgroundFilter.highPass(before, radius: 8),
                                              current: ScrollBackgroundFilter.highPass(after, radius: 8),
                                              axis: .vertical, maximumOffset: 450)
        #expect(filtered.offset == 220)
        for expected in [210, 140] {
            let raw = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                            offset: expected, searchLimit: 450)
            #expect(raw.consistent == 0 && raw.against == 0)
            #expect(ScrollSecondLook.isNeeded(axis: .vertical, expected: expected, raw: raw, frameChanged: true))
            #expect(abs(filtered.offset - expected) > FrameMatcher.nearRange(of: expected))
            #expect(inspect(before, after, expected: expected, raw: raw).match == nil)
        }
    }

    @Test func anUnchangedFrameDoesNotNeedOrRunASecondLook() {
        let source = page(0)
        let raw = FrameMatcher.StepEvidence(standing: [6], consistent: 0, against: 0, contradicted: false)
        #expect(ScrollSecondLook.isNeeded(axis: .vertical, expected: 300, raw: raw, frameChanged: true))
        #expect(!ScrollSecondLook.isNeeded(axis: .vertical, expected: 300, raw: raw, frameChanged: false))
        let result = inspect(source, source, raw: raw, frameChanged: false)
        #expect(result.match == nil && result.consistent == 0 && result.note.isEmpty)
    }

    @Test func onlyVerticalCalibratedStepsWithSilentRawTilesGetASecondLook() {
        let before = page(0), after = page(300)
        let silent = FrameMatcher.StepEvidence(standing: [], consistent: 0, against: 0, contradicted: false)
        for result in [inspect(before, after, expected: nil, raw: silent),
                       inspect(before, after, axis: .horizontal, raw: silent),
                       inspect(before, after, raw: .init(standing: [], consistent: 1, against: 0, contradicted: false)),
                       inspect(before, after, raw: .init(standing: [], consistent: 0, against: 1, contradicted: true))] {
            #expect(result.match == nil)
            #expect(result.note.isEmpty)
        }
    }

    private func decide(_ evidence: FrameMatcher.StepEvidence, secondLookConsistent: Int = 0,
                        frameUnchanged: Bool = false) -> ScrollStepDecision {
        ScrollStepDecision.decide(.init(undecided: true, canExpect: true,
                                        consistent: evidence.consistent, against: evidence.against,
                                        contradicted: evidence.contradicted, required: 2,
                                        unpinnedStanding: 1, queued: 0, frameUnchanged: frameUnchanged,
                                        secondLookConsistent: secondLookConsistent))
    }

    @Test func oneSupportingTilePreventsAStopAndFilteredOppositionDoesNotCauseARetry() {
        let raw = FrameMatcher.StepEvidence(standing: [6], consistent: 0, against: 0, contradicted: false, near: 2, sticking: 1)
        let filtered = FrameMatcher.StepEvidence(standing: [], consistent: 1, against: 1, contradicted: false)
        #expect(decide(raw) == .stationary)
        let supporting = ScrollSecondLook.addingSupport(from: filtered)
        #expect(supporting == 1)
        #expect(decide(raw, secondLookConsistent: supporting) == .temporary(confirmed: false))
        let opposing = FrameMatcher.StepEvidence(standing: [], consistent: 0, against: 5, contradicted: true)
        #expect(ScrollSecondLook.addingSupport(from: opposing) == 0)
    }

    @Test func contradictoryFilteredEvidenceAddsNothingAndRawOppositionIsPreserved() {
        let raw = FrameMatcher.StepEvidence(standing: [6], consistent: 0, against: 1, contradicted: true)
        let filtered = FrameMatcher.StepEvidence(standing: [], consistent: 5, against: 9, contradicted: true)
        #expect(ScrollSecondLook.addingSupport(from: filtered) == 0)
        let supportive = FrameMatcher.StepEvidence(standing: [], consistent: 1, against: 0, contradicted: false)
        #expect(decide(raw, secondLookConsistent: ScrollSecondLook.addingSupport(from: supportive)) == .retry)
    }
}
