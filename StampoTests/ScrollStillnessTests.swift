import CoreGraphics
import Foundation
import Testing
@testable import Stampo

/// The page is still when no tile of the frame has changed, not when the frame as a whole has hardly changed: a
/// heading that fades in over a second is a small part of the frame (apple.com/iphone-18-pro, 2026-10-14-201714).
@Suite struct ScrollStillnessTests {
    private func frame(width: Int, height: Int, grey: UInt8 = 100) -> CaptureFrame {
        CaptureFrame(width: width, height: height, pixels: [UInt8](repeating: grey, count: width * height * 4))
    }

    /// `frame` with the pixels of the rectangle brightened by `amount` levels.
    private func brightened(_ source: CaptureFrame, x: Range<Int>, y: Range<Int>, by amount: Int) -> CaptureFrame {
        var pixels = source.pixels
        for row in y {
            for column in x {
                let i = (row * source.width + column) * 4
                for channel in 0..<3 { pixels[i + channel] = UInt8(min(255, Int(pixels[i + channel]) + amount)) }
            }
        }
        return CaptureFrame(width: source.width, height: source.height, pixels: pixels)
    }

    /// The mean difference of the whole frame, as `captureStable…` took it before (sampled across it).
    private func wholeFrameDifference(_ a: CaptureFrame, _ b: CaptureFrame) -> Double {
        var total = 0.0, n = 0
        for pixel in stride(from: 0, to: a.width * a.height, by: max(4, (a.width * a.height) / 25_000)) {
            let i = pixel * 4
            total += Double(abs(Int(a.pixels[i]) - Int(b.pixels[i])) + abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1]))
                            + abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))) / 765
            n += 1
        }
        return total / Double(max(1, n))
    }

    @Test func theLimitAndTheIntervalAreTheOnesOfBefore() {
        #expect(ScrollStillness.limit == 1.8)
        #expect(ScrollStillness.interval == .milliseconds(140))
        #expect(ScrollStillness.grid == 8)
        #expect(ScrollStillness.stillBelow == 0.003)
    }

    @Test func framesThatAreTheSameAreStill() {
        let a = frame(width: 640, height: 480)
        #expect(ScrollStillness.isStill(a, a))
        let differences = ScrollStillness.tileDifferences(a, a)
        #expect(differences?.count == 64 && differences?.allSatisfy { $0 == 0 } == true)
    }

    /// One tile that changed by 0.02 is not still, though the frame as a whole changed by far less than the old
    /// threshold of 0.003: the small slow fade of a heading.
    @Test func oneTileThatChangedMakesThePairMoveWhenTheWholeFrameHardlyDid() throws {
        let a = frame(width: 640, height: 640)
        // The tile in the third row and fourth column: 80 by 80 pixels, brightened by 15 of 765 levels per pixel
        // (5 per channel is 0.0196 of 255 over the three channels).
        let b = brightened(a, x: 240..<320, y: 160..<240, by: 5)
        let differences = try #require(ScrollStillness.tileDifferences(a, b))
        #expect(abs(differences[2 * 8 + 3] - 5.0 / 255) < 0.001)
        #expect(differences.enumerated().allSatisfy { $0.offset == 2 * 8 + 3 || $0.element == 0 })
        #expect(wholeFrameDifference(a, b) < 0.003, "the frame as a whole: \(wholeFrameDifference(a, b))")
        #expect(!ScrollStillness.isStill(a, b))
    }

    /// Every tile under the threshold is still: a quarter of the sampled pixels differ by 2 levels per channel, which is
    /// 0.002 in every tile.
    @Test func everyTileUnderTheThresholdIsStill() {
        let a = frame(width: 640, height: 480)
        var pixels = a.pixels
        for y in stride(from: 0, to: 480, by: 4) {
            for x in stride(from: 0, to: 640, by: 4) where (x / 4 + y / 4) % 4 == 0 {
                let i = (y * 640 + x) * 4
                for channel in 0..<3 { pixels[i + channel] = pixels[i + channel] &+ 2 }
            }
        }
        let b = CaptureFrame(width: 640, height: 480, pixels: pixels)
        let differences = ScrollStillness.tileDifferences(a, b) ?? []
        #expect(!differences.isEmpty && differences.allSatisfy { $0 < ScrollStillness.stillBelow && $0 > 0 },
                "\(differences.max() ?? -1)")
        #expect(ScrollStillness.isStill(a, b))
    }

    @Test func aTileExactlyAtTheThresholdIsNotStill() {
        var differences = [Double](repeating: 0, count: 64)
        #expect(ScrollStillness.isStill(tileDifferences: differences))
        differences[10] = 0.0029
        #expect(ScrollStillness.isStill(tileDifferences: differences))
        differences[10] = 0.003
        #expect(!ScrollStillness.isStill(tileDifferences: differences))
    }

    /// A frame that is not a multiple of 8 across or down: its edges are in the last tiles, and a change in the
    /// last pixel is felt.
    @Test func theEdgesOfAFrameThatIsNotAMultipleOfTheGridAreCounted() throws {
        let a = frame(width: 13, height: 9)
        let b = brightened(a, x: 12..<13, y: 8..<9, by: 255)
        let differences = try #require(ScrollStillness.tileDifferences(a, b))
        // The last tile of the last row has the pixel, and no other tile has it.
        #expect(differences[63] > ScrollStillness.stillBelow)
        #expect(differences.dropLast().allSatisfy { $0 == 0 })
        #expect(!ScrollStillness.isStill(a, b))
        // A larger frame: the bottom right corner, in a width and a height that the grid does not divide.
        let c = frame(width: 643, height: 517)
        let d = brightened(c, x: 560..<643, y: 460..<517, by: 30)
        #expect(!ScrollStillness.isStill(c, d))
        let first = brightened(c, x: 0..<60, y: 0..<50, by: 30)
        #expect(!ScrollStillness.isStill(c, first))
    }

    @Test func framesOfDifferentSizesAreNotStill() {
        let a = frame(width: 64, height: 48), b = frame(width: 64, height: 49)
        #expect(ScrollStillness.tileDifferences(a, b) == nil)
        #expect(!ScrollStillness.isStill(a, b))
        #expect(ScrollStillness.tileDifferences(frame(width: 0, height: 0), frame(width: 0, height: 0)) == nil)
    }
}
