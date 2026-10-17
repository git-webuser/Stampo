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

    @Test func oneLevelInEveryCellIsStillARepeatButTwoLevelsAreNot() {
        let a = frame(seed: 0)
        var pixels = a.pixels
        for i in pixels.indices where i % 4 != 3 { pixels[i] += 1 }
        let oneLevel = CaptureFrame(width: a.width, height: a.height, pixels: pixels)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(a)
        #expect(guardrail.isRepeat(oneLevel, excluding: nil))
        #expect(!guardrail.isRepeat(frame(seed: 0, noise: 2), excluding: nil))
    }

    @Test func aMovedTextLineOnAFixedGradientIsNotARepeat() {
        func gradient(lineAt top: Int) -> CaptureFrame {
            let width = 256, height = 256
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let text = (top..<top + 2).contains(y) && (64..<192).contains(x) && x % 8 < 4
                    let value = UInt8(40 + y / 2 + (text ? 60 : 0))
                    for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
                }
            }
            return CaptureFrame(width: width, height: height, pixels: pixels)
        }
        let a = gradient(lineAt: 64)
        var guardrail = ScrollRepeatGuard()
        guardrail.remember(a)
        // The gradient alone supplies content in more than four tiles. The
        // moved text changes only 0.39% of the image (mean RGB delta < 0.001).
        #expect(guardrail.isRepeat(a, excluding: nil))
        #expect(!guardrail.isRepeat(gradient(lineAt: 128), excluding: nil))
    }

    @Test func aCheckedFingerprintIsRememberedOnlyWhenAccepted() {
        let a = frame(seed: 0), b = frame(seed: 1)
        var guardrail = ScrollRepeatGuard()
        let firstCheck = guardrail.checkForRepeat(a, excluding: nil)
        #expect(!firstCheck)
        #expect(!guardrail.isRepeat(a, excluding: nil))
        guardrail.rememberCheckedFrame()
        #expect(guardrail.isRepeat(a, excluding: b))
        let secondCheck = guardrail.checkForRepeat(b, excluding: a)
        #expect(!secondCheck)
        guardrail.rememberCheckedFrame()
        #expect(guardrail.isRepeat(b, excluding: nil))
    }
}
