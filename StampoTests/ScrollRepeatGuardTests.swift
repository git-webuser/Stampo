import Testing
@testable import Stampo

@Suite struct ScrollRepeatGuardTests {
    private func frame(seed: Int, noise: Int = 0, flat: Bool = false, contentTiles: Int = 64) -> CaptureFrame {
        let width = 128, height = 128
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let tile = y / 16 * 8 + x / 16
                let value = flat || tile >= contentTiles ? 100 : 30 + (x * 13 + y * 7 + seed * 43) % 170
                // One byte in one eighth of the pixels is a mean of 0.00049.
                let delta = noise == 1 ? (x % 8 == 0 ? 1 : 0) : noise
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8(value + delta) }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    @Test func aReturnToAnEarlierContentFrameIsARepeat() {
        let a = frame(seed: 0), b = frame(seed: 1)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(a)
        guardrail.remember(b)
        #expect(guardrail.isRepeat(a, excluding: b))
    }

    @Test func theImmediatelyPreviousFrameIsExcluded() {
        let a = frame(seed: 0)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(a)
        #expect(!guardrail.isRepeat(a, excluding: a))
        guardrail.remember(a)
        #expect(!guardrail.isRepeat(a, excluding: a))
    }

    @Test func flatFramesAreNeverRepeats() {
        let a = frame(seed: 0, flat: true), b = frame(seed: 1)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(a)
        guardrail.remember(b)
        #expect(!guardrail.isRepeat(a, excluding: b))
    }

    @Test func atLeastFourTilesMustHaveContent() {
        for tiles in [3, 4] {
            let a = frame(seed: 0, contentTiles: tiles), b = frame(seed: 1)
            var guardrail = ScrollRepeatGuard()
            guardrail.remember(a)
            guardrail.remember(b)
            #expect(guardrail.isRepeat(a, excluding: b) == (tiles == 4))
        }
    }

    @Test func subThousandthNoiseRepeatsButAOnePercentChangeDoesNot() {
        let a = frame(seed: 0), b = frame(seed: 1)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(a)
        guardrail.remember(b)
        #expect(guardrail.isRepeat(frame(seed: 0, noise: 1), excluding: b))
        #expect(!guardrail.isRepeat(frame(seed: 0, noise: 3), excluding: b))
    }

    @Test func onlyRememberedFramesCanRepeatAndTheQueryDoesNotRemember() {
        let a = frame(seed: 0), b = frame(seed: 1)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(b)
        #expect(!guardrail.isRepeat(a, excluding: b))
        #expect(!guardrail.isRepeat(a, excluding: nil))
    }
}
