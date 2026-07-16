import AppKit
import Carbon.HIToolbox
import Testing
@testable import Stampo

@Suite struct PinnedWindowGeometryTests {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 950)

    // MARK: initialSize

    @Test func hugeImageClampsToHalfTheScreen() {
        // 5K screenshot on a laptop screen: both raw dimensions exceed the cap.
        let size = PinnedWindowGeometry.initialSize(
            imagePixels: CGSize(width: 5120, height: 2880), visibleFrame: screen)
        #expect(size.width <= screen.width * PinnedWindowGeometry.screenFraction + 0.5)
        #expect(size.height <= screen.height * PinnedWindowGeometry.screenFraction + 0.5)
        #expect(abs(size.width / size.height - 5120.0 / 2880.0) < 0.01)
    }

    @Test func tinyImageIsRaisedToTheMinimumSide() {
        let size = PinnedWindowGeometry.initialSize(
            imagePixels: CGSize(width: 200, height: 150), visibleFrame: screen)
        #expect(min(size.width, size.height) >= PinnedWindowGeometry.minSide - 0.5)
        #expect(abs(size.width / size.height - 200.0 / 150.0) < 0.01)
    }

    @Test func mediumImageUsesTheInitialFraction() {
        let size = PinnedWindowGeometry.initialSize(
            imagePixels: CGSize(width: 1200, height: 900), visibleFrame: screen)
        #expect(abs(size.width - 1200 * PinnedWindowGeometry.initialFraction) < 0.5)
        #expect(abs(size.height - 900 * PinnedWindowGeometry.initialFraction) < 0.5)
    }

    @Test func thinImageScreenClampWinsOverMinimumSide() {
        // 40:1 banner: satisfying the 140 pt floor would need a 5600 pt width,
        // so the screen clamp must win and the short side may drop below it.
        let size = PinnedWindowGeometry.initialSize(
            imagePixels: CGSize(width: 8000, height: 200), visibleFrame: screen)
        #expect(size.width <= screen.width * PinnedWindowGeometry.screenFraction + 0.5)
        #expect(abs(size.width / size.height - 40.0) < 0.1)
    }

    @Test func degenerateInputsFallBackToMinimumSquare() {
        let size = PinnedWindowGeometry.initialSize(
            imagePixels: .zero, visibleFrame: screen)
        #expect(size == CGSize(width: PinnedWindowGeometry.minSide,
                               height: PinnedWindowGeometry.minSide))
    }

    // MARK: origin

    @Test func firstPinAnchorsTopRight() {
        let size = CGSize(width: 400, height: 300)
        let origin = PinnedWindowGeometry.origin(
            size: size, visibleFrame: screen, cascadeIndex: 0)
        #expect(origin.x == screen.maxX - PinnedWindowGeometry.margin - size.width)
        #expect(origin.y == screen.maxY - PinnedWindowGeometry.margin - size.height)
    }

    @Test func cascadeStepsDownLeft() {
        let size = CGSize(width: 400, height: 300)
        let first = PinnedWindowGeometry.origin(
            size: size, visibleFrame: screen, cascadeIndex: 0)
        let third = PinnedWindowGeometry.origin(
            size: size, visibleFrame: screen, cascadeIndex: 2)
        #expect(third.x == first.x - 2 * PinnedWindowGeometry.cascadeOffset)
        #expect(third.y == first.y - 2 * PinnedWindowGeometry.cascadeOffset)
    }

    @Test func cascadeWrapsBackInsideTheScreen() {
        let size = CGSize(width: 700, height: 850)   // tall pin: few steps fit
        for index in 0..<40 {
            let origin = PinnedWindowGeometry.origin(
                size: size, visibleFrame: screen, cascadeIndex: index)
            let frame = CGRect(origin: origin, size: size)
            #expect(screen.contains(frame), "cascade index \(index) left the screen")
        }
    }

    // MARK: minWindowSize

    @Test func normalImageMinSizeUsesTheResizeFloor() {
        let s = PinnedWindowGeometry.minWindowSize(
            imagePixels: CGSize(width: 1200, height: 900), maxContentSize: screen.size)
        #expect(abs(min(s.width, s.height) - PinnedWindowGeometry.minResizeSide) < 0.5)
        #expect(abs(s.width / s.height - 1200.0 / 900.0) < 0.01)
    }

    @Test func extremeAspectMinSizeNeverExceedsMaxContentSize() {
        // 40:1 banner: an aspect-preserving 120 pt floor would demand a
        // 4800 pt minimum width — the max ceiling must win so edge-resize
        // never gets contradictory constraints.
        let maxContent = CGSize(width: 1512, height: 950)
        for pixels in [CGSize(width: 8000, height: 200),    // ultra-wide
                       CGSize(width: 200, height: 8000)] {  // ultra-tall
            let s = PinnedWindowGeometry.minWindowSize(
                imagePixels: pixels, maxContentSize: maxContent)
            #expect(s.width <= maxContent.width + 0.5)
            #expect(s.height <= maxContent.height + 0.5)
            #expect(abs(s.width / s.height - pixels.width / pixels.height) < 0.01)
        }
    }

    // MARK: clampedFrame

    @Test func oversizedFrameIsShrunkAndShiftedInside() {
        let frame = CGRect(x: -100, y: 900, width: 2000, height: 1200)
        let clamped = PinnedWindowGeometry.clampedFrame(frame, to: screen)
        #expect(screen.contains(clamped))
    }

    @Test func fittingFrameIsUntouched() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(PinnedWindowGeometry.clampedFrame(frame, to: screen) == frame)
    }
}

@Suite struct PinLastCaptureHotkeyTests {

    @Test func pinDefaultComboIsCtrlOptCmdP() {
        let combo = HotkeyAction.pinLastCapture.defaultCombo
        #expect(combo.keyCode == UInt16(kVK_ANSI_P))
        #expect(combo.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(combo.displayString == "⌃⌥⌘P")
    }

    @Test func pinCarbonIDIsEightAndUnique() {
        #expect(HotkeyAction.pinLastCapture.rawValue == 8)
        let ids = HotkeyAction.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
    }

    @Test func pinDefaultComboDoesNotCollide() {
        let combos = HotkeyAction.allCases.map(\.defaultCombo)
        #expect(Set(combos).count == combos.count)
        let result = HotkeyValidator.validate(
            HotkeyAction.pinLastCapture.defaultCombo, for: .pinLastCapture)
        #expect(result != .systemReserved)
        #expect(result != .noStrongModifier)
    }

    @Test func pinRowMetadataIsFilledIn() {
        #expect(HotkeyAction.pinLastCapture.labelKey == "Pin Last Screenshot")
        #expect(HotkeyAction.pinLastCapture.icon == "pin")
    }
}

// Hosted tests run inside Stampo.app, so touching AppKit windows on the main
// actor is allowed (same arrangement as PanelStateTests).
@MainActor
@Suite struct PinnedScreenshotControllerTests {

    /// Renders a small opaque PNG on disk for the controller to pin.
    private func makeTemporaryImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-test-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        return url
    }

    @Test func pinAndCloseMaintainTheRegistry() throws {
        let controller = PinnedScreenshotController.shared
        controller.closeAll()
        defer { controller.closeAll() }

        let url = try makeTemporaryImage()
        defer { try? FileManager.default.removeItem(at: url) }

        controller.pin(url: url)
        #expect(controller.count == 1)
        controller.pin(url: url)   // duplicates allowed by design
        #expect(controller.count == 2)

        controller.closeAll()
        #expect(controller.count == 0)
    }

    @Test func cascadeNeverReusesAnOccupiedSlot() throws {
        // pin A, pin B, close A, pin C: with a pins.count-based cascade C
        // would land exactly on top of B; the monotonic index must not.
        let controller = PinnedScreenshotController.shared
        controller.closeAll()
        defer { controller.closeAll() }

        let url = try makeTemporaryImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = try #require(controller.pin(url: url))
        controller.pin(url: url)
        controller.close(id: a)
        controller.pin(url: url)

        let frames = controller.windowFrames
        #expect(frames.count == 2)
        #expect(frames[0].origin != frames[1].origin)
    }

    @Test func cascadeResetsOnceAllPinsAreClosed() throws {
        let controller = PinnedScreenshotController.shared
        controller.closeAll()
        defer { controller.closeAll() }

        let url = try makeTemporaryImage()
        defer { try? FileManager.default.removeItem(at: url) }

        controller.pin(url: url)
        let firstOrigin = controller.windowFrames[0].origin
        controller.closeAll()

        controller.pin(url: url)
        #expect(controller.windowFrames[0].origin == firstOrigin)
    }

    @Test func hotkeyPinDebouncesHeldShortcutButAllowsQuietRepeatAndOtherURLs() throws {
        // Carbon fires repeated hot-key events while ⌃⌥⌘P is held; back-to-back
        // events must keep extending the debounce window so a long hold still
        // creates one pin. A quiet pause or a different capture pins again.
        let controller = PinnedScreenshotController.shared
        controller.closeAll()
        defer { controller.closeAll() }

        let first = try makeTemporaryImage()
        let second = try makeTemporaryImage()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        controller.pinLastCapture(url: first, on: nil, eventTime: 100.0)
        controller.pinLastCapture(url: first, on: nil, eventTime: 100.4)
        controller.pinLastCapture(url: first, on: nil, eventTime: 100.9)
        #expect(controller.count == 1)

        controller.pinLastCapture(url: first, on: nil, eventTime: 101.8)
        #expect(controller.count == 2)

        controller.pinLastCapture(url: second, on: nil, eventTime: 101.9)
        #expect(controller.count == 3)
    }

    @Test func pinningAMissingFileStillCreatesAWindow() {
        // pin(url:) itself does not gate on existence (the geometry falls back
        // to a default size); only the hotkey path checks the file. It must
        // simply not crash.
        let controller = PinnedScreenshotController.shared
        controller.closeAll()
        defer { controller.closeAll() }

        let ghost = URL(fileURLWithPath: "/nonexistent/pin-test-ghost.png")
        controller.pin(url: ghost)
        #expect(controller.count == 1)
    }
}
