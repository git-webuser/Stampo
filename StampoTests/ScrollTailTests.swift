import Testing
@testable import Stampo

@Suite struct ScrollTailTests {
    @Test func aRecoveredPlacementDoesNotRelayOrUpdateAnyCalibrationState() {
        let placement = ScrollStepPlacement.recovered
        // These are the gates used by layMatchedStep for relay, linearity,
        // late calibration, and ScrollRecalibration (including forgetting).
        #expect(!placement.cleanStep)
        #expect(!placement.updatesCalibration)
        #expect(ScrollStepPlacement.matched(cleanStep: true).cleanStep)
        #expect(ScrollStepPlacement.matched(cleanStep: false).updatesCalibration)
    }

    @Test func recoveryRequiresACleanCalibratedStepThatIsNotAPush() {
        let proof = FrameMatcher.StepEvidence(standing: [], consistent: 8, against: 0, contradicted: false)
        for clean in [false, true] {
            for push in [false, true] {
                for calibration: Double? in [nil, 80] {
                    #expect(ScrollReturn.canRecover(cleanStep: clean, isPush: push, pixelsPerLine: calibration,
                                                    went: 205, evidence: proof, required: 2)
                            == (clean && !push && calibration != nil))
                }
            }
        }
        let contradicted = FrameMatcher.StepEvidence(standing: [], consistent: 8, against: 9, contradicted: true)
        #expect(!ScrollReturn.canRecover(cleanStep: true, isPush: false, pixelsPerLine: 80,
                                        went: 205, evidence: contradicted, required: 2))
        #expect(!ScrollReturn.canRecover(cleanStep: true, isPush: false, pixelsPerLine: 80,
                                        went: 2, evidence: proof, required: 2))
        #expect(!ScrollReturn.canRecover(cleanStep: true, isPush: false, pixelsPerLine: 80,
                                        went: 205, evidence: proof, required: 9))
    }

    @Test func aReverseLandingMustExceedTheCalibratedNoiseRange() {
        #expect(ScrollReturn.landing(difference: 0.1, forward: nil, behind: 355, predicted: 560) == .behind(355))
        #expect(ScrollReturn.landing(difference: 0.1, forward: nil, behind: 22, predicted: 560) == .elsewhere)
        #expect(ScrollReturn.landing(difference: 0.1, forward: nil, behind: 23, predicted: 560) == .behind(23))
        #expect(ScrollReturn.landing(difference: 0.1, forward: nil, behind: 4, predicted: 560) == .elsewhere)
        #expect(ScrollReturn.landing(difference: 0.1, forward: nil, behind: nil, predicted: 560) == .elsewhere)
    }

    @Test func sameAndForwardLandingsKeepTheirPriority() {
        #expect(ScrollReturn.landing(difference: 0, forward: 50, behind: 355, predicted: 560) == .same)
        #expect(ScrollReturn.landing(difference: 0.1, forward: 50, behind: 355, predicted: 560) == .further(50))
    }

    @Test func onlyRawSupportWithoutContradictionConfirmsTheShorterStep() {
        let raw = FrameMatcher.StepEvidence(standing: [], consistent: 2, against: 1, contradicted: false)
        #expect(ScrollReturn.confirms(went: 205, evidence: raw, required: 2))
        #expect(!ScrollReturn.confirms(went: 205, evidence: raw, required: 3))
        let contradicted = FrameMatcher.StepEvidence(standing: [], consistent: 8, against: 9, contradicted: true)
        #expect(!ScrollReturn.confirms(went: 205, evidence: contradicted, required: 1))
        let silent = FrameMatcher.StepEvidence(standing: [], consistent: 0, against: 0, contradicted: false)
        #expect(!ScrollReturn.confirms(went: 205, evidence: silent, required: 1))
    }

    @Test func noShorterStepAtOrBelowNoiseCanBeConfirmed() {
        let raw = FrameMatcher.StepEvidence(standing: [], consistent: 8, against: 0, contradicted: false)
        for went in [-355, 0, 1, 2] { #expect(!ScrollReturn.confirms(went: went, evidence: raw, required: 1)) }
        #expect(ScrollReturn.confirms(went: 3, evidence: raw, required: 1))
    }

    @Test func aReverseMeasurementCanUseFilteredTextWithoutACalibratedDistance() throws {
        func gradientPage(_ offset: Int) -> CaptureFrame {
            let width = 500, height = 800
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let py = y + offset, line = py / 28, glyph = (x - 210) / 16
                    let seed = (line * 71 + glyph * 43 + line * glyph * 13) % 127
                    let text = x >= 210 && py % 28 < 13
                        && (x % 16 < 3 || py % 28 == seed % 11) && seed % 5 != 0
                    let heading = x > 15 && x < 170 && y > 330 && y < 365 && (x % 12 < 4 || y % 11 < 3)
                    let value = UInt8(20 + y / 5 + (text || heading ? 70 : 0))
                    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
                }
            }
            return CaptureFrame(width: width, height: height, pixels: pixels)
        }
        let back = gradientPage(0), kept = gradientPage(300)
        #expect(throws: (any Error).self) {
            try FrameMatcher.match(previous: back, current: kept, axis: .vertical, maximumOffset: 450)
        }
        let measured = try #require(ScrollReturn.displacement(previous: back, current: kept, axis: .vertical,
                                                              maximumOffset: 450, radius: 8))
        #expect(measured == 300)
    }

    private func page(_ offset: Int) -> CaptureFrame {
        let width = 240, height = 600
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let py = y + offset + 600
                let value = UInt8((x * 73 + py * 31 + (x / 7) * (py / 11) * 17) % 220 + 15)
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    @Test func anOvershotTailIsMeasuredConfirmedAndLaidAtItsActualDistance() throws {
        let kept = page(0), step = page(50), back = page(-150)
        let behind = try #require(ScrollReturn.displacement(previous: back, current: kept, axis: .vertical,
                                                            maximumOffset: 400, radius: 8))
        #expect(behind == 150)
        #expect(ScrollReturn.landing(difference: 0.1, forward: nil, behind: behind, predicted: 200) == .behind(150))
        let went = 200 - behind
        let raw = FrameMatcher.evidence(previous: kept, current: step, axis: .vertical, offset: went, searchLimit: 400)
        #expect(ScrollReturn.confirms(went: went, evidence: raw, required: 2))
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: kept)
        try assembler.append(step, movement: went,
                             pinned: ScrollPinned.pinnedBlocks(previous: kept, current: step, shift: went))
        #expect(try assembler.makeImage().height == kept.height + 50)
    }
}
