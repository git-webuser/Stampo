import AppKit
import Testing
@testable import Stampo

/// Every colour pick makes a `ColorSampler`, which owns a `CursorOverlay`, which
/// owns a full-screen window. All three must go away when the pick ends. A
/// callback that captures its own sampler strongly keeps the whole chain alive
/// for the rest of the session — one hidden window per pick, found by the E2E
/// window-set check. None of these tests starts a capture, so none needs
/// Screen Recording and none puts a window on screen.
@MainActor
@Suite struct ColorPickerLifetimeTests {

    /// Esc, right-click and a capture error all end in `sampler.cancel()`.
    @Test func aCancelledSamplerIsFreedOnceTheCoordinatorLetsGo() {
        let coordinator = ColorPickingCoordinator()
        weak var weakSampler: ColorSampler?
        do {
            let sampler = ColorSampler()
            weakSampler = sampler
            coordinator.attach(sampler, preferredScreen: nil)
            #expect(coordinator.activeSampler === sampler)

            sampler.cancel()
            #expect(coordinator.activeSampler == nil)
        }
        #expect(weakSampler == nil)
    }

    /// The coordinator can go away mid-pick (the app quits, the panel is torn
    /// down). The callbacks must not be what keeps the sampler alive then.
    @Test func theCallbacksDoNotKeepASamplerAlive() {
        weak var weakSampler: ColorSampler?
        do {
            let coordinator = ColorPickingCoordinator()
            let sampler = ColorSampler()
            weakSampler = sampler
            coordinator.attach(sampler, preferredScreen: nil)
        }
        #expect(weakSampler == nil)
    }

    /// The overlay makes its window lazily and only orders it out on `hide()`,
    /// so the window lives exactly as long as the overlay does.
    @Test func anOverlayTakesItsWindowWithIt() throws {
        let screen = try #require(NSScreen.screens.first)
        let before = cursorWindowCount()
        autoreleasepool {
            let overlay = CursorOverlay()
            overlay.move(to: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
            #expect(cursorWindowCount() == before + 1)
            overlay.hide()
        }
        #expect(cursorWindowCount() == before)
    }

    private func cursorWindowCount() -> Int {
        NSApp.windows.filter { String(describing: type(of: $0)) == "FullscreenCursorWindow" }.count
    }
}
