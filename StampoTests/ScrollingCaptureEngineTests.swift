import CoreGraphics
import Testing
@testable import Stampo

@Suite struct ScrollingCaptureEngineTests {
    private func texture(width: Int, height: Int, xOffset: Int = 0, yOffset: Int = 0,
                        repeatedRows: Int? = nil, stickyHeader: Int = 0,
                        animated: Bool = false) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let logicalY = y + yOffset
                let logicalX = x + xOffset
                let n = repeatedRows.map { logicalY % $0 } ?? logicalY
                var value = UInt8(truncatingIfNeeded: (n &* 73 &+ logicalX &* 37 &+ n &* logicalX &* 11) & 255)
                if y < stickyHeader { value = UInt8(truncatingIfNeeded: x &* 37 & 255) }
                if animated && x < 5 && y < 5 { value = (x + y) % 2 == 0 ? 0 : 255 }
                let i = (y * width + x) * 4
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
                bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    @Test func matchesMeasuredVerticalAndHorizontalMotion() throws {
        let vertical = try FrameMatcher.match(previous: texture(width: 160, height: 180),
                                              current: texture(width: 160, height: 180, yOffset: 23),
                                              axis: .vertical, maximumOffset: 70)
        let horizontal = try FrameMatcher.match(previous: texture(width: 180, height: 140),
                                                current: texture(width: 180, height: 140, xOffset: 19),
                                                axis: .horizontal, maximumOffset: 70)
        #expect(vertical.offset == 23)
        #expect(horizontal.offset == 19)
        #expect(vertical.independentRegions >= 3)
        #expect(horizontal.independentRegions >= 3)
    }

    @Test func appendsOnlyTheNewBottomBandForAnIncompleteFinalStep() throws {
        let first = texture(width: 120, height: 100)
        let last = texture(width: 120, height: 100, yOffset: 17)
        let match = try FrameMatcher.match(previous: first, current: last, axis: .vertical, maximumOffset: 60)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: first)
        try assembler.append(last, movement: match.offset)
        let image = try assembler.makeImage(maxPixels: 100_000)
        #expect(image.width == 120)
        #expect(image.height == 117)
        let output = CaptureFrame(image: image)
        #expect(output?.pixels == texture(width: 120, height: 117).pixels)
    }

    @Test func rejectsRepeatedRowsThatHaveSeveralPlausibleOffsets() {
        let previous = texture(width: 140, height: 160, repeatedRows: 8)
        let current = texture(width: 140, height: 160, yOffset: 18, repeatedRows: 8)
        #expect(throws: FrameMatchError.ambiguousMotion) {
            try FrameMatcher.match(previous: previous, current: current, axis: .vertical, maximumOffset: 60)
        }
    }

    @Test func stationaryHeadersDoNotBecomeRepeatedOutputBands() throws {
        let first = texture(width: 160, height: 180, stickyHeader: 16)
        let next = texture(width: 160, height: 180, yOffset: 22, stickyHeader: 16)
        let match = try FrameMatcher.match(previous: first, current: next, axis: .vertical, maximumOffset: 60)
        #expect(match.offset == 22)
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: first)
        try assembler.append(next, movement: match.offset)
        #expect(assembler.totalLength == 202)
    }

    @Test func aSmallAnimatedPatchDoesNotOutvoteStableRegions() throws {
        let previous = texture(width: 160, height: 180, animated: false)
        let current = texture(width: 160, height: 180, yOffset: 21, animated: true)
        let match = try FrameMatcher.match(previous: previous, current: current, axis: .vertical, maximumOffset: 60)
        #expect(match.offset == 21)
        #expect(match.independentRegions >= 3)
    }

    @Test func noMotionAndOutputLimitsFailClosed() throws {
        let frame = texture(width: 120, height: 100)
        #expect(throws: FrameMatchError.noReliableMotion) {
            try FrameMatcher.match(previous: frame, current: frame, axis: .vertical, maximumOffset: 60)
        }
        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: frame)
        #expect(throws: FrameMatchError.outputLimitExceeded) {
            try assembler.makeImage(maxPixels: 1)
        }
    }

    @Test func horizontalAssemblerAddsOnlyNewRightBand() throws {
        let first = texture(width: 100, height: 90)
        let shifted = texture(width: 100, height: 90, xOffset: 13)
        var assembler = ImageAssembler(axis: .horizontal)
        assembler.begin(with: first)
        try assembler.append(shifted, movement: 13)
        let image = try assembler.makeImage(maxPixels: 100_000)
        #expect(image.width == 113)
        #expect(image.height == 90)
        #expect(CaptureFrame(image: image)?.pixels == texture(width: 113, height: 90).pixels)
    }

    @Test @MainActor func cancellingDiscardsTheCollectedImage() {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 15, y: 15),
                                              bounds: CGRect(x: 0, y: 0, width: 120, height: 90))
        let session = ScrollingCaptureSession(selection: selection, axis: .vertical)
        var didFinish = false
        var didCancel = false
        session.onFinished = { _ in didFinish = true }
        session.onCancelled = { didCancel = true }
        session.cancel()
        #expect(didCancel)
        #expect(!didFinish)
    }
}
