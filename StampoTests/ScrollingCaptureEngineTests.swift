import AppKit
import CoreGraphics
import Foundation
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
            "Done",
            HotkeyAction.scroll.labelKey, HotkeyAction.scroll.hintKey ?? "",
            "Scrolling", "Scroll direction", "Down", "Right",
            "Scrolling capture failed",
            "Scrolling capture needs Accessibility access",
            "Grant Accessibility access to Stampo to scroll windows.",
            "Stampo couldn't complete scrolling capture. Try again.",
            "Stampo couldn't encode the scrolling image.",
            "The window is covered at the scroll point.",
            "The window size changed.",
            "The display scale changed.",
            "The window moved to the background.",
            "Frames couldn't be aligned.",
            "The area doesn't scroll. Click inside the page or table and start again.",
            "There's no scrollable area at that point. Click inside the page or table and try again.",
            "The content is too uniform to align. The capture stopped to avoid a broken image.",
            "The content moved sideways. Don't move the window during the capture.",
            "macOS couldn't scroll the window.",
        ]
        for key in keys {
            let translated = LocaleManager.string(key, locale: ru)
            #expect(translated != key, "no Russian for \(key)")
        }
    }

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
        #expect(ScrollDirection.down.icon == "arrow.down.to.line")
        #expect(ScrollDirection.right.icon == "arrow.right.to.line")
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

    @Test func theStripShowsARingWhileWorkingAndSavingAndAWarningWhenPaused() {
        #expect(ScrollStripPhase(.capturing) == .running)
        #expect(ScrollStripPhase(.saving) == .running)
        #expect(ScrollStripPhase(.paused(reason: "The window size changed.")) == .paused)
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
