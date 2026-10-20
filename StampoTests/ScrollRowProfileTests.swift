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

    @Test func aFlatProfileCannotProveThatThePageStands() throws {
        #expect(!ScrollRowProfile.Result(best: 0, minimum: 0, zero: 0, expected: 0, maskedRows: 0).stands)
        #expect(!ScrollRowProfile.Result(best: 0, minimum: 0, zero: 0,
                                        expected: ScrollPush.changedFrom, maskedRows: 0).stands)
        let flat = CaptureFrame(width: 120, height: 240, pixels: [UInt8](repeating: 255, count: 120 * 240 * 4))
        let result = try #require(ScrollRowProfile.inspect(history: flat, previous: flat, current: flat, expected: 60))
        #expect(result.maskedRows == 0)
        #expect(!result.stands)
        var pixels = flat.pixels
        for x in 0..<flat.width {
            for channel in 0..<3 { pixels[((flat.height - 1) * flat.width + x) * 4 + channel] = 0 }
        }
        let revealed = CaptureFrame(width: flat.width, height: flat.height, pixels: pixels)
        #expect(ScrollPush.isChanged(1.0 / Double(flat.height)))
        #expect(try #require(ScrollRowProfile.inspect(history: flat, previous: flat, current: revealed,
                                                     expected: 60)).stands == false)
    }

    @Test func flatRowsCannotShareAHeightWhatevertheirCostsLookLike() {
        // Near the minimum, and the step would have shown: the same height.
        #expect(ScrollRowProfile.Result(best: 0, minimum: 0.00686, zero: 0.00686, expected: 0.01105,
                                        maskedRows: 3).sharesHeight)
        // Near the minimum on noise: moving by the step would not have shown.
        for expected in [0.0, ScrollPush.changedFrom, 0.0002, .nan, .infinity] {
            #expect(!ScrollRowProfile.Result(best: 0, minimum: 0.0002, zero: 0.0002, expected: expected,
                                             maskedRows: 0).sharesHeight)
        }
        // The step costs no more than standing still: nothing says it stood.
        #expect(!ScrollRowProfile.Result(best: 0, minimum: 0.005, zero: 0.005, expected: 0.005,
                                         maskedRows: 0).sharesHeight)
        #expect(!ScrollRowProfile.Result(best: 60, minimum: 0.001, zero: 0.01, expected: 0.02,
                                         maskedRows: 0).sharesHeight)
    }
}
