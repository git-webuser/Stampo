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

    // MARK: hover plate

    private let band = PinnedWindowGeometry.plateBand

    /// The plate is there at rest too, standing the pin off its background now
    /// that the window has no shadow — so hovering only adds the difference.
    @Test func hoverAddsOnlyWhatTheRestingPlateDoesNot() {
        #expect(PinnedWindowGeometry.restingBand > 0)
        #expect(PinnedWindowGeometry.restingBand < PinnedWindowGeometry.plateBand)
        #expect(PinnedWindowGeometry.hoverGrowth
                == PinnedWindowGeometry.plateBand - PinnedWindowGeometry.restingBand)

        // Resting window → hovered window → back: the picture ends where it
        // started, and is one full band inside the plate while hovered.
        let picture = CGRect(x: 300, y: 400, width: 480, height: 300)
        let resting = PinnedWindowGeometry.plated(picture, band: PinnedWindowGeometry.restingBand)
        let hovered = PinnedWindowGeometry.plated(resting, band: PinnedWindowGeometry.hoverGrowth)
        #expect(PinnedWindowGeometry.unplated(hovered, band: band) == picture)
        #expect(PinnedWindowGeometry.unplated(hovered, band: PinnedWindowGeometry.hoverGrowth)
                == resting)
    }

    /// The whole point of growing the window: the image must not move or
    /// change size when the plate appears under the pointer.
    @Test func platingGrowsAroundTheImageAndUndoesExactly() {
        let image = CGRect(x: 300, y: 400, width: 480, height: 300)
        let plated = PinnedWindowGeometry.plated(image, band: band)
        #expect(plated.width == image.width + 2 * band)
        #expect(plated.height == image.height + 2 * band)
        #expect(plated.midX == image.midX)
        #expect(plated.midY == image.midY)
        #expect(PinnedWindowGeometry.unplated(plated, band: band) == image)
    }

    /// A pin parked half off the screen must not be yanked back by a plate: the
    /// picture stays where the user put it, the window just grows past the edge.
    @Test func platingNeverPullsAPinBackOntoTheScreen() {
        let image = CGRect(x: screen.maxX - 60, y: 400, width: 400, height: 260)
        let plated = PinnedWindowGeometry.plated(image, band: band)
        #expect(plated.midX == image.midX)
        #expect(plated.midY == image.midY)
        #expect(PinnedWindowGeometry.unplated(plated, band: band) == image)
    }

    // MARK: plate zones

    @Test func plateCornersResizeAndEverythingElseMoves() {
        let size = CGSize(width: 400, height: 300)
        let reach = PinnedWindowGeometry.cornerReach
        // Corners, in the bottom-left origin the geometry works in.
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 3, y: 3), in: size) == .bottomLeft)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 397, y: 3), in: size) == .bottomRight)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 3, y: 297), in: size) == .topLeft)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 397, y: 297), in: size) == .topRight)
        // The straight run of plate between two corners moves the window.
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 200, y: 3), in: size) == .body)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 3, y: 150), in: size) == .body)
        // A corner's reach ends where it says it does.
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: reach + 5, y: 3), in: size) == .body)
        // Inside the image, past the plate: the picture drags the window.
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 200, y: 150), in: size) == .body)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 20, y: 20), in: size) == .body)
    }

    /// A pin of a very narrow image is the case the plate exists for: the
    /// image is a sliver, but the plate around it still has real corners.
    @Test func narrowPinStillHasGrabbableCorners() {
        let size = CGSize(width: 600, height: 2 * PinnedWindowGeometry.plateBand + 14)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 2, y: 2), in: size) == .bottomLeft)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 598, y: size.height - 2), in: size) == .topRight)
        #expect(PinnedWindowGeometry.zone(at: CGPoint(x: 300, y: size.height / 2), in: size) == .body)
    }

    // MARK: plate resize

    /// Dragging a corner outward: the image keeps its aspect and the corner
    /// across from the dragged one does not move. A pull along one axis alone
    /// cannot be honoured exactly — no aspect-true size has that corner — so
    /// the size grows towards it without overshooting it.
    @Test func draggingACornerKeepsTheAspectAndTheOppositeCorner() {
        let frame = CGRect(x: 200, y: 200, width: 400 + 2 * band, height: 250 + 2 * band)
        let resized = PinnedWindowGeometry.resized(
            frame, corner: .topRight, translation: CGSize(width: 100, height: 0),
            imageAspect: 400.0 / 250.0, band: band,
            minImageSize: CGSize(width: 120, height: 75),
            maxImageSize: CGSize(width: 1400, height: 875))

        #expect(resized.minX == frame.minX)          // anchored bottom-left
        #expect(resized.minY == frame.minY)
        let image = PinnedWindowGeometry.unplated(resized, band: band)
        #expect(image.width > 400)
        #expect(image.width <= 500)
        #expect(abs(image.width / image.height - 400.0 / 250.0) < 0.001)
    }

    /// A drag along the image's own diagonal is the one the pointer can be
    /// honoured on exactly, and it must be: that is the gesture someone makes
    /// when they want the corner to end up under their cursor.
    @Test func aDragAlongTheDiagonalFollowsThePointerExactly() {
        let aspect = 400.0 / 250.0
        let frame = CGRect(x: 200, y: 200, width: 400 + 2 * band, height: 250 + 2 * band)
        for pull in [CGFloat(40), 120, -80] {
            let resized = PinnedWindowGeometry.resized(
                frame, corner: .topRight,
                translation: CGSize(width: pull * aspect, height: pull),
                imageAspect: aspect, band: band,
                minImageSize: CGSize(width: 120, height: 75),
                maxImageSize: CGSize(width: 1400, height: 875))
            let image = PinnedWindowGeometry.unplated(resized, band: band)
            #expect(abs(image.height - (250 + pull)) < 0.001, "pull \(pull)")
            #expect(abs(image.width - (400 + pull * aspect)) < 0.001, "pull \(pull)")
        }
    }

    @Test func draggingTheBottomLeftAnchorsTheTopRight() {
        let frame = CGRect(x: 200, y: 200, width: 400 + 2 * band, height: 250 + 2 * band)
        let resized = PinnedWindowGeometry.resized(
            frame, corner: .bottomLeft, translation: CGSize(width: -100, height: 0),
            imageAspect: 400.0 / 250.0, band: band,
            minImageSize: CGSize(width: 120, height: 75),
            maxImageSize: CGSize(width: 1400, height: 875))

        #expect(abs(resized.maxX - frame.maxX) < 0.001)
        #expect(abs(resized.maxY - frame.maxY) < 0.001)
        #expect(resized.width > frame.width)
    }

    @Test func resizeStopsAtTheFloorAndTheCeiling() {
        let frame = CGRect(x: 200, y: 200, width: 400 + 2 * band, height: 250 + 2 * band)
        let aspect = 400.0 / 250.0
        let minImage = CGSize(width: 120, height: 75)
        let maxImage = CGSize(width: 800, height: 500)

        let shrunk = PinnedWindowGeometry.resized(
            frame, corner: .topRight, translation: CGSize(width: -5000, height: 0),
            imageAspect: aspect, band: band, minImageSize: minImage, maxImageSize: maxImage)
        let smallImage = PinnedWindowGeometry.unplated(shrunk, band: band)
        #expect(abs(smallImage.width - minImage.width) < 0.5)
        #expect(abs(smallImage.width / smallImage.height - aspect) < 0.001)

        let grown = PinnedWindowGeometry.resized(
            frame, corner: .topRight, translation: CGSize(width: 5000, height: 0),
            imageAspect: aspect, band: band, minImageSize: minImage, maxImageSize: maxImage)
        let bigImage = PinnedWindowGeometry.unplated(grown, band: band)
        #expect(abs(bigImage.width - maxImage.width) < 0.5)
        #expect(abs(bigImage.width / bigImage.height - aspect) < 0.001)
    }

    /// The plate keeps its width on every side while the image is resized —
    /// so the aspect is the image's, never the window's.
    @Test func theBandSurvivesAResize() {
        let frame = CGRect(x: 200, y: 200, width: 400 + 2 * band, height: 250 + 2 * band)
        let resized = PinnedWindowGeometry.resized(
            frame, corner: .bottomRight, translation: CGSize(width: 60, height: -40),
            imageAspect: 400.0 / 250.0, band: band,
            minImageSize: CGSize(width: 120, height: 75),
            maxImageSize: CGSize(width: 1400, height: 875))
        let image = PinnedWindowGeometry.unplated(resized, band: band)
        #expect(abs(resized.width - image.width - 2 * band) < 0.001)
        #expect(abs(resized.height - image.height - 2 * band) < 0.001)
    }

    /// A hand dragging a corner diagonally wobbles by a point or two either
    /// side of the diagonal. The size must follow that smoothly: if the rule
    /// switches which axis it reads as the wobble crosses, the window jumps
    /// between two sizes on every tremor and the picture shakes in steps.
    @Test func aWobblingDiagonalDragDoesNotShakeTheSize() {
        let frame = CGRect(x: 200, y: 200, width: 400 + 2 * band, height: 250 + 2 * band)
        let aspect = 400.0 / 250.0

        var previous: CGFloat = 0
        for step in 0...60 {
            // Straight out along the diagonal, plus a tremor across it.
            let along = CGFloat(step) * 4
            let tremor = CGFloat(step % 2 == 0 ? 3 : -3)
            let resized = PinnedWindowGeometry.resized(
                frame, corner: .topRight,
                translation: CGSize(width: along + tremor, height: along - tremor),
                imageAspect: aspect, band: band,
                minImageSize: CGSize(width: 120, height: 75),
                maxImageSize: CGSize(width: 4000, height: 2500))
            let width = PinnedWindowGeometry.unplated(resized, band: band).width

            // Each step moves outward, so no size is smaller than the last —
            // and none is a leap the tremor cannot account for. Not strictly
            // bigger: sizes are whole points, and a small step can round to
            // the same one twice.
            #expect(width >= previous, "step \(step) went backwards: \(previous) → \(width)")
            #expect(width == width.rounded(), "step \(step) landed on a fraction: \(width)")
            if step > 0 {
                #expect(width - previous < 20,
                        "step \(step) jumped \(width - previous) pt on a 4 pt move")
            }
            previous = width
        }
    }

    @Test func bodyZoneIsNeverAResize() {
        let frame = CGRect(x: 200, y: 200, width: 420, height: 270)
        #expect(PinnedWindowGeometry.resized(
            frame, corner: .body, translation: CGSize(width: 100, height: 100),
            imageAspect: 1.6, band: band,
            minImageSize: CGSize(width: 120, height: 75),
            maxImageSize: CGSize(width: 1400, height: 875)) == frame)
    }
}

@Suite struct PinLastCaptureHotkeyTests {

    /// L for "latest". P moved to the panel pin, which is what the word means
    /// everywhere else in the app, and T was freed for Translate.
    @Test func pinDefaultComboIsCtrlOptCmdL() {
        let combo = HotkeyAction.pinLastCapture.defaultCombo
        #expect(combo.keyCode == UInt16(kVK_ANSI_L))
        #expect(combo.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        #expect(combo.displayString == "⌃⌥⌘L")
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
        #expect(HotkeyAction.pinLastCapture.labelKey == "Pin Latest Capture")
        // Not a pin: bare `pin` is the panel throughout the app, and two pins
        // a row apart in the settings list were the same glyph to the eye.
        #expect(HotkeyAction.pinLastCapture.icon == "inset.filled.topright.rectangle")
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
