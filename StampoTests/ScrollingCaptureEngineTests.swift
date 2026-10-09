import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
@testable import Stampo

@Suite struct ScrollingCaptureEngineTests {
    private func texture(width: Int, height: Int, xOffset: Int = 0, yOffset: Int = 0,
                        repeatedRows: Int? = nil, stickyHeader: Int = 0, stickyFooter: Int = 0,
                        animated: Bool = false) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let logicalY = y + yOffset
                let logicalX = x + xOffset
                let n = repeatedRows.map { logicalY % $0 } ?? logicalY
                var value = UInt8(truncatingIfNeeded: (n &* 73 &+ logicalX &* 37 &+ n &* logicalX &* 11) & 255)
                if y < stickyHeader || y >= height - stickyFooter {
                    value = UInt8(truncatingIfNeeded: x &* 37 & 255)
                }
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

    private func diagonalTexture(width: Int, height: Int, xOffset: Int, yOffset: Int) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let logicalY = y + yOffset
                let logicalX = x + xOffset
                let rawRow = logicalY * 73 + logicalY * logicalY * 11
                let rawColumn = logicalX * 37 + logicalX * logicalX * 13
                let row = (rawRow % 160 + 160) % 160
                let column = (rawColumn % 50 + 50) % 50
                let value = UInt8(row + column)
                let i = (y * width + x) * 4
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
                bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func noise(_ x: Int, _ y: Int) -> UInt64 {
        var hash = (UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15)
            ^ (UInt64(bitPattern: Int64(y)) &* 0xD1B5_4A32_D192_ED03)
        hash ^= hash >> 30
        hash &*= 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 27
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        return hash
    }

    private func aperiodicTexture(width: Int, height: Int, xOffset: Int, yOffset: Int) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(truncatingIfNeeded: noise(x + xOffset, y + yOffset) >> 56)
                let i = (y * width + x) * 4
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
                bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// Text only in the left part of the width (chat, mail, code) on a blank
    /// or zebra background. `inkCoverage` of 256 fills the column with noise;
    /// lower values leave sparse dark dots, like small text.
    private func columnTexture(width: Int, height: Int, yOffset: Int, columnFraction: Double,
                               inkCoverage: Int = 256, zebraRow: Int? = nil) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let columnWidth = Int(Double(width) * columnFraction)
        for y in 0..<height {
            let logicalY = y + yOffset
            let background: UInt8 = zebraRow.map { (logicalY / $0) % 2 == 0 ? 244 : 255 } ?? 255
            for x in 0..<width {
                var value = background
                if x < columnWidth {
                    let hash = noise(x, logicalY) >> 56
                    if inkCoverage >= 256 { value = UInt8(truncatingIfNeeded: hash) }
                    else if Int(hash) < inkCoverage { value = 40 }
                }
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// A dark page of dim lines of text with a block that changes between
    /// frames — a video — in it. Frames are `height` rows of the page from
    /// `offset`; the block is `videoColumns` wide, `videoRows` of the page
    /// tall, and its content depends on `videoSeed`, so two frames taken at
    /// different moments disagree there whatever the scroll. A header or a
    /// banner is a fixed band over the page, the same in every frame.
    ///
    /// `panels` makes the block a UI-demo scene instead of noise: a dim flat
    /// backdrop with a few bright panels that move with the seed. Flat areas
    /// match each other at many offsets, so it is the harder case for a matcher.
    private func videoPage(width: Int = 320, height: Int, offset: Int, videoSeed: Int,
                           videoColumns: Range<Int> = 16..<304, videoRows: Range<Int> = 0..<0,
                           header: Int = 0, banner: Int = 0, panels: Bool = false) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // The same hash for a panel cell however many pixels ask for it.
        var cells: [Int: UInt64] = [:]
        for y in 0..<height {
            let pageRow = y + offset
            let inVideoRows = videoRows.contains(pageRow)
            let isTextRow = pageRow % 18 < 8
            for x in 0..<width {
                var value: UInt8 = 24
                if inVideoRows, videoColumns.contains(x) {
                    if panels {
                        let cx = x / 40, cy = (pageRow - videoRows.lowerBound) / 40
                        let cell = cells[cx * 1_000 + cy]
                            ?? noise(cx &+ videoSeed &* 7919, cy &+ videoSeed &* 104729)
                        cells[cx * 1_000 + cy] = cell
                        value = cell % 5 == 0 ? UInt8(truncatingIfNeeded: 120 + (cell >> 40) % 120) : 30
                    } else {
                        value = UInt8(truncatingIfNeeded: 40 + noise(x &+ videoSeed &* 7919,
                                                                     pageRow &+ videoSeed &* 104729) % 180)
                    }
                } else if isTextRow, x > 30, x < width - 30 {
                    value = UInt8(truncatingIfNeeded: 70 + noise(x, pageRow) % 150)
                }
                if y < header { value = UInt8(truncatingIfNeeded: 200 + (x / 9) % 40) }
                if y >= height - banner { value = UInt8(truncatingIfNeeded: 160 + (x / 7) % 60) }
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// Full-width horizontal bands of random grey: no vertical detail at all.
    private func bandTexture(width: Int, height: Int, yOffset: Int, band: Int) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let value = UInt8(truncatingIfNeeded: noise(0, (y + yOffset) / band) >> 56)
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func paneTexture(width: Int, height: Int, axis: ScrollAxis, offset: Int) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let moving = x >= 32 && y >= 20 && (axis == .vertical ? y < height - 12 : x < width - 12)
                let sourceX = x + (moving && axis == .horizontal ? offset : 0)
                let sourceY = y + (moving && axis == .vertical ? offset : 0)
                let value = UInt8(truncatingIfNeeded: sourceX * 37 + sourceY * 73 + sourceX * sourceY * 11)
                let i = (y * width + x) * 4
                bytes[i] = value; bytes[i + 1] = value; bytes[i + 2] = value; bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    private func scrollbarTexture(width: Int, height: Int, axis: ScrollAxis, offset: Int,
                                  scrollbarVisible: Bool, thumbOffset: Int) -> CaptureFrame {
        let base = texture(width: width, height: height,
                           xOffset: axis == .horizontal ? offset : 0,
                           yOffset: axis == .vertical ? offset : 0)
        var pixels = base.pixels
        if axis == .vertical {
            for y in 0..<height {
                for x in (width - 10)..<width {
                    let thumb = scrollbarVisible && y >= thumbOffset && y < thumbOffset + 24
                    let value: UInt8 = thumb ? 36 : (scrollbarVisible ? 206 : 255)
                    let i = (y * width + x) * 4
                    pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
                }
            }
        } else {
            for y in (height - 10)..<height {
                for x in 0..<width {
                    let thumb = scrollbarVisible && x >= thumbOffset && x < thumbOffset + 24
                    let value: UInt8 = thumb ? 36 : (scrollbarVisible ? 206 : 255)
                    let i = (y * width + x) * 4
                    pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
                }
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
    }

    private func roundedWindowTexture(width: Int, height: Int, axis: ScrollAxis, offset: Int) -> CaptureFrame {
        let radius = 14
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inLeftTop = x < radius && y < radius
                    && (x - radius) * (x - radius) + (y - radius) * (y - radius) > radius * radius
                let inRightTop = x >= width - radius && y < radius
                    && (x - (width - radius)) * (x - (width - radius)) + (y - radius) * (y - radius) > radius * radius
                let inLeftBottom = x < radius && y >= height - radius
                    && (x - radius) * (x - radius) + (y - (height - radius)) * (y - (height - radius)) > radius * radius
                let inRightBottom = x >= width - radius && y >= height - radius
                    && (x - (width - radius)) * (x - (width - radius)) + (y - (height - radius)) * (y - (height - radius)) > radius * radius
                let transparentCorner = inLeftTop || inRightTop || inLeftBottom || inRightBottom
                let border = x < 10 || x >= width - 10 || y < 10 || y >= height - 10
                let sourceX = x + (axis == .horizontal ? offset : 0)
                let sourceY = y + (axis == .vertical ? offset : 0)
                let value: UInt8 = border ? 0 : UInt8(80 + ((sourceX * 37 + sourceY * 73 + sourceX * sourceY * 11) % 175))
                let i = (y * width + x) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
                pixels[i + 3] = transparentCorner ? 0 : 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: pixels)
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

    @Test func rejectsResidualDiagonalMotionInBothDirectionsAndSigns() {
        let stationary = aperiodicTexture(width: 200, height: 240, xOffset: 0, yOffset: 0)
        for crossShift in [-8, 8] {
            let verticalDiagonal = aperiodicTexture(width: 200, height: 240,
                                                    xOffset: crossShift, yOffset: 23)
            let verticalResidual = FrameMatcher.bestOrthogonalResidual(previous: stationary,
                                                                        current: verticalDiagonal,
                                                                        primaryAxis: .vertical,
                                                                        primaryOffset: 23,
                                                                        limit: 20)
            #expect(verticalResidual.offset == crossShift)
            #expect(verticalResidual.error < 12)
            #expect(throws: FrameMatchError.self) {
                try FrameMatcher.match(previous: stationary,
                                       current: verticalDiagonal,
                                       axis: .vertical, maximumOffset: 70)
            }

            let horizontalDiagonal = aperiodicTexture(width: 200, height: 240,
                                                      xOffset: 23, yOffset: crossShift)
            let horizontalResidual = FrameMatcher.bestOrthogonalResidual(previous: stationary,
                                                                           current: horizontalDiagonal,
                                                                           primaryAxis: .horizontal,
                                                                           primaryOffset: 23,
                                                                           limit: 20)
            #expect(horizontalResidual.offset == crossShift)
            #expect(horizontalResidual.error < 12)
            #expect(throws: FrameMatchError.self) {
                try FrameMatcher.match(previous: stationary,
                                       current: horizontalDiagonal,
                                       axis: .horizontal, maximumOffset: 70)
            }
        }
    }

    @Test func findsMotionOfATextColumnPressedToTheLeft() throws {
        let match = try FrameMatcher.match(
            previous: columnTexture(width: 200, height: 240, yOffset: 0, columnFraction: 0.35),
            current: columnTexture(width: 200, height: 240, yOffset: 41, columnFraction: 0.35),
            axis: .vertical, maximumOffset: 70)
        #expect(match.offset == 41)
    }

    @Test func findsMotionOfAZebraTableWithTextOnlyOnTheLeft() throws {
        let match = try FrameMatcher.match(
            previous: columnTexture(width: 200, height: 240, yOffset: 0, columnFraction: 0.4,
                                    inkCoverage: 24, zebraRow: 12),
            current: columnTexture(width: 200, height: 240, yOffset: 41, columnFraction: 0.4,
                                   inkCoverage: 24, zebraRow: 12),
            axis: .vertical, maximumOffset: 70)
        #expect(match.offset == 41)
    }

    @Test func sparseTextInOneBandOverZebraRowsIsConfidentEnough() throws {
        // The stripes fit offsets a period away, so the whole-frame margin is
        // small; the one band with text still pins the offset down.
        let match = try FrameMatcher.match(
            previous: columnTexture(width: 200, height: 240, yOffset: 0, columnFraction: 0.12,
                                    inkCoverage: 3, zebraRow: 12),
            current: columnTexture(width: 200, height: 240, yOffset: 41, columnFraction: 0.12,
                                   inkCoverage: 3, zebraRow: 12),
            axis: .vertical, maximumOffset: 70)
        #expect(match.offset == 41)
    }

    @Test func fullWidthBandsMatchExactlyAndAreNotSidewaysMotion() throws {
        // Every residual fits bands equally, and the coarse grid can miss the
        // few band edges that tell neighbouring offsets apart.
        let previous = bandTexture(width: 200, height: 240, yOffset: 0, band: 9)
        for offset in 23...27 {
            let current = bandTexture(width: 200, height: 240, yOffset: offset, band: 9)
            let match = try FrameMatcher.match(previous: previous, current: current,
                                               axis: .vertical, maximumOffset: 70)
            #expect(match.offset == offset)
        }
    }

    @Test func rejectsTheReportedDiagonalMotionPattern() {
        #expect(throws: FrameMatchError.self) {
            try FrameMatcher.match(previous: diagonalTexture(width: 200, height: 240,
                                                              xOffset: 0, yOffset: 0),
                                   current: diagonalTexture(width: 200, height: 240,
                                                             xOffset: 8, yOffset: 23),
                                   axis: .vertical, maximumOffset: 70)
        }
    }

    @Test func axResolverAcceptsWebAreaInsideScrollArea() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let chain = [
            ScrollAncestorCandidate(identity: "web", role: "AXWebArea", frame: bounds),
            ScrollAncestorCandidate(identity: "scroll", role: "AXScrollArea", frame: bounds)
        ]
        #expect(ScrollAncestorResolver.matchesSelectedIdentity("web", in: chain, windowBounds: bounds))
    }

    @Test func axResolverAcceptsTableInsideScrollArea() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let chain = [
            ScrollAncestorCandidate(identity: "table", role: "AXTable", frame: bounds),
            ScrollAncestorCandidate(identity: "scroll", role: "AXScrollArea", frame: bounds)
        ]
        #expect(ScrollAncestorResolver.matchesSelectedIdentity("table", in: chain, windowBounds: bounds))
    }

    @Test func axResolverRejectsAChangedInnerContainer() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let chain = [
            ScrollAncestorCandidate(identity: "new-inner-table", role: "AXTable", frame: bounds),
            ScrollAncestorCandidate(identity: "original-web", role: "AXWebArea", frame: bounds),
            ScrollAncestorCandidate(identity: "scroll", role: "AXScrollArea", frame: bounds)
        ]
        #expect(!ScrollAncestorResolver.matchesSelectedIdentity("original-web", in: chain,
                                                                 windowBounds: bounds))
    }

    @Test func axResolverSkipsAnIneligibleSmallInnerContainer() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let chain = [
            ScrollAncestorCandidate(identity: "small-table", role: "AXTable",
                                    frame: CGRect(x: 10, y: 10, width: 60, height: 60)),
            ScrollAncestorCandidate(identity: "web", role: "AXWebArea", frame: bounds),
            ScrollAncestorCandidate(identity: "scroll", role: "AXScrollArea", frame: bounds)
        ]
        #expect(ScrollAncestorResolver.matchesSelectedIdentity("web", in: chain, windowBounds: bounds))
    }

    @Test func axResolverUsesTheMovedWindowsCurrentBounds() {
        let originalBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let currentBounds = CGRect(x: 520, y: 140, width: 400, height: 300)
        let containerFrame = currentBounds.insetBy(dx: 20, dy: 20)
        let chain = [ScrollAncestorCandidate(identity: "web", role: "AXWebArea",
                                             frame: containerFrame)]

        #expect(ScrollAncestorResolver.matchesSelectedIdentity("web", in: chain,
                                                                 windowBounds: currentBounds))
        #expect(!ScrollAncestorResolver.matchesSelectedIdentity("web", in: chain,
                                                                  windowBounds: originalBounds))
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
        // Either refusal will do: an offset of 18 in rows that repeat every 8
        // looks, to the tiles, like standing still plus a few pixels — "fixed
        // or blank", so none is left to vote — rather than like several
        // equally good offsets. What matters is that nothing is stitched.
        #expect(throws: FrameMatchError.self) {
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

    @Test func backingScaleComesFromTheDisplayModePixels() {
        #expect(ScrollingCaptureSession.backingScale(pixelWidth: 2880, pointWidth: 1440) == 2)
        // "More Space" on a 2880-pixel panel renders 1680 points at 3360 pixels.
        #expect(ScrollingCaptureSession.backingScale(pixelWidth: 3360, pointWidth: 1680) == 2)
        #expect(ScrollingCaptureSession.backingScale(pixelWidth: 1920, pointWidth: 1920) == 1)
        #expect(ScrollingCaptureSession.backingScale(pixelWidth: 0, pointWidth: 1440) == nil)
        #expect(ScrollingCaptureSession.backingScale(pixelWidth: 2880, pointWidth: 0) == nil)
    }

    @Test func stitchedImageKeepsTheCaptureColorSpace() throws {
        let p3 = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                                             bytesPerRow: 160, space: p3, bitmapInfo: CaptureFrame.bitmapInfo))
        context.setFillColor(CGColor(colorSpace: p3, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let source = try #require(context.makeImage())
        let frame = try #require(CaptureFrame(image: source))
        #expect(frame.colorSpace.name == CGColorSpace.displayP3)
        #expect([frame[5, 5, 0], frame[5, 5, 1], frame[5, 5, 2]] == [255, 0, 0])

        var assembler = ImageAssembler(axis: .vertical)
        assembler.begin(with: frame)
        let image = try assembler.makeImage()
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(CaptureFrame(image: image)?.pixels == frame.pixels)
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

    @Test func threeSequentialAppendsPreserveEveryPixelOnBothAxes() throws {
        for axis in ScrollAxis.allCases {
            let width = axis == .vertical ? 120 : 90
            let height = axis == .vertical ? 90 : 120
            let increments = [11, 17, 7]
            var assembler = ImageAssembler(axis: axis)
            assembler.begin(with: texture(width: width, height: height))
            var offset = 0
            for movement in increments {
                offset += movement
                let next = texture(width: width, height: height,
                                   xOffset: axis == .horizontal ? offset : 0,
                                   yOffset: axis == .vertical ? offset : 0)
                try assembler.append(next, movement: movement)
            }

            let image = try assembler.makeImage(maxPixels: 100_000)
            let expected = texture(width: axis == .horizontal ? width + offset : width,
                                   height: axis == .vertical ? height + offset : height)
            #expect(CaptureFrame(image: image)?.pixels == expected.pixels)
            #expect(assembler.totalLength == (axis == .vertical ? height : width) + offset)
        }
    }

    @Test func trimmedViewportKeepsRetinaCropGeometryAndStableFrameDimensions() throws {
        let before = texture(width: 180, height: 220, stickyHeader: 14, stickyFooter: 18)
        let after = texture(width: 180, height: 220, yOffset: 21,
                            stickyHeader: 14, stickyFooter: 18)
        let moving = try #require(ScrollingCaptureSession.movingContentRect(before: before,
                                                                              after: after,
                                                                              axis: .vertical))
        #expect(moving.minY >= 14)
        #expect(moving.maxY <= CGFloat(before.height - 18))

        let windowBounds = CGRect(x: 400, y: 250, width: 500, height: 400)
        let originalViewport = ScrollViewport(windowRect: CGRect(x: 430, y: 280, width: 90, height: 110),
                                              relativeScrollPoint: CGPoint(x: 40, y: 50),
                                              windowBounds: windowBounds)
        let cropped = try #require(originalViewport.cropped(to: moving, backingScale: 2))
        #expect(cropped.windowRect.minX == 430 + moving.minX / 2)
        #expect(cropped.windowRect.minY == 280 + moving.minY / 2)
        #expect(cropped.windowRect.width == moving.width / 2)
        #expect(cropped.windowRect.height == moving.height / 2)
        #expect(cropped.relativeScrollPoint == originalViewport.relativeScrollPoint)
        #expect(cropped.cropRectInWindowPoints == CGRect(x: cropped.windowRect.minX - windowBounds.minX,
                                                         y: cropped.windowRect.minY - windowBounds.minY,
                                                         width: cropped.windowRect.width,
                                                         height: cropped.windowRect.height))

        let later1 = try #require(before.cropped(to: moving))
        let later2 = try #require(after.cropped(to: moving))
        #expect(later1.width == later2.width)
        #expect(later1.height == later2.height)
        #expect(later1.width == Int(cropped.windowRect.width * 2))
        #expect(later1.height == Int(cropped.windowRect.height * 2))
    }

    @Test func movingBoundsCropFixedSidebarAndHeaderForBothAxes() throws {
        for axis in ScrollAxis.allCases {
            let before = paneTexture(width: 240, height: 200, axis: axis, offset: 0)
            let after = paneTexture(width: 240, height: 200, axis: axis, offset: 23)
            let moving = try #require(ScrollingCaptureSession.movingContentRect(before: before,
                                                                                  after: after,
                                                                                  axis: axis))
            #expect(moving.minX >= 32)
            #expect(moving.minY >= 20)
            #expect(moving.width >= 160)
            #expect(moving.height >= 140)
        }
    }

    @Test func knownAccessibilityViewportKeepsItsFullCrossAxisWidth() throws {
        for axis in ScrollAxis.allCases {
            let before = paneTexture(width: 240, height: 200, axis: axis, offset: 0)
            let after = paneTexture(width: 240, height: 200, axis: axis, offset: 23)
            let moving = try #require(ScrollingCaptureSession.movingContentRect(before: before,
                                                                                  after: after,
                                                                                  axis: axis,
                                                                                  preserveCrossAxis: true))
            if axis == .vertical {
                #expect(moving.minX == 0)
                #expect(moving.width == 240)
                #expect(moving.minY >= 20)
            } else {
                #expect(moving.minY == 0)
                #expect(moving.height == 200)
                #expect(moving.minX >= 32)
            }
        }
    }

    @Test func scrollbarReserveUsesStableOptionalViewportEdges() throws {
        for axis in ScrollAxis.allCases {
            let width = 240, height = 200
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let viewport = ScrollViewport(windowRect: bounds, relativeScrollPoint: .zero, windowBounds: bounds)
            let enabled = try #require(viewport.excludingScrollbar(axis: axis, insetPoints: 10))
            let disabled = try #require(viewport.excludingScrollbar(axis: axis, insetPoints: 0))
            if axis == .vertical {
                #expect(enabled.windowRect.width == CGFloat(width - 10))
                #expect(enabled.windowRect.height == CGFloat(height))
            } else {
                #expect(enabled.windowRect.width == CGFloat(width))
                #expect(enabled.windowRect.height == CGFloat(height - 10))
            }
            #expect(disabled.windowRect == viewport.windowRect)

            let frames = [
                scrollbarTexture(width: width, height: height, axis: axis, offset: 0,
                                 scrollbarVisible: false, thumbOffset: 0),
                scrollbarTexture(width: width, height: height, axis: axis, offset: 15,
                                 scrollbarVisible: true, thumbOffset: 18),
                scrollbarTexture(width: width, height: height, axis: axis, offset: 29,
                                 scrollbarVisible: true, thumbOffset: 52)
            ]
            let excluded = try frames.map { frame -> CaptureFrame in
                try #require(frame.cropped(to: enabled.cropRectInWindowPoints))
            }
            let included = try frames.map { frame -> CaptureFrame in
                try #require(frame.cropped(to: disabled.cropRectInWindowPoints))
            }
            #expect(Set(excluded.map { "\($0.width)x\($0.height)" }).count == 1)
            #expect(included[1].width == width && included[1].height == height)
            let match = try FrameMatcher.match(previous: excluded[1], current: excluded[2],
                                               axis: axis, maximumOffset: 70)
            #expect(match.offset == 14)

            let edgeIndex = axis == .vertical
                ? (28 * width + (width - 1)) * 4
                : (((height - 1) * width + 28) * 4)
            #expect(included[1].pixels[edgeIndex] != included[2].pixels[edgeIndex])
        }
    }

    @Test func accessibilityScrollbarGeometryReservesOnlyTheViewportEdge() {
        let viewport = CGRect(x: 10, y: 20, width: 240, height: 180)
        let verticalInside = CGRect(x: 240, y: 24, width: 10, height: 172)
        #expect(ScrollbarEdgeResolver.inset(for: verticalInside, viewport: viewport, axis: .vertical) == 12)
        let verticalOutside = CGRect(x: 250, y: 24, width: 10, height: 172)
        #expect(ScrollbarEdgeResolver.inset(for: verticalOutside, viewport: viewport, axis: .vertical) == 0)
        let horizontalInside = CGRect(x: 14, y: 192, width: 232, height: 8)
        #expect(ScrollbarEdgeResolver.inset(for: horizontalInside, viewport: viewport, axis: .horizontal) == 10)
        let unrelated = CGRect(x: 90, y: 70, width: 10, height: 80)
        #expect(ScrollbarEdgeResolver.inset(for: unrelated, viewport: viewport, axis: .vertical) == nil)
    }

    @Test func roundedTransparentWindowCornersAndBorderNeverEnterStitchedStrips() throws {
        let scale: CGFloat = 2
        let points = CGRect(x: 0, y: 0, width: 120, height: 90)
        let viewport = ScrollViewport(windowRect: points, relativeScrollPoint: .zero, windowBounds: points)
        let inset = try #require(viewport.insetWindowEdges(points: 6))
        #expect(inset.cropRectInWindowPoints == CGRect(x: 6, y: 6, width: 108, height: 78))
        for axis in ScrollAxis.allCases {
            let source = roundedWindowTexture(width: 240, height: 180, axis: axis, offset: 0)
            let nextSource = roundedWindowTexture(width: 240, height: 180, axis: axis, offset: 14)
            let provider = try #require(CGDataProvider(data: Data(source.pixels) as CFData))
            let cgImage = try #require(CGImage(width: source.width, height: source.height,
                                               bitsPerComponent: 8, bitsPerPixel: 32,
                                               bytesPerRow: source.width * 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                   | CGBitmapInfo.byteOrder32Big.rawValue),
                                               provider: provider, decode: nil, shouldInterpolate: false,
                                               intent: .defaultIntent))
            let imported = try #require(CaptureFrame(image: cgImage))
            #expect(imported[0, 0, 3] == 0)
            #expect(imported[20, 20, 3] == 255)
            func crop(_ frame: CaptureFrame) throws -> CaptureFrame {
                try #require(frame.cropped(to: CGRect(x: inset.cropRectInWindowPoints.minX * scale,
                                                      y: inset.cropRectInWindowPoints.minY * scale,
                                                      width: inset.cropRectInWindowPoints.width * scale,
                                                      height: inset.cropRectInWindowPoints.height * scale)))
            }
            let first = try crop(imported)
            let next = try crop(nextSource)
            #expect(stride(from: 3, to: first.pixels.count, by: 4).allSatisfy { first.pixels[$0] == 255 })
            var assembler = ImageAssembler(axis: axis)
            assembler.begin(with: first)
            let match = try FrameMatcher.match(previous: first, current: next, axis: axis, maximumOffset: 60)
            #expect(match.offset == 14)
            try assembler.append(next, movement: match.offset)
            let stitched = try #require(CaptureFrame(image: assembler.makeImage(maxPixels: 100_000)))
            #expect(stride(from: 3, to: stitched.pixels.count, by: 4).allSatisfy { stitched.pixels[$0] == 255 })
            #expect(stitched[0, 0, 0] > 0)
        }
    }

    @Test func matcherRetainsTheLastShortPartialScrollStep() throws {
        for axis in ScrollAxis.allCases {
            let before = aperiodicTexture(width: 160, height: 200, xOffset: 0, yOffset: 0)
            let after = aperiodicTexture(width: 160, height: 200,
                                         xOffset: axis == .horizontal ? 7 : 0,
                                         yOffset: axis == .vertical ? 7 : 0)
            let last = try FrameMatcher.match(previous: before, current: after, axis: axis,
                                              maximumOffset: 70)
            #expect(last.offset == 7)
            var assembler = ImageAssembler(axis: axis)
            assembler.begin(with: before)
            try assembler.append(after, movement: last.offset)
            #expect(assembler.totalLength == (axis == .vertical ? before.height : before.width) + 7)
            #expect(throws: FrameMatchError.noReliableMotion) {
                try FrameMatcher.match(previous: after, current: after, axis: axis, maximumOffset: 70)
            }
        }
    }

    @Test func stationaryWindowDoesNotProduceAMovingViewport() {
        let frame = texture(width: 240, height: 200)
        for axis in ScrollAxis.allCases {
            #expect(ScrollingCaptureSession.movingContentRect(before: frame, after: frame, axis: axis) == nil)
        }
    }

    @Test func wholeWindowFallbackPreservesTheOriginalClickPoint() {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 463, y: 371),
                                              bounds: CGRect(x: 400, y: 250, width: 500, height: 400))
        let viewport = ScrollDriver.windowFallbackViewport(for: selection)
        #expect(viewport.windowRect == selection.bounds)
        #expect(viewport.relativeScrollPoint == CGPoint(x: 63, y: 121))
        #expect(viewport.cropRectInWindowPoints == CGRect(origin: .zero, size: selection.bounds.size))
    }

    @Test func scrollingCaptureFailureDoesNotRouteToPermissionSettings() {
        let kind = UserFacingError.Kind.scrollingCaptureFailed(reason: "probe had no reliable movement")
        #expect(!kind.isPermissionKind)
        if case nil = kind.remediation { } else { Issue.record("Scrolling capture should not suggest a permission fix") }
        #expect(kind.title == LocaleManager.shared.string("Scrolling capture failed"))
        #expect(kind.message == "probe had no reliable movement")
        #expect(!kind.message.localizedCaseInsensitiveContains("screen recording"))
        #expect(!kind.message.localizedCaseInsensitiveContains("scrollable area"))
        let generic = UserFacingError.Kind.scrollingCaptureFailed(reason: nil)
        #expect(generic.message == LocaleManager.shared.string("Stampo couldn't complete scrolling capture. Try again."))
        #expect(!generic.message.localizedCaseInsensitiveContains("screen recording"))
        #expect(!generic.message.localizedCaseInsensitiveContains("scrollable area"))

        let screenRecording = UserFacingError.Kind.screenCaptureFailed(reason: nil)
        if case .openScreenRecordingSettings? = screenRecording.remediation { }
        else { Issue.record("Screen capture permission failure should link to Screen Recording settings") }
        let accessibility = UserFacingError.Kind.accessibilityPermission
        if case .openAccessibilitySettings? = accessibility.remediation { }
        else { Issue.record("Accessibility permission failure should link to Accessibility settings") }
    }

    @Test @MainActor func scrollingEncodingFailureUsesSpecificNeutralMessage() {
        let kind = ScreenshotService.scrollingSaveErrorKind(ScreenshotFileStore.SaveError.encodingFailed)
        #expect(kind.message == LocaleManager.shared.string("Stampo couldn't encode the scrolling image."))
        #expect(!kind.message.localizedCaseInsensitiveContains("screen recording"))
        #expect(!kind.message.localizedCaseInsensitiveContains("scrollable area"))
        if case nil = kind.remediation { } else { Issue.record("Encoding failure should not suggest a permission fix") }

        let deniedWrite = NSError(domain: NSCocoaErrorDomain,
                                  code: CocoaError.Code.fileWriteNoPermission.rawValue)
        let directoryKind = ScreenshotService.scrollingSaveErrorKind(deniedWrite)
        if case .saveDirectoryInaccessible = directoryKind { }
        else { Issue.record("A destination write permission failure should identify the save folder") }
        if case .openAppSettings? = directoryKind.remediation { }
        else { Issue.record("Save folder failure should route to Stampo Capture settings") }
    }

    @Test func cancellingDuringInitialCapturePreventsTheFirstScrollEvent() async throws {
        let latch = AsyncLatch()
        let counter = EventCounter()
        let delayedCapture = Task {
            try await ScrollCaptureCancellationBoundary.awaitActive {
                await latch.park()
                return CaptureFrame(width: 100, height: 90,
                                    pixels: [UInt8](repeating: 0, count: 100 * 90 * 4))
            }
            await counter.recordEvent()
        }
        await latch.waitUntilStarted()
        delayedCapture.cancel()
        await latch.release()
        do { try await delayedCapture.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(await counter.value == 0)
    }

    @Test func cancellingDuringMatcherPreventsAppendingOrPublishing() async throws {
        let latch = AsyncLatch()
        let counter = EventCounter()
        let delayedMatcher = Task {
            let _: FrameMatch = try await ScrollCaptureCancellationBoundary.awaitActive {
                await latch.park()
                return FrameMatch(offset: 12, confidence: 1, independentRegions: 5)
            }
            await counter.recordEvent()
            await counter.recordEvent()
        }
        await latch.waitUntilStarted()
        delayedMatcher.cancel()
        await latch.release()
        do { try await delayedMatcher.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(await counter.value == 0)
    }

    /// A key missing from the catalog does not fail: it falls back to its own
    /// English text, which in a Russian UI is a sentence in the wrong language.
    @Test func everyScrollingStringHasARussianTranslation() {
        let ru = Locale(identifier: "ru")
        let keys = [
            "Click the area to scroll",
            "Save",
            HotkeyAction.scroll.labelKey, HotkeyAction.scroll.hintKey ?? "",
            "Scrolling", "Down", "Right",
            "Excludes a narrow viewport edge where scrollbars appear; content near that edge may also be cropped.",
            "Screenshot capture stopped",
            "Pause capture", "Resume capture",
            "Length limit", "Shrink to fit",
            "At the limit the image drops to standard resolution (1x) and the capture continues — twice as much of the page fits.",
            "MB", "Scrolling Screenshot",
            "Scrolling capture failed",
            "Scrolling capture needs Accessibility access",
            "Grant Accessibility access to Stampo to scroll windows.",
            "Stampo couldn't complete scrolling capture. Try again.",
            "Stampo couldn't encode the scrolling image.",
            "The scrolling image reached the configured size limit.",
            "Grant Screen Recording access to Stampo, then try again.",
            "The selected window is no longer available.",
        ]
        for key in keys {
            let translated = LocaleManager.string(key, locale: ru)
            #expect(translated != key, "no Russian for \(key)")
        }
    }

#if DEBUG
    /// The dump of a capture's frames: a folder named by the time, a PNG for
    /// every frame, the lines of steps.txt in the order they came — and nothing
    /// at all unless the flag is on.
    @Test @MainActor func aFrameDumpWritesFramesAndStepsInOrder() throws {
        #expect(AppSettings.store.bool(forKey: ScrollFrameDump.defaultsKey) == false)
        #expect(ScrollFrameDump.begin() == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let moment = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8,
                                                                     hour: 14, minute: 30, second: 5)))
        #expect(ScrollFrameDump.directoryName(for: moment, calendar: calendar) == "2026-10-08-143005")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollFrameDumpTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let dump = ScrollFrameDump(directory: folder)
        let frame = texture(width: 64, height: 48)
        dump.save(frame, as: "00-before")
        dump.step("01 lines=3 · match 120 px → added")
        dump.save(frame, as: "01-step")
        dump.step("02 lines=3 · ambiguousMotion → retry 1 of 2")
        dump.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["00-before.png", "01-step.png", "steps.txt"])
        let steps = try String(contentsOf: folder.appendingPathComponent("steps.txt"), encoding: .utf8)
        #expect(steps == "01 lines=3 · match 120 px → added\n02 lines=3 · ambiguousMotion → retry 1 of 2\n")
        // The PNG is the frame.
        let source = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent("00-before.png") as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CaptureFrame(image: image)?.pixels == frame.pixels)
    }
#endif

    @Test func theAskedDirectionIsProbedFirstAndTheOtherSecond() {
        #expect(ScrollingCaptureSession.probeOrder(preferred: .vertical) == [.vertical, .horizontal])
        #expect(ScrollingCaptureSession.probeOrder(preferred: .horizontal) == [.horizontal, .vertical])
    }

    @Test func oneWholeWindowFrameServesWhicheverAxisTheProbeSettlesOn() throws {
        // A window that scrolls only sideways: a probe the wrong way changes
        // nothing, so the frame after it is the frame before it.
        let start = paneTexture(width: 240, height: 200, axis: .horizontal, offset: 0)
        let sideways = paneTexture(width: 240, height: 200, axis: .horizontal, offset: 23)
        let whole = CGRect(x: 0, y: 0, width: 240, height: 200)

        #expect(ScrollingCaptureSession.probeOutcome(before: start, after: start, viewportPixels: whole,
                                                     axis: .vertical, preserveCrossAxis: false) == nil)

        // The probe along the right axis finds the same start frame's moving part.
        let outcome = try #require(ScrollingCaptureSession.probeOutcome(
            before: start, after: sideways, viewportPixels: whole, axis: .horizontal,
            preserveCrossAxis: false))
        #expect(outcome.movingRect.minX >= 32)
        #expect(outcome.movingRect.minY >= 20)
        #expect(outcome.first.width == outcome.probe.width && outcome.first.height == outcome.probe.height)
        // The first frame is the start, cut: the pixels are the start's own.
        let rect = outcome.movingRect
        #expect(outcome.first.pixels == start.cropped(to: rect)?.pixels)

        // The bar to leave out belongs to the final axis: the same frames,
        // cropped for it, give a frame inside that viewport.
        let belowTheBar = CGRect(x: 0, y: 0, width: 240, height: 180)
        let cropped = try #require(ScrollingCaptureSession.probeOutcome(
            before: start, after: sideways, viewportPixels: belowTheBar, axis: .horizontal,
            preserveCrossAxis: false))
        #expect(cropped.first.height <= 180)
    }

    @Test func oneScrollingModeCoversBothDirections() {
        #expect(CaptureMode.allCases == [.selection, .window, .scroll, .screen])
        #expect(CaptureMode(rawValue: CaptureMode.scroll.rawValue) == .scroll)
        // The two modes this replaced were never released; their stored values
        // fall back to the default rather than being carried.
        #expect(CaptureMode(rawValue: "scrollVertical") == nil)
        #expect(CaptureMode(rawValue: "scrollHorizontal") == nil)
        #expect(ScrollDirection.down.axis == .vertical)
        #expect(ScrollDirection.right.axis == .horizontal)
        // Two directions: next and previous are the same step.
        for direction in ScrollDirection.allCases {
            #expect(direction.other != direction)
            #expect(direction.other.other == direction)
        }
        #expect(ScrollDirection.down.icon == "arrow.up.and.down.text.horizontal")
        #expect(ScrollDirection.right.icon == "arrow.left.and.right.text.vertical")
    }

    @Test func voiceOverHearsTheDirectionOnlyForScrolling() {
        let ru = Locale(identifier: "ru"), en = Locale(identifier: "en")
        #expect(CaptureMode.scroll.accessibilityValue(direction: .down, locale: ru) == "Прокрутка, вниз")
        #expect(CaptureMode.scroll.accessibilityValue(direction: .right, locale: ru) == "Прокрутка, вправо")
        #expect(CaptureMode.scroll.accessibilityValue(direction: .down, locale: en) == "Scrolling, down")
        #expect(CaptureMode.scroll.accessibilityValue(direction: .right, locale: en) == "Scrolling, right")
        // The direction is not part of any other mode.
        #expect(CaptureMode.window.accessibilityValue(direction: .right, locale: en) == "Window")
    }

    @Test func oneHotkeyCoversScrollingAndTheOldIDStaysRetired() {
        #expect(HotkeyAction.scroll.rawValue == 12)
        #expect(HotkeyAction(rawValue: 13) == nil)
        #expect(HotkeyAction.scroll.group == .capture)
        #expect(HotkeyAction.scroll.hintKey == "Press ⇥ to switch direction")
        #expect(HotkeyAction.allCases.filter { $0.defaultCombo == HotkeyAction.scroll.defaultCombo }.count == 1)
    }

    @Test func wheelLinesFollowTheStepInPointsNotInCapturedPixels() {
        // 540 points is six lines at either scale; the capture is twice the pixels at 2x.
        #expect(ScrollDriver.lineDelta(for: 540, backingScale: 1) == 6)
        #expect(ScrollDriver.lineDelta(for: 1080, backingScale: 2) == 6)
        // Rounded up, never zero, capped at ten.
        #expect(ScrollDriver.lineDelta(for: 101, backingScale: 1) == 2)
        #expect(ScrollDriver.lineDelta(for: 24, backingScale: 2) == 1)
        #expect(ScrollDriver.lineDelta(for: 5000, backingScale: 1) == 10)
        // The search bound is in pixels again: lines × 90 points × scale.
        #expect(ScrollDriver.maximumLikelyMovement(pixelStep: 1080, backingScale: 2, viewportLength: 3000) == 6 * 90 * 2)
        #expect(ScrollDriver.maximumLikelyMovement(pixelStep: 540, backingScale: 1, viewportLength: 3000) == 6 * 90)
    }

    // MARK: Length limit and shrink to fit

    /// Smooth content, so that halving it band by band can be compared with
    /// halving it whole.
    private func smoothFrame(width: Int, height: Int, yOffset: Int) -> CaptureFrame {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = 128 + 100 * sin(Double(x) / 21) * cos(Double(y + yOffset) / 29)
                let i = (y * width + x) * 4
                bytes[i] = UInt8(v); bytes[i + 1] = UInt8(255 - v / 2); bytes[i + 2] = UInt8(v / 2 + 40); bytes[i + 3] = 255
            }
        }
        return CaptureFrame(width: width, height: height, pixels: bytes)
    }

    /// A tall page assembled from frames of `height` rows, each `movements[k]`
    /// further down than the one before.
    private func assemble(movements: [Int], width: Int = 240, height: Int = 200,
                          shrinkAfter: Int? = nil, content: (Int, Int, Int) -> CaptureFrame)
        throws -> ImageAssembler {
        var assembler = ImageAssembler(axis: .vertical, maxLength: 100_000)
        assembler.begin(with: content(width, height, 0))
        var offset = 0
        for (index, movement) in movements.enumerated() {
            if index == shrinkAfter { assembler.shrinkToHalf() }
            offset += movement
            try assembler.append(content(width, height, offset), movement: movement)
        }
        return assembler
    }

    @Test func shrinkingHalvesTheImageAndKeepsItWhole() throws {
        let movements = [37, 11, 29, 17, 23, 13, 31, 19]
        let whole = try assemble(movements: movements) { smoothFrame(width: $0, height: $1, yOffset: $2) }
        let shrunkMidway = try assemble(movements: movements, shrinkAfter: 4) {
            smoothFrame(width: $0, height: $1, yOffset: $2)
        }
        let full = 200 + movements.reduce(0, +)
        #expect(whole.totalLength == full)
        #expect(!whole.isShrunk)
        #expect(shrunkMidway.isShrunk)
        // Half the length, half the width — rounded down along, up across.
        #expect(shrunkMidway.totalLength == full / 2)
        let image = try shrunkMidway.makeImage()
        #expect(image.width == 120)
        #expect(image.height == full / 2)
    }

    /// Fifty bands of unequal, mostly odd heights. Rounding each band's own
    /// length to half would leave a pixel here and gain one there and the error
    /// would add up; laying each at half of where it began cannot.
    @Test func shrinkingFiftyBandsLeavesNoGapAndNoDrift() throws {
        let movements = (0..<50).map { 11 + ($0 * 7) % 27 }
        let assembler = try assemble(movements: movements, shrinkAfter: 12) {
            smoothFrame(width: 240, height: $1, yOffset: $2)
        }
        let full = 200 + movements.reduce(0, +)
        #expect(assembler.fullLength == full)
        #expect(assembler.totalLength == full / 2)
        var expectedStart = 0
        for strip in assembler.strips {
            #expect(strip.start == expectedStart, "a gap or an overlap before the band at \(strip.start)")
            expectedStart += strip.frame.height
        }
        #expect(expectedStart == assembler.totalLength)
        #expect(try assembler.makeImage().height == full / 2)
    }

    @Test func theShrunkImageIsTheOriginalAtHalfSize() throws {
        let movements = [37, 11, 29, 17, 23, 13, 31, 19, 27, 21]
        let whole = try assemble(movements: movements) { smoothFrame(width: $0, height: $1, yOffset: $2) }
        let shrunk = try assemble(movements: movements, shrinkAfter: 5) {
            smoothFrame(width: $0, height: $1, yOffset: $2)
        }
        let original = try whole.makeImage()
        let halved = try shrunk.makeImage()

        // The original, halved in one go, to compare the band-by-band one with.
        let space = try #require(original.colorSpace)
        let context = try #require(CGContext(data: nil, width: halved.width, height: halved.height,
                                             bitsPerComponent: 8, bytesPerRow: halved.width * 4,
                                             space: space, bitmapInfo: CaptureFrame.bitmapInfo))
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: halved.width, height: halved.height))
        let referenceImage = try #require(context.makeImage())
        let reference = try #require(CaptureFrame(image: referenceImage))
        let result = try #require(CaptureFrame(image: halved))
        #expect(reference.width == result.width && reference.height == result.height)

        var difference = 0, samples = 0
        for y in 0..<result.height {
            for x in 0..<result.width {
                for c in 0..<3 {
                    difference += abs(Int(result[x, y, c]) - Int(reference[x, y, c])); samples += 1
                }
            }
        }
        // Not the same pixels — a band is filtered on its own — but the same picture.
        #expect(Double(difference) / Double(samples) < 2.0)
    }

    /// A frame of the page with a rectangle laid over it, standing in for an
    /// element that is part-way through appearing.
    private func withElement(_ frame: CaptureFrame, rows: Range<Int>, columns: Range<Int>, value: UInt8) -> CaptureFrame {
        var pixels = frame.pixels
        for y in rows { for x in columns {
            let i = (y * frame.width + x) * 4
            pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
        } }
        return CaptureFrame(width: frame.width, height: frame.height, pixels: pixels)
    }

    /// The seam lies in the middle of the overlap: the earlier frame keeps the
    /// first half, the later one gives the second. An element that is half-way
    /// up in the first frame and finished in the second ends up finished when
    /// it lies in the second half of the overlap. (Keeping the first frame's
    /// overlap cut a heading off at the top on a page whose headings slide in
    /// as it scrolls.)
    @Test func theLaterFrameWinsInTheSecondHalfOfTheOverlap() throws {
        let height = 200, movement = 60, columns = 40..<120
        // The overlap is page rows 60 to 200; the seam falls at row 130.
        let upper = 100..<130, lower = 150..<180
        func dim(_ frame: CaptureFrame) -> CaptureFrame {
            withElement(withElement(frame, rows: upper, columns: columns, value: 90),
                        rows: lower, columns: columns, value: 90)
        }
        func finished(_ frame: CaptureFrame) -> CaptureFrame {
            let moved = { (rows: Range<Int>) in (rows.lowerBound - movement)..<(rows.upperBound - movement) }
            return withElement(withElement(frame, rows: moved(upper), columns: columns, value: 255),
                               rows: moved(lower), columns: columns, value: 255)
        }
        let first = dim(texture(width: 240, height: height))
        let second = finished(texture(width: 240, height: height, yOffset: movement))
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: first)
        try assembler.append(second, movement: movement)
        #expect(assembler.totalLength == height + movement)
        // Contiguous: the first cut back to the seam, the second from there.
        #expect(assembler.strips.count == 2)
        #expect(assembler.strips[0].frame.height == 130)
        #expect(assembler.strips[1].start == 130 && assembler.strips[1].frame.height == height - 70)

        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image[60, 165, 0] == 255, "below the seam the element is as the later frame has it")
        #expect(image[60, 115, 0] == 90, "above the seam it is as the earlier frame has it")
        // Beyond the elements the page is the page, wherever it came from.
        let expected = texture(width: 240, height: height + movement)
        for (x, y) in [(10, 5), (200, 59), (200, 61), (10, 129), (10, 131), (10, 180), (230, 259)] {
            #expect(image[x, y, 0] == expected[x, y, 0], "at \(x),\(y)")
        }
    }

    /// A bar fixed to the top of the viewport is in every frame; the seams fall
    /// below it, so it is in the image once, at the top.
    @Test func aBarFixedAtTheTopOfEveryFrameIsInTheImageOnceAtTheTop() throws {
        let width = 240, height = 200, bar = 40, movements = [60, 60, 60, 60]
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: texture(width: width, height: height, stickyHeader: bar))
        var offset = 0
        for movement in movements {
            offset += movement
            try assembler.append(texture(width: width, height: height, yOffset: offset, stickyHeader: bar),
                                 movement: movement)
        }
        let total = height + offset
        #expect(assembler.totalLength == total)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        let expected = texture(width: width, height: total, stickyHeader: bar)
        #expect(image.pixels == expected.pixels)
    }

    /// The same at the bottom: only the last frame's bar is left, at the end.
    @Test func aBarFixedAtTheBottomOfEveryFrameIsInTheImageOnceAtTheEnd() throws {
        let width = 240, height = 200, bar = 40, movements = [60, 60, 60, 60]
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: texture(width: width, height: height, stickyFooter: bar))
        var offset = 0
        for movement in movements {
            offset += movement
            try assembler.append(texture(width: width, height: height, yOffset: offset, stickyFooter: bar),
                                 movement: movement)
        }
        let total = height + offset
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        let expected = texture(width: width, height: total, stickyFooter: bar)
        #expect(image.pixels == expected.pixels)
    }

    /// Bars at both edges, and a step so small that the overlap is nearly the
    /// frame: still once each — and the same after the image has been halved.
    @Test func barsAtBothEdgesAreOnceEachBeforeAndAfterTheImageIsHalved() throws {
        let width = 240, height = 200, bar = 30, movements = [40, 25, 40, 40, 25, 40]
        for shrinkAfter in [nil, 2] as [Int?] {
            let assembler = try assemble(movements: movements, width: width, height: height, shrinkAfter: shrinkAfter) {
                texture(width: $0, height: $1, yOffset: $2, stickyHeader: bar, stickyFooter: bar)
            }
            let total = height + movements.reduce(0, +)
            #expect(assembler.fullLength == total)
            let image = try #require(CaptureFrame(image: try assembler.makeImage()))
            if shrinkAfter == nil {
                let expected = texture(width: width, height: total, stickyHeader: bar, stickyFooter: bar)
                #expect(image.pixels == expected.pixels)
            } else {
                // Halved, a row of the bar is one that looks like a row inside
                // the top bar: they are at the top and at the end, and nowhere
                // between.
                func differs(_ y: Int, from reference: Int) -> Double {
                    var sum = 0
                    for x in 0..<image.width { sum += abs(Int(image[x, y, 0]) - Int(image[x, reference, 0])) }
                    return Double(sum) / Double(image.width)
                }
                let barRows = (0..<image.height).filter { differs($0, from: 3) < 4 }
                #expect(barRows.contains(3) && barRows.contains(image.height - 4))
                for y in barRows {
                    #expect(y <= bar / 2 || y >= image.height - bar / 2 - 1, "a bar row in the page at \(y)")
                }
            }
        }
    }

    /// The same once the image has dropped to half size: the seam and the rest
    /// of the frame both land on the halved floor, so the element is there and
    /// nothing is left of the frame that it replaced.
    @Test func theLaterFrameWinsAfterTheImageHasShrunk() throws {
        // The second and third frames share page rows 120 to 260, the seam at
        // 190; the element at 200–230 is in the second half.
        let height = 200, movement = 60, element = 200..<230, columns = 40..<120
        let first = texture(width: 240, height: height)
        let second = texture(width: 240, height: height, yOffset: movement)
        let third = withElement(texture(width: 240, height: height, yOffset: 2 * movement),
                                rows: (element.lowerBound - 2 * movement)..<(element.upperBound - 2 * movement),
                                columns: columns, value: 255)
        var assembler = ImageAssembler(axis: .vertical, maxLength: 10_000)
        assembler.begin(with: first)
        try assembler.append(second, movement: movement)
        assembler.shrinkToHalf()
        // The element is in the overlap of the second and third frames — and, as
        // the second frame has it as texture, only the third frame has it bright.
        try assembler.append(third, movement: movement)
        let full = height + 2 * movement
        #expect(assembler.fullLength == full)
        #expect(assembler.totalLength == full / 2)
        var expectedStart = 0
        for strip in assembler.strips {
            #expect(strip.start == expectedStart)
            expectedStart += strip.frame.height
        }
        #expect(expectedStart == assembler.totalLength)
        let image = try #require(CaptureFrame(image: try assembler.makeImage()))
        #expect(image[40, 107, 0] > 230, "the element, halved, is bright: \(image[40, 107, 0])")
    }

    @Test func shrinkingTwiceOrBeforeThereIsAnythingChangesNothing() throws {
        var empty = ImageAssembler(axis: .vertical)
        empty.shrinkToHalf()
        #expect(!empty.isShrunk)

        var assembler = try assemble(movements: [20, 20]) { smoothFrame(width: $0, height: $1, yOffset: $2) }
        assembler.shrinkToHalf()
        let once = assembler.totalLength
        assembler.shrinkToHalf()
        #expect(assembler.totalLength == once)
        #expect(assembler.lengthAfterAdding(30) == (assembler.fullLength + 30) / 2)
    }

    @Test func atTheLimitTheImageShrinksOnceAndOnlyAboveOneX() {
        func action(_ length: Int, shrink: Bool = true, scale: CGFloat = 2, shrunk: Bool = false) -> ScrollLengthLimit.Action {
            ScrollLengthLimit.action(lengthAfterAdding: length, limit: 20_000, shrinkToFit: shrink,
                                     frameScale: scale, alreadyShrunk: shrunk)
        }
        #expect(action(20_000) == .fits)
        #expect(action(20_001) == .shrink)
        // Off: stop and save, as before.
        #expect(action(20_001, shrink: false) == .stop)
        // At 1x there is nothing to drop to.
        #expect(action(20_001, scale: 1) == .stop)
        // Once is enough: the second time at the limit it saves.
        #expect(action(20_001, shrunk: true) == .stop)
    }

    /// The length chosen is a wish; memory is a ceiling. 120 M pixels is half a
    /// gigabyte, and what a width of that leaves is what a capture can be.
    @Test func theMemoryCeilingCapsTheLengthAtWideWidthsAndTheShrinkLiftsIt() {
        // A 5K display at 2x: 40 000 would be 205 M pixels.
        #expect(ScrollLengthLimit.effectiveLimit(limit: 40_000, crossSize: 5_120) == 23_437)
        // Halved by the shrink, the same width leaves room for all that was asked.
        #expect(ScrollLengthLimit.effectiveLimit(limit: 40_000, crossSize: 2_560) == 40_000)
        // The window the 20 000 default was sized for: untouched.
        #expect(ScrollLengthLimit.effectiveLimit(limit: 40_000, crossSize: 2_516) == 40_000)
        #expect(ScrollLengthLimit.effectiveLimit(limit: 20_000, crossSize: 5_120) == 20_000)
        // Nothing to divide by yet.
        #expect(ScrollLengthLimit.effectiveLimit(limit: 40_000, crossSize: 0) == 40_000)
    }

    @Test func theAssemblerReadsTheCeilingFromItsOwnWidthBeforeAndAfterAShrink() throws {
        var assembler = ImageAssembler(axis: .vertical, maxLength: 40_000)
        #expect(assembler.effectiveLimit == 40_000)
        assembler.begin(with: texture(width: 5_120, height: 100))
        #expect(assembler.outputCrossSize == 5_120)
        #expect(assembler.effectiveLimit == 23_437)
        // At the limit the question is the same as ever: shrink if allowed, else save.
        #expect(ScrollLengthLimit.action(lengthAfterAdding: 23_438, limit: assembler.effectiveLimit,
                                         shrinkToFit: true, frameScale: 2, alreadyShrunk: false) == .shrink)
        #expect(ScrollLengthLimit.action(lengthAfterAdding: 23_438, limit: assembler.effectiveLimit,
                                         shrinkToFit: false, frameScale: 2, alreadyShrunk: false) == .stop)
        assembler.shrinkToHalf()
        #expect(assembler.outputCrossSize == 2_560)
        #expect(assembler.effectiveLimit == 40_000)
    }

    @MainActor @Test func theLimitAndTheShrinkSettingStartAtFortyThousandAndOff() {
        let store = AppSettings.store
        store.removeObject(forKey: AppSettings.Keys.scrollLengthLimit)
        store.removeObject(forKey: AppSettings.Keys.scrollShrinkToFit)
        #expect(AppSettings.scrollLengthLimit == 40_000)
        #expect(!AppSettings.scrollShrinkToFit)
        defer {
            store.removeObject(forKey: AppSettings.Keys.scrollLengthLimit)
            store.removeObject(forKey: AppSettings.Keys.scrollShrinkToFit)
        }
        AppSettings.scrollLengthLimit = 10_000
        AppSettings.scrollShrinkToFit = true
        #expect(AppSettings.scrollLengthLimit == 10_000)
        #expect(AppSettings.scrollShrinkToFit)
        // Only the three lengths on offer are believed.
        for stray in [0, 5_000, 15_000, 1_000_000] {
            store.set(stray, forKey: AppSettings.Keys.scrollLengthLimit)
            #expect(AppSettings.scrollLengthLimit == 40_000, "\(stray)")
        }
        #expect(ScrollLengthLimit.options == [10_000, 20_000, 40_000])
    }

    /// The row says how much page and how big a file the limit comes to: a 14"
    /// MacBook Pro screen, at 2x. A step is 0.8 of the screen's height, and the
    /// image is as wide as the screen.
    @Test func theEstimateCountsScreensAndBytesFromTheScreenAndTheFormat() {
        let screen = CGSize(width: 1512, height: 982)
        let png = ScrollLengthLimit.estimate(limit: 20_000, format: "png", screenPoints: screen, backingScale: 2)
        // 20 000 / (982 × 2 × 0.8) = 12.7
        #expect(png.screens == 13)
        // 20 000 × 3024 = 60 480 000 pixels, at 0.15–0.6 bytes each.
        #expect(png.bytes == 9_072_000...36_288_000)
        let jpeg = ScrollLengthLimit.estimate(limit: 20_000, format: "jpg", screenPoints: screen, backingScale: 2)
        #expect(jpeg.bytes == 6_048_000...18_144_000)
        // TIFF is not compressed: one value, four bytes a pixel.
        let tiff = ScrollLengthLimit.estimate(limit: 20_000, format: "tiff", screenPoints: screen, backingScale: 2)
        #expect(tiff.bytes == 241_920_000...241_920_000)

        // Twice the limit, twice the screens and twice the bytes. At 1x the
        // same number of pixels along the scroll is twice the screens, and the
        // image half as wide — half the bytes.
        let double = ScrollLengthLimit.estimate(limit: 40_000, format: "png", screenPoints: screen, backingScale: 2)
        #expect(double.screens == 25)
        #expect(double.bytes.upperBound == png.bytes.upperBound * 2)
        let standard = ScrollLengthLimit.estimate(limit: 20_000, format: "png", screenPoints: screen, backingScale: 1)
        #expect(standard.screens == 25)
        #expect(standard.bytes.upperBound == png.bytes.upperBound / 2)
        // An unknown format is read as PNG, the default.
        #expect(ScrollLengthLimit.estimate(limit: 20_000, format: "heic", screenPoints: screen,
                                           backingScale: 2).bytes == png.bytes)
    }

    /// In the app's language, not the system's: the sentence around it is.
    @Test func theSizeInTheRowIsOneNumberOrARangeInMegabytesInTheAppsLanguage() {
        let en = Locale(identifier: "en"), ru = Locale(identifier: "ru")
        #expect(CaptureSettingsView.sizeText(241_920_000...241_920_000, locale: en) == "242 MB")
        #expect(CaptureSettingsView.sizeText(9_072_000...36_288_000, locale: en) == "9.1–36 MB")
        // Below ten a decimal is worth showing; the separator and the unit are the language's.
        #expect(CaptureSettingsView.sizeText(4_320_000...17_280_000, locale: en) == "4.3–17 MB")
        #expect(CaptureSettingsView.sizeText(4_320_000...17_280_000, locale: ru) == "4,3–17 МБ")
        #expect(CaptureSettingsView.sizeText(241_920_000...241_920_000, locale: ru) == "242 МБ")
    }

    // MARK: Video, fixed bars, and the predicted step

    private let videoFrameHeight = 260, videoStep = 156
    private let videoOffsets = [0, 97, 233, 420]

    /// A video that changes between the frames and covers most of what they
    /// share used to outvote the page: every full-height strip contained it,
    /// so the strips voted against the true offset and the steps would not
    /// match. The tiles it covers say nothing now.
    /// Whatever the matcher answers it must not answer wrongly — a wrong
    /// offset is a seam in the image, an error is a retry.
    @Test func aVideoCoveringMostOfTheOverlapDoesNotOutvoteThePage() {
        let cases: [(rows: Range<Int>, mustMatch: Bool)] = [
            (10..<200, true),    // most of the overlap, the page below still in view
            (30..<235, false),   // nearly all of it: either answer is fine, a wrong one is not
        ]
        for (rows, mustMatch) in cases {
            for offset in videoOffsets {
                let before = videoPage(height: videoFrameHeight, offset: offset, videoSeed: 1, videoRows: rows)
                let after = videoPage(height: videoFrameHeight, offset: offset + videoStep, videoSeed: 2, videoRows: rows)
                do {
                    let match = try FrameMatcher.match(previous: before, current: after, axis: .vertical,
                                                       maximumOffset: videoFrameHeight * 3 / 4)
                    #expect(match.offset == videoStep, "video \(rows) at \(offset): offset \(match.offset)")
                } catch {
                    #expect(!mustMatch, "video \(rows) at \(offset): \(error)")
                }
            }
        }
    }

    /// Whatever a video does to the tiles, a match that is wrong is worse than
    /// none: it is a seam in the image, where a refusal is a retry. A hundred
    /// and fifty pages with a scene of panels over part or all of what two
    /// frames share, taken at different moments of the video — each answer is
    /// the true offset or a refusal, and some of them must be the true offset,
    /// or refusing everything would pass.
    @Test func noVideoMakesTheMatcherAnswerWithAWrongOffset() {
        struct SplitMix {
            var state: UInt64
            mutating func next() -> Int {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Int((z ^ (z >> 31)) >> 1)
            }
        }
        struct Trial {
            let rows: Range<Int>, margin: Int, step: Int, offset: Int, seeds: (Int, Int)
        }
        var random = SplitMix(state: 12345)
        let trials = (0..<150).map { _ -> Trial in
            let height = 100 + random.next() % 500
            let top = random.next() % 300
            let margin = [0, 8, 16, 32][random.next() % 4]
            let step = 100 + random.next() % 90
            let offset = random.next() % 400
            let seeds = (1 + random.next() % 50, 60 + random.next() % 50)
            return Trial(rows: top..<(top + height), margin: margin, step: step, offset: offset, seeds: seeds)
        }
        // The matcher is pure and the trials independent, so they run side by
        // side — a hundred and fifty matches are slow in a build without
        // optimization. The answer of each: -1 refused, otherwise its offset.
        var answers = [Int](repeating: -1, count: trials.count)
        let height = videoFrameHeight
        answers.withUnsafeMutableBufferPointer { out in
            let results = out
            DispatchQueue.concurrentPerform(iterations: trials.count) { index in
                let trial = trials[index]
                let columns = trial.margin..<(320 - trial.margin)
                let before = videoPage(height: height, offset: trial.offset, videoSeed: trial.seeds.0,
                                       videoColumns: columns, videoRows: trial.rows, panels: true)
                let after = videoPage(height: height, offset: trial.offset + trial.step,
                                      videoSeed: trial.seeds.1, videoColumns: columns,
                                      videoRows: trial.rows, panels: true)
                let match = try? FrameMatcher.match(previous: before, current: after, axis: .vertical,
                                                    maximumOffset: height * 3 / 4)
                results[index] = match?.offset ?? -1
            }
        }
        var right = 0, refused = 0
        for (trial, answer) in zip(trials, answers) {
            if answer == -1 { refused += 1 }
            else if answer == trial.step { right += 1 }
            else {
                Issue.record("offset \(answer) for a step of \(trial.step), video rows \(trial.rows), margin \(trial.margin)")
            }
        }
        #expect(right >= 20, "right \(right), refused \(refused)")
    }

    /// A dark page like claude.com/product/design at half the size: a large
    /// heading and a line or two under a wide autoplaying video — 44% of the
    /// page's height, three quarters of its width — with sparse text below. The
    /// scene in the video depends on `videoSeed`; the rest is the same in every
    /// capture. The first screen is the heading with the video under it, the
    /// heading surrounded by dark nothing.
    private func heroPage(videoSeed: Int) throws -> CaptureFrame {
        let width = 1258, pageHeight = 4500
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: pageHeight, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CaptureFrame.bitmapInfo))
        let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        let big = CTFontCreateWithName("Helvetica-Bold" as CFString, 36, nil)
        func text(_ string: String, _ font: CTFont, _ x: Int, _ top: Int, gray: CGFloat) {
            let attributed = NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: NSColor(white: gray, alpha: 1)])
            context.textPosition = CGPoint(x: x, y: pageHeight - top)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
        text("Design your idea with Claude", big, 165, 130, gray: 0.92)
        text("Describe a visual and Claude builds a first version, on brand. Refine, share, or", font, 240, 200, gray: 0.6)
        text("hand off to the tools you use. You're the designer, start to finish.", font, 300, 230, gray: 0.6)
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 540, y: pageHeight - 300, width: 180, height: 45))

        let videoX = 151, videoTop = 381, videoWidth = 956, videoHeight = 620
        let video = CGRect(x: videoX, y: pageHeight - videoTop - videoHeight, width: videoWidth, height: videoHeight)
        context.setFillColor(CGColor(gray: 0.12, alpha: 1)); context.fill(video)
        context.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); context.setLineWidth(1)
        context.stroke(video.insetBy(dx: 0.5, dy: 0.5))
        srand48(videoSeed)
        for panel in 0..<14 {
            let x = videoX + 20 + Int(drand48() * Double(videoWidth - 250))
            let top = videoTop + 20 + Int(drand48() * Double(videoHeight - 150))
            context.setFillColor(CGColor(gray: 0.2 + drand48() * 0.6, alpha: 1))
            context.fill(CGRect(x: x, y: pageHeight - top - 100,
                                width: 100 + Int(drand48() * 150), height: 30 + Int(drand48() * 80)))
            text("Panel \(videoSeed * 31 + panel) · \(100 + Int(drand48() * 900))", font, x + 5, top + 20, gray: 0.95)
        }
        // Sparse paragraphs below the video — the same whatever the seed.
        let words = "describe refine together export hand off prototype slides layout colour brand system component review share iterate canvas comment version".split(separator: " ")
        func word() -> String { String(words[Int(drand48() * Double(words.count))]) }
        var y = videoTop + videoHeight + 150, section = 0
        srand48(4242)
        while y < pageHeight - 100 {
            text("Section \(section) " + (0..<Int(2 + drand48() * 4)).map { _ in word() }.joined(separator: " "),
                 big, 150 + Int(drand48() * 100), y, gray: 0.9)
            y += 75 + Int(drand48() * 20)
            for _ in 0..<Int(2 + drand48() * 5) {
                text((0..<Int(6 + drand48() * 10)).map { _ in word() }.joined(separator: " "), font, 150, y, gray: 0.6)
                y += 28
            }
            y += 90 + Int(drand48() * 120); section += 1
        }
        let image = try #require(context.makeImage())
        return try #require(CaptureFrame(image: image))
    }

    /// The probe on claude.com was refused: the video held more than half of
    /// the tiles with anything in them, and the heading it sat under is a few
    /// bright tiles in the dark. Those few lined up exactly — the page holds
    /// still, the video does not — and that is evidence enough. Twelve captures
    /// of the scene, the video different each time, a probe of 40 px.
    @Test func aProbeBelowAHeadingAndAboveAVideoFindsItsOffset() throws {
        let height = 683
        var found = 0
        for seed in 0..<12 {
            let before = try #require(try heroPage(videoSeed: seed * 2).cropped(to: CGRect(x: 0, y: 0, width: 1258, height: height)))
            let after = try #require(try heroPage(videoSeed: seed * 2 + 1).cropped(to: CGRect(x: 0, y: 40, width: 1258, height: height)))
            do {
                let match = try FrameMatcher.match(previous: before, current: after, axis: .vertical, maximumOffset: 102)
                #expect(match.offset == 40, "seed \(seed): offset \(match.offset)")
                found += 1
            } catch {
                Issue.record("seed \(seed): \(error)")
            }
        }
        #expect(found == 12)
    }

    /// With the video over everything the two frames share, the frames cannot
    /// say how far they moved, only whether a given distance is consistent
    /// with them: the tiles beside the video fit the right offset and refuse
    /// another one.
    @Test func aPredictedOffsetIsCheckedAgainstTheFramesAroundTheVideo() throws {
        let rows = 0..<520, columns = 64..<256
        for offset in [0, 97, 150] {
            let before = videoPage(height: videoFrameHeight, offset: offset, videoSeed: 1,
                                   videoColumns: columns, videoRows: rows)
            let after = videoPage(height: videoFrameHeight, offset: offset + videoStep, videoSeed: 2,
                                  videoColumns: columns, videoRows: rows)
            let verdict = try #require(FrameMatcher.verifyPredicted(
                previous: before, current: after, axis: .vertical, offset: videoStep,
                searchLimit: videoFrameHeight * 3 / 4))
            #expect(verdict.consistent >= 1, "at \(offset)")
            #expect(verdict.against == 0)
            // 20% short is the wrong distance: the tiles beside the video know it.
            #expect(FrameMatcher.verifyPredicted(previous: before, current: after, axis: .vertical,
                                                 offset: videoStep * 4 / 5,
                                                 searchLimit: videoFrameHeight * 3 / 4) == nil,
                    "a wrong prediction was accepted at \(offset)")
        }
    }

    /// Frames in which nothing but the video changes can still be placed — and
    /// a prediction on them that agrees with nothing is no prediction.
    @Test func aPredictionNobodyAgreesWithCountsForNothing() throws {
        // The video over every column: no tile is left to agree or disagree.
        let before = videoPage(height: videoFrameHeight, offset: 97, videoSeed: 1,
                               videoColumns: 0..<320, videoRows: 0..<520)
        let after = videoPage(height: videoFrameHeight, offset: 97 + videoStep, videoSeed: 2,
                              videoColumns: 0..<320, videoRows: 0..<520)
        let verdict = FrameMatcher.verifyPredicted(previous: before, current: after, axis: .vertical,
                                                   offset: videoStep, searchLimit: videoFrameHeight * 3 / 4)
        #expect(verdict?.consistent ?? 0 == 0)
    }

    /// A header that stays put and a banner that stays put are fixed on the
    /// screen while the page moves under them. Held against the scroll they
    /// made each strip vote for "no movement"; as tiles they abstain.
    @Test func aFixedHeaderOrBannerDoesNotHideTheScroll() throws {
        for (header, banner) in [(24, 0), (0, 30)] {
            for offset in videoOffsets {
                let before = videoPage(height: videoFrameHeight, offset: offset, videoSeed: 1,
                                       header: header, banner: banner)
                let after = videoPage(height: videoFrameHeight, offset: offset + videoStep, videoSeed: 1,
                                      header: header, banner: banner)
                let match = try FrameMatcher.match(previous: before, current: after, axis: .vertical,
                                                   maximumOffset: videoFrameHeight * 3 / 4)
                #expect(match.offset == videoStep, "header \(header) banner \(banner) at \(offset)")
            }
        }
    }

    // MARK: Steps the matcher cannot place

    private typealias Evidence = ScrollStepDecision.Evidence

    /// A step with a calibration to go by, clean of earlier attempts, that the
    /// matcher could not decide — the case every row below changes one thing in.
    private func evidence(consistent: Int = 0, against: Int = 0, contradicted: Bool = false,
                          required: Int = 2, unpinnedStanding: Int = 0, queued: Int = 0,
                          undecided: Bool = true, canExpect: Bool = true) -> Evidence {
        Evidence(undecided: undecided, canExpect: canExpect, consistent: consistent, against: against,
                 contradicted: contradicted, required: required, unpinnedStanding: unpinnedStanding,
                 queued: queued)
    }

    /// What is done with a step the frames cannot place, row by row: claude.com
    /// (a video all over the overlap), apple.com's empty gap between sections,
    /// the end of a page, and the ways a step goes wrong.
    @Test func aStepTheMatcherCannotPlaceIsStoppedPlacedProvisionallyOrRetried() {
        typealias Decision = ScrollStepDecision
        // claude.com: 18 of 20 tiles change by themselves, none agrees, none
        // disagrees, none stands. Nothing speaks against the calibration.
        #expect(Decision.decide(evidence()) == .temporary(confirmed: false))
        // apple.com, step 14: an empty frame, only the site's bar standing —
        // and the bar is pinned, so nothing unpinned stands.
        #expect(Decision.decide(evidence(unpinnedStanding: 0)) == .temporary(confirmed: false))
        // The end of a page: a tile with content stands that is not pinned and
        // nothing bears out that the page moved.
        #expect(Decision.decide(evidence(unpinnedStanding: 3)) == .stationary)
        #expect(Decision.decide(evidence(unpinnedStanding: 1, canExpect: false)) == .stationary)
        // The same frames, but one tile fits the distance the calibration expects:
        // the page moved, however much of it also stands.
        #expect(Decision.decide(evidence(consistent: 1, required: 1, unpinnedStanding: 3))
                == .temporary(confirmed: true))
        // Enough tiles agree: confirmed — two before a full step has shown the
        // calibration to hold, one after.
        #expect(Decision.decide(evidence(consistent: 2, required: 2)) == .temporary(confirmed: true))
        #expect(Decision.decide(evidence(consistent: 1, required: 2)) == .temporary(confirmed: false))
        #expect(Decision.decide(evidence(consistent: 1, required: 1)) == .temporary(confirmed: true))
        // Tiles that know better, though not enough to contradict outright: try again.
        #expect(Decision.decide(evidence(consistent: 1, against: 1, required: 2)) == .retry)
        #expect(Decision.decide(evidence(consistent: 3, against: 1, contradicted: true, required: 1)) == .retry)
        // Nothing to expect — no calibration, or an earlier attempt moved the
        // page — and no proof of a stop: try again.
        #expect(Decision.decide(evidence(canExpect: false)) == .retry)
        // Some other failure than a refusal to tell: never a stop.
        #expect(Decision.decide(evidence(unpinnedStanding: 4, undecided: false)) == .retry)
        #expect(Decision.decide(evidence(consistent: 5, undecided: false)) == .retry)
        // Eight steps waiting is the most there is room for.
        #expect(Decision.decide(evidence(queued: TemporarySteps.limit - 1)) == .temporary(confirmed: false))
        #expect(Decision.decide(evidence(queued: TemporarySteps.limit)) == .finish)
        // A stop is a stop at any length of queue: the queue goes with the capture.
        #expect(Decision.decide(evidence(unpinnedStanding: 2, queued: TemporarySteps.limit)) == .stationary)
        #expect(TemporarySteps.limit == 8)
    }

    /// Steps wait in order with the distance each moved the page, are laid into
    /// the image in that order by the step that carries them, and are dropped —
    /// and counted — when the capture ends before one does.
    @Test func temporaryStepsWaitAreLaidInOrderAndAreDroppedWithTheCapture() throws {
        let movements = [60, 45, 70, 50]
        func frames() -> [CaptureFrame] {
            var offset = 0
            return movements.map { movement in
                offset += movement
                return texture(width: 120, height: 200, yOffset: offset)
            }
        }
        // As if each were laid as it came.
        var direct = ImageAssembler(axis: .vertical, maxLength: 10_000)
        direct.begin(with: texture(width: 120, height: 200))
        for (frame, movement) in zip(frames(), movements) { try direct.append(frame, movement: movement) }

        // Kept apart, then laid.
        var kept = ImageAssembler(axis: .vertical, maxLength: 10_000)
        kept.begin(with: texture(width: 120, height: 200))
        var waiting = TemporarySteps()
        #expect(waiting.isEmpty)
        for (index, (frame, movement)) in zip(frames(), movements).enumerated() {
            waiting.add(frame, movement: movement, confirmed: index % 2 == 0)
            #expect(waiting.count == index + 1)
        }
        // Waiting, they are not in the image.
        #expect(kept.totalLength == 200)
        let taken = waiting.take()
        #expect(waiting.isEmpty && taken.map(\.movement) == movements)
        #expect(taken.map(\.confirmed) == [true, false, true, false])
        for step in taken { try kept.append(step.frame, movement: step.movement) }
        #expect(kept.totalLength == direct.totalLength)
        #expect(try kept.makeImage().height == direct.makeImage().height)
        #expect(CaptureFrame(image: try kept.makeImage())?.pixels == CaptureFrame(image: try direct.makeImage())?.pixels)

        // The capture ended first: they are dropped, and the image is as it was.
        var dropped = TemporarySteps()
        for (frame, movement) in zip(frames(), movements) { dropped.add(frame, movement: movement, confirmed: false) }
        #expect(dropped.discard() == movements.count)
        #expect(dropped.isEmpty && dropped.discard() == 0)
    }

    /// What a standing tile can prove. Only the middle rows — 1 and 2 of 0 to 3,
    /// along the scroll — and only when the tile is not pinned: the first and
    /// last rows are where the site's bars and banners live.
    @Test func onlyUnpinnedStandingTilesOfTheMiddleRowsProveThatThePageStopped() {
        typealias Decision = ScrollStepDecision
        func proof(_ standing: Set<Int>, pinned: Set<Int> = []) -> Int {
            Decision.provingStop(standing: standing, pinned: pinned)
        }
        // Tiles are numbered row by row, five to a row.
        #expect(proof([0, 1, 2, 3, 4]) == 0, "the first row")
        #expect(proof([15, 16, 17, 18, 19]) == 0, "the last row")
        #expect(proof([7]) == 1, "row 1")
        #expect(proof([12]) == 1, "row 2")
        #expect(proof([0, 4, 7, 12, 17]) == 2)
        // Pinned tiles of the middle are no proof either.
        #expect(proof([7, 12], pinned: [7]) == 1)
        #expect(proof([7, 12], pinned: [7, 12]) == 0)
        #expect(proof([], pinned: [7]) == 0)
    }

    /// Every refusal of the matcher that says "cannot tell" is asked of the
    /// tiles, and nothing else is.
    @Test func everyRefusalThatSaysTheMatcherCouldNotTellIsAskedOfTheTiles() {
        #expect(ScrollStepDecision.isUndecided(FrameMatchError.noReliableMotion))
        #expect(ScrollStepDecision.isUndecided(FrameMatchError.ambiguousMotion))
        // An empty frame with a bar in it: noise across the axis, nothing along it.
        #expect(ScrollStepDecision.isUndecided(FrameMatchError.crossAxisMotion))
        #expect(!ScrollStepDecision.isUndecided(FrameMatchError.outputLimitExceeded))
        #expect(!ScrollStepDecision.isUndecided(CocoaError(.fileReadUnknown)))
        #expect(!ScrollStepDecision.isUndecided(CancellationError()))
    }

    /// The gaps without content, as the matcher met them on apple.com: a frame
    /// of black and the site's bar, which the matcher answers with
    /// `crossAxisMotion`. Nothing on the page agrees, none disagrees; what
    /// stands is the bar in the first row — and that proves nothing.
    @Test func anEmptyGapIsPlacedByTheCalibrationAndOnlyAMiddleTileStopsTheCapture() {
        typealias Decision = ScrollStepDecision
        func decision(error: Error, standing: Set<Int>, pinned: Set<Int> = []) -> Decision {
            Decision.decide(evidence(unpinnedStanding: Decision.provingStop(standing: standing, pinned: pinned),
                                     undecided: Decision.isUndecided(error)))
        }
        let cross = FrameMatchError.crossAxisMotion
        // 0/0, and only the first row stands: provisional, unconfirmed.
        #expect(decision(error: cross, standing: [0, 1, 2, 3, 4]) == .temporary(confirmed: false))
        // A tile of row 1 stands: the page has stopped.
        #expect(decision(error: cross, standing: [0, 1, 7]) == .stationary)
        // A tile of row 3 stands: it is the banner, not a stop.
        #expect(decision(error: cross, standing: [17]) == .temporary(confirmed: false))
        // The same tile of the middle, pinned by a step that moved the page: no stop.
        #expect(decision(error: cross, standing: [7], pinned: [7]) == .temporary(confirmed: false))
        // The other refusals go the same way.
        for error in [FrameMatchError.noReliableMotion, .ambiguousMotion] {
            #expect(decision(error: error, standing: [0, 4]) == .temporary(confirmed: false))
            #expect(decision(error: error, standing: [12]) == .stationary)
        }
        // A failure of another kind is a retry whatever stands.
        #expect(decision(error: CocoaError(.fileReadUnknown), standing: [7, 12]) == .retry)
    }

    /// A tile that stands still while the page moves is fixed to the viewport,
    /// and it is found in the step that moved the page. The site's bar is that
    /// tile in the first row; a side panel is one in the middle, and for the
    /// side panel the pin is what stops it from proving a stop.
    @Test func aTileThatStandsWhileThePageMovesIsPinnedAndAPinnedPanelProvesNothingAfterwards() throws {
        // Tiles are 65 rows and 64 columns of the 260 × 320 frame; the bar is
        // the first row of tiles, the panel one tile — row 1, column 0 — so
        // that no tile is part fixed and part page.
        let height = 260, step = 100
        let barRows = 0..<65, panelRows = 65..<130, panelColumns = 0..<64
        // Something in it along the scroll as well as across: text, a logo.
        // Flat down its height it would fit any distance and say nothing.
        func fixed(_ frame: CaptureFrame) -> CaptureFrame {
            var pixels = frame.pixels
            func paint(rows: Range<Int>, columns: Range<Int>, salt: Int) {
                for y in rows { for x in columns {
                    let i = (y * frame.width + x) * 4
                    let value = UInt8(truncatingIfNeeded: 70 + noise(x, y &+ salt) % 150)
                    pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
                } }
            }
            paint(rows: barRows, columns: 0..<frame.width, salt: 5000)
            paint(rows: panelRows, columns: panelColumns, salt: 9000)
            return CaptureFrame(width: frame.width, height: frame.height, pixels: pixels)
        }
        func page(_ offset: Int) -> CaptureFrame {
            fixed(videoPage(height: height, offset: offset, videoSeed: 1))
        }
        // A step the matcher places: the bar's tiles and the panel's stand.
        let match = try FrameMatcher.match(previous: page(0), current: page(step), axis: .vertical,
                                           maximumOffset: height * 3 / 4)
        #expect(match.offset == step)
        let bar: Set<Int> = [0, 1, 2, 3, 4], panel = 5
        #expect(match.standing.isSuperset(of: bar), "standing: \(match.standing.sorted())")
        #expect(match.standing.contains(panel), "standing: \(match.standing.sorted())")
        // The tiles of the page moved.
        #expect(!match.standing.contains(12) && !match.standing.contains(17))

        // Later a frame that is the bar and the panel and nothing else, twice.
        func empty() -> CaptureFrame {
            let frame = fixed(videoPage(height: height, offset: 0, videoSeed: 1))
            var pixels = frame.pixels
            for y in 0..<height { for x in 0..<frame.width where !(barRows ~= y) && !(panelRows ~= y && panelColumns ~= x) {
                let i = (y * frame.width + x) * 4
                pixels[i] = 24; pixels[i + 1] = 24; pixels[i + 2] = 24
            } }
            return CaptureFrame(width: frame.width, height: frame.height, pixels: pixels)
        }
        let found = FrameMatcher.evidence(previous: empty(), current: empty(), axis: .vertical,
                                          offset: step, searchLimit: height * 3 / 4)
        #expect(found.standing.isSuperset(of: bar) && found.standing.contains(panel))
        #expect(found.consistent == 0)
        func decision(pinned: Set<Int>) -> ScrollStepDecision {
            ScrollStepDecision.decide(evidence(
                consistent: found.consistent, against: found.against, contradicted: found.contradicted,
                unpinnedStanding: ScrollStepDecision.provingStop(standing: found.standing, pinned: pinned)))
        }
        // Knowing the panel is pinned: an empty gap, which the calibration carries.
        #expect(decision(pinned: match.standing) == .temporary(confirmed: false))
        // Not knowing: the panel standing looks like a page that stopped. The bar
        // does not, pinned or not.
        #expect(decision(pinned: []) == .stationary)
        #expect(decision(pinned: [panel]) == .temporary(confirmed: false))
    }

    /// The frames of the cases above, as the matcher meets them.
    @Test func theEvidenceOfAStepReadsStandingTilesAndTheExpectedDistance() throws {
        let height = videoFrameHeight, step = videoStep, limit = height * 3 / 4
        // A page that has not moved at all: every tile with content stands, and
        // nothing bears out a distance.
        let still = videoPage(height: height, offset: 97, videoSeed: 1, videoRows: 0..<520)
        let same = FrameMatcher.evidence(previous: still, current: still, axis: .vertical,
                                         offset: step, searchLimit: limit)
        #expect(same.standing.count >= 8, "standing: \(same.standing.sorted())")
        #expect(same.consistent == 0 && !same.contradicted)

        // A video over everything that is shared, different each time: no tile
        // stands, none agrees, none disagrees.
        let rows = 0..<520, columns = 0..<320
        let before = videoPage(height: height, offset: 97, videoSeed: 1, videoColumns: columns, videoRows: rows)
        let after = videoPage(height: height, offset: 97 + step, videoSeed: 2, videoColumns: columns, videoRows: rows)
        let video = FrameMatcher.evidence(previous: before, current: after, axis: .vertical,
                                          offset: step, searchLimit: limit)
        #expect(video.standing.isEmpty)
        #expect(video.consistent == 0 && video.against == 0 && !video.contradicted)

        // The page moved and a video is beside the text: the tiles beside it
        // bear the distance out, and a wrong one is contradicted.
        let partBefore = videoPage(height: height, offset: 97, videoSeed: 1, videoColumns: 64..<256, videoRows: 0..<520)
        let partAfter = videoPage(height: height, offset: 97 + step, videoSeed: 2, videoColumns: 64..<256, videoRows: 0..<520)
        let right = FrameMatcher.evidence(previous: partBefore, current: partAfter, axis: .vertical,
                                          offset: step, searchLimit: limit)
        #expect(right.consistent >= 1 && !right.contradicted)
        let wrong = FrameMatcher.evidence(previous: partBefore, current: partAfter, axis: .vertical,
                                          offset: step * 4 / 5, searchLimit: limit)
        #expect(wrong.contradicted)
        // Nothing asked about: standing tiles only, and nothing contradicted.
        let none = FrameMatcher.evidence(previous: partBefore, current: partAfter, axis: .vertical,
                                         offset: nil, searchLimit: limit)
        #expect(none.consistent == 0 && !none.contradicted)
        // A distance that cannot be looked at is contradicted.
        #expect(FrameMatcher.evidence(previous: partBefore, current: partAfter, axis: .vertical,
                                      offset: limit * 2, searchLimit: limit).contradicted)
    }

    /// A probe of one line says nothing about ten until a full step agrees; up
    /// to then the frames must bear the prediction out in two tiles, after it in one.
    @Test func anUnconfirmedCalibrationNeedsTwoTilesToAgreeAndAConfirmedOneNeedsOne() {
        #expect(ScrollStepPlanner.tilesRequiredToAgree(linearityConfirmed: false) == 2)
        #expect(ScrollStepPlanner.tilesRequiredToAgree(linearityConfirmed: true) == 1)
    }

    /// A late calibration is the same division as the probe's, over the lines
    /// of the step that matched.
    @Test func aStepThatMatchesLateCalibratesLikeTheProbe() {
        #expect(ScrollStepPlanner.pixelsPerLine(offset: 400, lines: 5) == 80)
        #expect(ScrollStepPlanner.plan(target: 820, pixelsPerLine: 80, axisLength: 1366, backingScale: 2).lines == 10)
    }

    @Test func linearityIsAFullStepWithinTwoPixelsOrTwoPercentOfTheCalibration() {
        #expect(ScrollStepPlanner.predictedOffset(lines: 10, pixelsPerLine: 80.4) == 804)
        // 800 expected: 2% is 16 px.
        #expect(ScrollStepPlanner.confirmsLinearity(offset: 800, lines: 10, pixelsPerLine: 80))
        #expect(ScrollStepPlanner.confirmsLinearity(offset: 815, lines: 10, pixelsPerLine: 80))
        #expect(!ScrollStepPlanner.confirmsLinearity(offset: 820, lines: 10, pixelsPerLine: 80))
        // Small steps get the two pixels instead.
        #expect(ScrollStepPlanner.confirmsLinearity(offset: 42, lines: 1, pixelsPerLine: 40))
        #expect(!ScrollStepPlanner.confirmsLinearity(offset: 43, lines: 1, pixelsPerLine: 40))
        // A page that scrolled twice as far for ten lines as for one is not linear.
        #expect(!ScrollStepPlanner.confirmsLinearity(offset: 800, lines: 10, pixelsPerLine: 40))
    }

    @Test func calibrationIsTheProbesMovementOverTheLinesItSent() {
        #expect(ScrollStepPlanner.pixelsPerLine(offset: 80, lines: 2) == 40)
        #expect(ScrollStepPlanner.pixelsPerLine(offset: 0, lines: 1) == nil)
        #expect(ScrollStepPlanner.pixelsPerLine(offset: 80, lines: 0) == nil)
    }

    @Test func stepsAreLinesThatReachTheTargetAndLeaveTheFramesOverlapping() {
        // 80 px a line, a 1366 px frame: the target (60%) is ten lines, and 800 px is under 1024.
        #expect(ScrollStepPlanner.lines(target: 820, pixelsPerLine: 80, axisLength: 1366) == 10)
        // 200 px a line: four lines.
        #expect(ScrollStepPlanner.lines(target: 820, pixelsPerLine: 200, axisLength: 1366) == 4)
        // 300 px a line in a 1000 px frame: never more than fits in 750.
        let lines = ScrollStepPlanner.lines(target: 900, pixelsPerLine: 300, axisLength: 1000)
        #expect(lines == 2)
        #expect(Double(lines) * 300 <= 750)
        // One line is the floor even when a line alone is too long, and ten the ceiling.
        #expect(ScrollStepPlanner.lines(target: 600, pixelsPerLine: 900, axisLength: 1000) == 1)
        #expect(ScrollStepPlanner.lines(target: 5000, pixelsPerLine: 10, axisLength: 4000) == 10)
    }

    @Test func theSearchBoundIsHalfAgainAsFarAsTheLinesMoveAndNeverPastThreeQuarters() {
        #expect(ScrollStepPlanner.motionLimit(lines: 4, pixelsPerLine: 200, axisLength: 1366) == 1024)
        #expect(ScrollStepPlanner.motionLimit(lines: 5, pixelsPerLine: 40, axisLength: 1366) == 332)
    }

    @Test func withoutACalibrationTheOldEstimateFromPointsStillPlansTheStep() {
        let plan = ScrollStepPlanner.plan(target: 1080, pixelsPerLine: nil, axisLength: 3000, backingScale: 2)
        #expect(plan.lines == 6)
        #expect(plan.motionLimit == ScrollDriver.maximumLikelyMovement(pixelStep: 1080, backingScale: 2,
                                                                       viewportLength: 3000))
        let calibrated = ScrollStepPlanner.plan(target: 820, pixelsPerLine: 80, axisLength: 1366, backingScale: 2)
        #expect(calibrated.lines == 10)
        #expect(calibrated.motionLimit == 1024)
    }

    @Test func aWindowOfOursOverThePointCoversItUnlessItIsTheIgnoredPanel() {
        let page = ScrollDriver.WindowListEntry(windowID: 7, processID: 100,
                                                bounds: CGRect(x: 0, y: 0, width: 800, height: 600), alpha: 1)
        // The picker, still fading: nearly transparent, full screen, ours.
        let fadingPicker = ScrollDriver.WindowListEntry(windowID: 9, processID: 1,
                                                        bounds: CGRect(x: 0, y: 0, width: 1280, height: 832), alpha: 0.2)
        // The notch panel's window: tall, transparent below its content, ours.
        let notchPanel = ScrollDriver.WindowListEntry(windowID: 5, processID: 1,
                                                      bounds: CGRect(x: 380, y: 0, width: 520, height: 168), alpha: 1)
        let point = CGPoint(x: 400, y: 100)

        // Front to back: a window of ours on top is what is under the pointer.
        let covered = ScrollDriver.topmostWindow(at: point, in: [fadingPicker, page], ignoring: [])
        #expect(covered?.windowID == 9)
        // The panel is looked through, and the page behind it is the answer.
        let through = ScrollDriver.topmostWindow(at: point, in: [notchPanel, page], ignoring: [5])
        #expect(through?.windowID == 7)
        // Only that one: another window of ours over the point still covers it.
        let stillCovered = ScrollDriver.topmostWindow(at: point, in: [fadingPicker, notchPanel, page], ignoring: [5])
        #expect(stillCovered?.windowID == 9)
        // Gone once it has gone: fully transparent windows are not there.
        let gone = ScrollDriver.WindowListEntry(windowID: 9, processID: 1, bounds: fadingPicker.bounds, alpha: 0)
        #expect(ScrollDriver.topmostWindow(at: point, in: [gone, page], ignoring: [])?.windowID == 7)
    }

    /// Who touched the page, and what the capture does about it. The capture's
    /// own wheel events reach a global monitor like any other and are told by
    /// the mark they carry; everything else that moves the page, or could, is
    /// the user taking over and pauses it with a toast.
    @Test func inputThatIsNotTheCapturesOwnPausesItWithAToast() {
        let marker = ScrollInputGuard.syntheticMarker
        func response(_ kind: ScrollInputGuard.Kind, data: Int64 = 0) -> ScrollInputGuard.Response {
            ScrollInputGuard.response(to: kind, userData: data)
        }
        // A wheel event: the capture's own is marked, the user's is not.
        #expect(response(.scrollWheel, data: marker) == .nothing)
        #expect(response(.scrollWheel, data: 0) == .pauseAnnounced)
        #expect(response(.scrollWheel, data: marker + 1) == .pauseAnnounced)
        // Buttons and keys; Esc cancels on its own account.
        #expect(response(.mouseDown) == .pauseAnnounced)
        #expect(response(.key(isEscape: false)) == .pauseAnnounced)
        #expect(response(.key(isEscape: true)) == .nothing)
    }

    /// With nothing collected yet there is nothing for Save to keep: a hand on
    /// the page gives the window's screenshot instead.
    @Test func whatTheInputDoesDependsOnWhetherAFrameIsIn() {
        typealias Guard = ScrollInputGuard
        #expect(Guard.outcome(of: .nothing, hasCollected: true) == .ignore)
        #expect(Guard.outcome(of: .nothing, hasCollected: false) == .ignore)
        #expect(Guard.outcome(of: .pauseAnnounced, hasCollected: true) == .pause)
        #expect(Guard.outcome(of: .pauseAnnounced, hasCollected: false) == .windowScreenshot)
    }

    /// The pointer is not input. Off the page, or on Stampo's strip, the user is
    /// reaching for a button: the capture holds its next step until it is back.
    @Test func theCaptureWaitsWhileThePointerIsOffThePageOrOnTheStrip() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        func waits(_ pointer: CGPoint, overUI: Bool = false) -> Bool {
            ScrollInputGuard.shouldWait(pointer: pointer, window: window, overOwnUI: overUI)
        }
        #expect(!waits(CGPoint(x: 400, y: 300)))
        #expect(waits(CGPoint(x: 1200, y: 300)))
        #expect(waits(CGPoint(x: 400, y: 40)))
        // On the strip, which may well be over the page's top edge.
        #expect(waits(CGPoint(x: 400, y: 110), overUI: true))
        #expect(waits(CGPoint(x: 1200, y: 300), overUI: true))
        // The edge of the window is in it.
        #expect(!waits(CGPoint(x: 100, y: 100)))
    }

    /// While the capture is paused the user's input is written down: the wheel,
    /// inertia included, and whether a key or a click may have moved the page.
    /// The capture's own marked events are not the user's.
    @Test func theLedgerSumsTheUsersWheelAndNotesKeysAndClicks() {
        typealias Event = ScrollInputGuard.Event
        var ledger = UserScrollLedger()
        #expect(!ledger.mayHaveMovedPage)
        #expect(ledger.pageMovement(scale: 2, pixelsPerLine: 80) == 0)
        // A trackpad scrolled the page toward its end: negative deltas, in points.
        ledger.record(Event(kind: .scrollWheel, preciseY: -30), axis: .vertical)
        ledger.record(Event(kind: .scrollWheel, preciseY: -20, isMomentum: true), axis: .vertical)
        // A mouse wheel toward the start by one line.
        ledger.record(Event(kind: .scrollWheel, lineY: 1), axis: .vertical)
        // Across the axis: not counted.
        ledger.record(Event(kind: .scrollWheel, preciseX: 400), axis: .vertical)
        // The capture's own event: not the user's.
        ledger.record(Event(kind: .scrollWheel, userData: ScrollInputGuard.syntheticMarker, lineY: -9),
                      axis: .vertical)
        #expect(ledger.mayHaveMovedPage)
        // 50 points at 2x toward the end, less one line of 80 pixels toward the start.
        #expect(ledger.pageMovement(scale: 2, pixelsPerLine: 80) == 100 - 80)
        // Along a horizontal capture it is the other delta.
        var sideways = UserScrollLedger()
        sideways.record(Event(kind: .scrollWheel, preciseX: -10, preciseY: 400), axis: .horizontal)
        #expect(sideways.pageMovement(scale: 1, pixelsPerLine: nil) == 10)
        // Without a measure a line is 80 points.
        var lined = UserScrollLedger()
        lined.record(Event(kind: .scrollWheel, lineY: -2), axis: .vertical)
        #expect(lined.pageMovement(scale: 2, pixelsPerLine: nil) == 320)

        // A key or a click may have moved it by an unknown amount; Esc is not one.
        var keyed = UserScrollLedger()
        keyed.record(Event(kind: .key(isEscape: true)), axis: .vertical)
        #expect(!keyed.mayHaveMovedPage)
        keyed.record(Event(kind: .key(isEscape: false)), axis: .vertical)
        #expect(keyed.mayHaveMovedPage && keyed.pageMovement(scale: 2, pixelsPerLine: 80) == 0)
        var clicked = UserScrollLedger()
        clicked.record(Event(kind: .mouseDown), axis: .vertical)
        #expect(clicked.mayHaveMovedPage)
    }

    /// After a pause the capture looks for its place only if the page may have
    /// moved: something was done to it, or a step was cut short.
    @Test func afterAPauseThePlaceIsLookedForOnlyIfThePageMayHaveMoved() {
        let quiet = UserScrollLedger()
        #expect(!ScrollResume.needsLooking(ledger: quiet, stepWasInFlight: false))
        #expect(ScrollResume.needsLooking(ledger: quiet, stepWasInFlight: true))
        var scrolled = UserScrollLedger()
        scrolled.record(.init(kind: .scrollWheel, lineY: 1), axis: .vertical)
        #expect(ScrollResume.needsLooking(ledger: scrolled, stepWasInFlight: false))
    }

    /// What is done with what the frames say about the place, row by row.
    @Test func theCaptureFindsItsPlaceAgainByTheFramesAndThenByUndoingTheUser() {
        typealias Resume = ScrollResume
        #expect(Resume.action(finding: .same, userMovement: 500, undone: false) == .goOn)
        #expect(Resume.action(finding: .ahead(300), userMovement: 500, undone: false) == .lay(movement: 300))
        #expect(Resume.action(finding: .behind(120), userMovement: 0, undone: false) == .scrollForward(pixels: 120))
        // The frames cannot tell: undo what the user did, once.
        #expect(Resume.action(finding: .unknown, userMovement: 900, undone: false) == .undoUser(pixels: 900))
        #expect(Resume.action(finding: .unknown, userMovement: -400, undone: false) == .undoUser(pixels: -400))
        #expect(Resume.action(finding: .unknown, userMovement: 900, undone: true) == .giveUp)
        // Nothing known of what the user did — a key, a click — and nothing from the frames.
        #expect(Resume.action(finding: .unknown, userMovement: 0, undone: false) == .giveUp)
        // A distance in lines: as measured, or 80 points to the line.
        #expect(Resume.lines(forPixels: 800, pixelsPerLine: 80, scale: 2) == 10)
        #expect(Resume.lines(forPixels: -800, pixelsPerLine: 80, scale: 2) == 10)
        #expect(Resume.lines(forPixels: 320, pixelsPerLine: nil, scale: 2) == 2)
        #expect(Resume.lines(forPixels: 30, pixelsPerLine: 80, scale: 2) == 0)
    }

    /// The place on real frames: further on, back, where it was, and lost.
    @Test func thePlaceIsReadFromFramesFurtherOnBackWhereItWasAndLost() {
        let height = 260
        func page(_ offset: Int) -> CaptureFrame { texture(width: 240, height: height, yOffset: offset) }
        let last = page(300)
        #expect(ScrollPlaceFinding.find(last: last, now: page(380), axis: .vertical) == .ahead(80))
        #expect(ScrollPlaceFinding.find(last: last, now: page(240), axis: .vertical) == .behind(60))
        #expect(ScrollPlaceFinding.find(last: last, now: last, axis: .vertical) == .same)
        // Further than the frames overlap — nothing of the one is in the other
        // (the texture repeats every 256 rows, so it is another stretch of the
        // page across as well): lost.
        let elsewhere = texture(width: 240, height: height, xOffset: 977, yOffset: 1500)
        #expect(ScrollPlaceFinding.find(last: last, now: elsewhere, axis: .vertical) == .unknown)
    }

    /// The capture's wheel event is built whole and marked, so what the guard
    /// recognises is what is sent: forward is negative and back positive, on the
    /// axis asked for, at the point asked for.
    @Test func theCapturesOwnScrollEventCarriesTheMarkAndTheDirection() throws {
        let point = CGPoint(x: 321, y: 123)
        let down = try #require(ScrollDriver.scrollEvent(axis: .vertical, lines: 3, at: point))
        #expect(down.getIntegerValueField(.eventSourceUserData) == ScrollInputGuard.syntheticMarker)
        #expect(down.location == point)
        #expect(down.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3)
        #expect(down.getIntegerValueField(.scrollWheelEventDeltaAxis2) == 0)
        let back = try #require(ScrollDriver.scrollEvent(axis: .vertical, lines: 3, backwards: true, at: point))
        #expect(back.getIntegerValueField(.eventSourceUserData) == ScrollInputGuard.syntheticMarker)
        #expect(back.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
        let right = try #require(ScrollDriver.scrollEvent(axis: .horizontal, lines: 2, at: point))
        #expect(right.getIntegerValueField(.scrollWheelEventDeltaAxis2) == -2)
        #expect(right.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 0)
        #expect(ScrollDriver.scrollEvent(axis: .vertical, lines: 0, at: point) == nil)
        // A hand that scrolls carries no such mark.
        let plain = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: -3, wheel2: 0, wheel3: 0))
        #expect(plain.getIntegerValueField(.eventSourceUserData) != ScrollInputGuard.syntheticMarker)
    }

    @Test func theMonitorsPointerIsInTheWindowListsSpace() {
        // The top of the primary display is y 0 in the window list, its bottom y = height.
        #expect(ScrollInputGuard.quartzPoint(fromAppKit: NSPoint(x: 5, y: 832), primaryHeight: 832) == CGPoint(x: 5, y: 0))
        #expect(ScrollInputGuard.quartzPoint(fromAppKit: NSPoint(x: 5, y: 0), primaryHeight: 832) == CGPoint(x: 5, y: 832))
    }

    /// The button in the arc's place: a turning ring with the pause sign while
    /// the capture works, the play sign while it waits, the ring alone — and
    /// nothing to click — while the image is being written.
    @Test func theStripButtonPausesResumesAndWhileSavingDoesNothing() {
        #expect(ScrollStripPhase(.capturing) == .running)
        #expect(ScrollStripPhase(.saving) == .saving)
        #expect(ScrollStripPhase(.paused(announce: true)) == .paused)
        #expect(ScrollStripPhase(.paused(announce: false)) == .paused)
        #expect(ScrollStripPhase.running.pauseButtonKind == .pause)
        #expect(ScrollStripPhase.paused.pauseButtonKind == .resume)
        #expect(ScrollStripPhase.saving.pauseButtonKind == .busy)
    }

    /// A capture is saved when it has made no headway for twenty seconds, not
    /// when it has run for a long time — and paused time, or time waiting for
    /// the pointer, is not time without headway.
    @Test func aCaptureIsSavedAfterTwentySecondsWithoutProgressNotAfterAnyTotal() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func over(after seconds: TimeInterval, idle: TimeInterval = 0) -> Bool {
            ScrollProgressTimeout.isOver(lastProgress: t0, now: t0.addingTimeInterval(seconds), idle: idle)
        }
        #expect(ScrollProgressTimeout.seconds == 20)
        // Just made headway.
        #expect(!over(after: 0))
        #expect(!over(after: 19.9))
        // Twenty seconds without.
        #expect(over(after: 20))
        #expect(over(after: 45))
        // The time paused or waiting for the pointer does not count.
        #expect(!over(after: 120, idle: 110))
        #expect(!over(after: 30, idle: 15))
        #expect(over(after: 30, idle: 10))
        #expect(!over(after: 600, idle: 600))
        // A page that has taken ten minutes and is still going is not stopped:
        // headway keeps moving the last-progress time up.
        let later = t0.addingTimeInterval(590)
        #expect(!ScrollProgressTimeout.isOver(lastProgress: later, now: t0.addingTimeInterval(600), idle: 0))
        // An idle sum larger than the time elapsed — a clock that stepped — is no reason to stop.
        #expect(!over(after: 5, idle: 50))
    }

    /// Which failures in the middle of a capture are hiccups to be waited out:
    /// something over the scroll point, and the window list stumbling. The rest
    /// pause as ever.
    @Test func onlyHiccupsAreWaitedOutAndTheRestPause() {
        typealias Interference = ScrollInterference
        #expect(Interference.classify(ScrollDriver.selectedWindowNotFrontmost()) == .pointCovered)
        #expect(Interference.classify(ScrollDriverError.pointCovered) == .pointCovered)
        #expect(Interference.classify(ScrollDriverError.windowSizeChanged) == .windowGlitch)
        #expect(Interference.classify(ScrollDriverError.displayScaleChanged) == .windowGlitch)
        #expect(Interference.classify(WindowFrameSourceError.windowUnavailable) == .windowGlitch)
        // The window sent to the back is the user's doing, not a hiccup; the
        // scroll area and the event are other matters.
        let others: [Error] = [WindowFrameSourceError.captureFailed("The window moved to the background."),
                               WindowFrameSourceError.permissionDenied,
                               ScrollDriverError.scrollAreaUnavailable, ScrollDriverError.noMovingContent,
                               ScrollDriverError.eventUnavailable, ScrollDriverError.accessibilityDenied,
                               CocoaError(.fileReadUnknown)]
        for error in others { #expect(Interference.classify(error) == nil, "\(error)") }
    }

    /// How long a hiccup is waited for, looking every quarter of a second: ten
    /// seconds for a thing over the point, two for a stumble of the window list;
    /// it passing at any moment sends the step on.
    @Test func aHiccupIsWaitedForTenSecondsOrTwoAndPassingSendsTheStepOn() {
        typealias Interference = ScrollInterference
        #expect(Interference.pollInterval == 0.25)
        #expect(Interference.pointCovered.patience == 10)
        #expect(Interference.windowGlitch.patience == 2)
        for interference in [Interference.pointCovered, .windowGlitch] {
            // Clear: on, whenever it is.
            #expect(interference.verdict(clear: true, waited: 0) == .goOn)
            #expect(interference.verdict(clear: true, waited: 9.9) == .goOn)
            #expect(interference.verdict(clear: true, waited: 500) == .goOn)
            // Not clear: wait until the time is up.
            #expect(interference.verdict(clear: false, waited: 0) == .wait)
        }
        #expect(Interference.pointCovered.verdict(clear: false, waited: 9.75) == .wait)
        #expect(Interference.pointCovered.verdict(clear: false, waited: 10) == .pause)
        #expect(Interference.windowGlitch.verdict(clear: false, waited: 1.75) == .wait)
        #expect(Interference.windowGlitch.verdict(clear: false, waited: 2) == .pause)
        #expect(Interference.windowGlitch.verdict(clear: false, waited: 30) == .pause)
        // A flicker that never settles ends in a pause after a few.
        #expect(Interference.maxWithoutProgress == 5)
    }

    /// Mid-capture, no scroll area under the point is let through to the
    /// window check — the window is on top there, which was looked at first —
    /// and before the first strip it stops the capture. Other failures are
    /// never let through.
    @Test func noScrollAreaUnderThePointGoesOnToTheWindowCheckOnceAStripIsIn() {
        typealias Interference = ScrollInterference
        #expect(Interference.fallsBackToWindowCheck(ScrollDriverError.scrollAreaUnavailable, hasCollected: true))
        #expect(!Interference.fallsBackToWindowCheck(ScrollDriverError.scrollAreaUnavailable, hasCollected: false))
        #expect(!Interference.fallsBackToWindowCheck(ScrollDriverError.pointCovered, hasCollected: true))
        #expect(!Interference.fallsBackToWindowCheck(WindowFrameSourceError.windowUnavailable, hasCollected: true))
        #expect(!Interference.fallsBackToWindowCheck(CocoaError(.fileReadUnknown), hasCollected: true))
    }

    /// The button that saves is as wide as its title needs — with ten points to
    /// spare on either side — and never narrower than the button the panel's
    /// layout has counted. «Сохранить» did not fit in 71.
    @Test func theSaveButtonGrowsToHoldItsTitleAndNeverShrinks() {
        let minimum: CGFloat = 71
        let ru = LocaleManager.string("Save", locale: Locale(identifier: "ru"))
        let en = LocaleManager.string("Save", locale: Locale(identifier: "en"))
        #expect(ru == "Сохранить" && en == "Save")
        #expect(PanelCaptureButton.width(minimum: minimum, fitting: ru) == 86)
        #expect(PanelCaptureButton.width(minimum: minimum, fitting: en) == minimum)
        // A longer title, a wider button; the inset is ten points a side.
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let long = "Сохранить и закрыть"
        let natural = ceil((long as NSString).size(withAttributes: [.font: font]).width)
        #expect(PanelCaptureButton.width(minimum: minimum, fitting: long) == natural + 20)
        // A smaller minimum than the title needs changes nothing; a larger one wins.
        #expect(PanelCaptureButton.width(minimum: 120, fitting: ru) == 120)
        #expect(PanelCaptureButton.titleInset == 10)
    }

    /// Pause and resume before the first strip is in: the capture starts over
    /// from the window, and what ends it is told as any ending before a frame.
    @Test @MainActor func pausingBeforeTheFirstFrameAndResumingStartsTheCaptureOver() async {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 15, y: 15),
                                              bounds: CGRect(x: 0, y: 0, width: 120, height: 90))
        var activations = 0
        let session = ScrollingCaptureSession(selection: selection, axis: .vertical,
                                              activateSelectedWindow: { _ in
                                                  activations += 1
                                                  throw ScrollDriverError.scrollAreaUnavailable
                                              })
        var statuses: [ScrollCaptureStatus] = []
        var instead = 0
        session.onStatus = { statuses.append($0) }
        session.onWindowScreenshotInstead = { instead += 1 }
        session.togglePause()
        #expect(statuses == [.paused(announce: false)])
        // A second click on the pause sign is a click on the play sign.
        session.togglePause()
        #expect(statuses == [.paused(announce: false), .capturing])
        // The resumed run is a task; wait for it by giving it the main actor.
        for _ in 0..<50 where instead == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(activations == 1 && instead == 1)
        // Over: a click now is nothing.
        session.togglePause()
        #expect(statuses == [.paused(announce: false), .capturing])
    }

    @Test func macOSAsksForAccessibilityOnceAndOurAlertIsTheOnlyThingAfter() {
        let first = ScrollingCaptureSession.accessibilityPlan(promptedBefore: false)
        #expect(first.prompt && !first.alertIfDenied)
        let later = ScrollingCaptureSession.accessibilityPlan(promptedBefore: true)
        #expect(!later.prompt && later.alertIfDenied)
    }

    @Test @MainActor func doneBeforeTheFirstFrameCancelsWithoutAnythingToSave() {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 15, y: 15),
                                              bounds: CGRect(x: 0, y: 0, width: 120, height: 90))
        let session = ScrollingCaptureSession(selection: selection, axis: .vertical)
        var statuses: [ScrollCaptureStatus] = []
        var didFinish = false
        var didCancel = false
        session.onStatus = { statuses.append($0) }
        session.onFinished = { _ in didFinish = true }
        session.onCancelled = { didCancel = true }
        session.finish()
        #expect(didCancel)
        #expect(!didFinish)
        // No "saving": there is no file, and no alert — nothing failed.
        #expect(statuses.isEmpty)
    }

    @Test func aWindowCentreFindsItsScreen() throws {
        let screen = try #require(NSScreen.screens.first)
        let id = try #require(screen.displayID)
        let bounds = CGDisplayBounds(id)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        #expect(NSScreen.containing(quartzPoint: centre)?.displayID == id)
        #expect(NSScreen.containing(quartzPoint: CGPoint(x: bounds.minX - 100_000, y: 0)) == nil)
    }

    @Test @MainActor func aWindowListPointKeepsItsPlaceInAppKitSpace() {
        // The top-left corner of the primary display is its top-left whichever
        // way y runs, and a point 10 below it is 10 under the top edge.
        let top = NotchPanelController.appKitPoint(fromQuartz: CGPoint(x: 5, y: 0), primaryHeight: 900)
        #expect(top == NSPoint(x: 5, y: 900))
        let below = NotchPanelController.appKitPoint(fromQuartz: CGPoint(x: 5, y: 10), primaryHeight: 900)
        #expect(below == NSPoint(x: 5, y: 890))
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

    /// Before the first frame, only what the user can do something about gets an
    /// alert; everything else — nothing scrolled, no scroll area, the scroll
    /// point covered, the window not brought forward, a wheel event that would
    /// not send — ends in the plain screenshot of the window.
    @Test func aFailureBeforeTheFirstFrameIsAnAlertOnlyWhenTheUserCanActOnIt() {
        let alerts: [Error] = [WindowFrameSourceError.permissionDenied,
                               ScrollDriverError.accessibilityDenied,
                               WindowFrameSourceError.windowUnavailable]
        for error in alerts { #expect(ScrollStartFailure.response(to: error) == .alert, "\(error)") }
        let screenshots: [Error] = [ScrollDriverError.noMovingContent,
                                    ScrollDriverError.scrollAreaUnavailable,
                                    ScrollDriverError.eventUnavailable,
                                    ScrollDriver.selectedWindowNotFrontmost(),
                                    WindowFrameSourceError.captureFailed("The window moved to the background."),
                                    WindowFrameSourceError.invalidFrame,
                                    FrameMatchError.noReliableMotion,
                                    CocoaError(.fileReadUnknown)]
        for error in screenshots { #expect(ScrollStartFailure.response(to: error) == .windowScreenshot, "\(error)") }
    }

    /// The session says it is giving way to a window screenshot — and only that:
    /// it is not a cancellation, which would send the strip away with nothing.
    @Test @MainActor func aSessionThatCannotScrollAsksForTheWindowScreenshotInstead() async {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 15, y: 15),
                                              bounds: CGRect(x: 0, y: 0, width: 120, height: 90))
        let session = ScrollingCaptureSession(selection: selection, axis: .vertical,
                                              activateSelectedWindow: { _ in throw ScrollDriverError.scrollAreaUnavailable })
        var instead = 0, cancelled = 0, finished = 0
        session.onWindowScreenshotInstead = { instead += 1 }
        session.onCancelled = { cancelled += 1 }
        session.onFinished = { _ in finished += 1 }
        await session.scheduleRun().value
        #expect(instead == 1)
        #expect(cancelled == 0 && finished == 0)
        // A second ending is no ending: the session is over.
        session.cancel()
        session.finish()
        #expect(instead == 1 && cancelled == 0 && finished == 0)
    }

    /// Without anyone to take the window's screenshot, giving way is a cancellation.
    @Test @MainActor func aSessionWithNobodyToTakeTheWindowScreenshotCancels() async {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 15, y: 15),
                                              bounds: CGRect(x: 0, y: 0, width: 120, height: 90))
        let session = ScrollingCaptureSession(selection: selection, axis: .vertical,
                                              activateSelectedWindow: { _ in throw ScrollDriverError.eventUnavailable })
        var cancelled = 0
        session.onCancelled = { cancelled += 1 }
        await session.scheduleRun().value
        #expect(cancelled == 1)
    }

    @Test @MainActor func cancellationBeforeScheduledRunDoesNotActivateAnyWindow() async {
        let selection = WindowPickerSelection(windowID: 17, processID: 42,
                                              clickPoint: CGPoint(x: 15, y: 15),
                                              bounds: CGRect(x: 0, y: 0, width: 120, height: 90))
        var activationCount = 0
        let session = ScrollingCaptureSession(selection: selection, axis: .vertical,
                                              activateSelectedWindow: { _ in activationCount += 1 })
        let run = session.scheduleRun()
        session.cancel()
        await run.value
        #expect(activationCount == 0)
    }
}

private actor AsyncLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func park() async {
        await withCheckedContinuation { continuation in
            self.started = true
            self.startContinuation?.resume()
            self.startContinuation = nil
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor EventCounter {
    private(set) var value = 0
    func recordEvent() { value += 1 }
}
