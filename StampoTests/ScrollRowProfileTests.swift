import Testing
@testable import Stampo

@Suite struct ScrollRowProfileTests {
    private func frame(_ offset: Int, phase: Int = 0, fixedRows: Range<Int> = 0..<0) -> CaptureFrame {
        let w = 120, h = 240
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let fixed = fixedRows.contains(y)
            let py = y + (fixed ? 0 : offset) + h
            let amplitude = 20 + (py * 73 + py / 7 * 31) % 90
            for x in 0..<w {
                let bright = (x + (fixed ? 0 : phase)) % 6 < 2
                let value = UInt8(bright ? 128 + amplitude : 128 - amplitude)
                for channel in 0..<3 { pixels[(y * w + x) * 4 + channel] = value }
            }
        }
        return CaptureFrame(width: w, height: h, pixels: pixels)
    }

    @Test func aStandingVerticalStructurePrefersZeroOverTheCalibratedStep() throws {
        let result = try #require(ScrollRowProfile.inspect(history: frame(0, phase: 3), previous: frame(0),
                                                          current: frame(0, phase: 3), expected: 60))
        #expect(result.stands)
        #expect(result.best == 0)
        #expect(result.zero == 0)
        #expect(result.expected > 0)
    }

    @Test func aVerticallyShiftedStructureIsNotAStandingStage() throws {
        let result = try #require(ScrollRowProfile.inspect(history: frame(-60), previous: frame(0),
                                                          current: frame(60), expected: 60))
        #expect(!result.stands)
        #expect(result.best == 60)
        #expect(result.expected == 0)
        #expect(result.zero > 0)
    }

    @Test func aPinnedTexturedBandCannotPullTheProfileToZero() throws {
        let result = try #require(ScrollRowProfile.inspect(history: frame(-60, fixedRows: 0..<80),
                                                          previous: frame(0, fixedRows: 0..<80),
                                                          current: frame(60, fixedRows: 0..<80), expected: 60))
        #expect(result.maskedRows >= 80)
        #expect(!result.stands)
        #expect(result.best == 60)
    }

    @Test func tooMuchMaskedOverlapCannotProveAStage() throws {
        let same = frame(0)
        let result = try #require(ScrollRowProfile.inspect(history: same, previous: same, current: same, expected: 60))
        #expect(result.maskedRows == same.height)
        #expect(!result.stands)
        #expect(!result.zero.isFinite)
    }

    @Test func missingGeometryOrAnInvalidExpectedDistanceCannotProveAStage() {
        let same = frame(0)
        for expected in [-1, 0, same.height, same.height + 1] {
            #expect(ScrollRowProfile.inspect(history: same, previous: same, current: same, expected: expected) == nil)
        }
        let narrow = CaptureFrame(width: 2, height: 240, pixels: [UInt8](repeating: 0, count: 2 * 240 * 4))
        #expect(ScrollRowProfile.inspect(history: narrow, previous: narrow, current: narrow, expected: 60) == nil)
        #expect(ScrollRowProfile.inspect(history: narrow, previous: same, current: same, expected: 60) == nil)
    }

    @Test func bothCostRatiosAreRequired() {
        #expect(ScrollRowProfile.Result(best: 0, minimum: 1, zero: 1, expected: 2, maskedRows: 0).stands)
        #expect(!ScrollRowProfile.Result(best: 1, minimum: 0.7, zero: 1, expected: 2, maskedRows: 0).stands)
        #expect(!ScrollRowProfile.Result(best: 0, minimum: 1, zero: 1, expected: 1.5, maskedRows: 0).stands)
    }
}
