import AppKit
import SwiftUI

// MARK: - Countdown session

/// Bundles every piece of countdown state into a single value so the
/// controller no longer has to juggle parallel fields (`countdownTimer`,
/// `countdownCaptureTarget`, `countdownScreen`).
struct CountdownSession {
    let target: NotchPanelController.CaptureTarget
    let screen: NSScreen?
    var secondsRemaining: Int
    let totalSeconds: Int
    var timer: Timer?
}

// MARK: - Capture orchestration

extension NotchPanelController {

    // MARK: Countdown

    /// Mirrors the authoritative `activeCountdown` into the view-facing
    /// `rootState` fields so the SwiftUI countdown arc updates without
    /// reading the session struct directly.
    private func syncCountdownToRootState() {
        rootState.countdownSeconds = activeCountdown?.secondsRemaining ?? 0
        rootState.countdownTotal   = activeCountdown?.totalSeconds   ?? 0
    }

    /// Screen mode: panel stays open, crossfade to countdown.
    func startScreenCountdown(seconds: Int) {
        activeCountdown = CountdownSession(
            target: .screen,
            screen: currentScreen,
            secondsRemaining: seconds,
            totalSeconds: seconds,
            timer: nil
        )
        syncCountdownToRootState()
        route = .cdwn
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 1.0
        }
        startCountdownTimer()
    }

    /// Selection/Window mode: hide panel, show pre-selection overlay, then show panel with countdown.
    func launchPreSelection(mode: CaptureMode, seconds: Int) {
        guard !preSelectionInFlight else { return }
        // Fail closed if there's no screen to present the overlay on (headless
        // Mac or mid-reconfiguration). Previously this forced `screens[0]` and
        // crashed on empty screens.
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        preSelectionInFlight = true

        hideAnimated { [weak self] in
            guard let self else { return }
            if mode == .selection {
                self.selectionOverlay.onSelected = { [weak self] rect in
                    guard let self else { return }
                    self.preSelectionInFlight = false
                    self.beginCountdownAfterPreSelection(target: .rect(rect), seconds: seconds, screen: screen)
                }
                self.selectionOverlay.onCancelled = { [weak self] in
                    self?.preSelectionInFlight = false
                }
                self.selectionOverlay.start(on: screen)
            } else {
                // .window
                self.windowPickerOverlay.onSelected = { [weak self] windowID in
                    guard let self else { return }
                    self.preSelectionInFlight = false
                    self.beginCountdownAfterPreSelection(target: .windowID(windowID), seconds: seconds, screen: screen)
                }
                self.windowPickerOverlay.onCancelled = { [weak self] in
                    self?.preSelectionInFlight = false
                }
                self.windowPickerOverlay.start(on: screen)
            }
        }
    }

    /// Called after pre-selection overlay completes: show panel in countdown state directly.
    func beginCountdownAfterPreSelection(target: CaptureTarget, seconds: Int, screen: NSScreen) {
        activeCountdown = CountdownSession(
            target: target,
            screen: screen,
            secondsRemaining: seconds,
            totalSeconds: seconds,
            timer: nil
        )
        syncCountdownToRootState()
        // Set countdown visible instantly before panel appears (no crossfade needed)
        rootState.countdownVisible = 1.0
        route = .cdwn
        showAnimated(on: screen)
        startCountdownTimer()
    }

    func startCountdownTimer() {
        cancelCountdownTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard var session = self.activeCountdown else { return }
            if session.secondsRemaining > 1 {
                session.secondsRemaining -= 1
                self.activeCountdown = session
                self.syncCountdownToRootState()
            } else {
                self.finishCountdown()
            }
        }
        activeCountdown?.timer = timer
    }

    /// Single authoritative place to kill the countdown Timer.
    /// Called from every exit path (stop / capture-now / finish / hideAnimated /
    /// deinit) so the tick closure can never fire into a freed controller.
    func cancelCountdownTimer() {
        activeCountdown?.timer?.invalidate()
        activeCountdown?.timer = nil
    }

    func stopCountdown() {
        cancelCountdownTimer()
        activeCountdown = nil
        route = .main
        withAnimation(.easeOut(duration: 0.16)) {
            rootState.countdownVisible = 0.0
        }
        // Reset arc values only after the fade-out completes,
        // otherwise the arc would jump backwards while still visible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.rootState.countdownSeconds = 0
            self?.rootState.countdownTotal = 0
        }
    }

    func captureNowFromCountdown() {
        cancelCountdownTimer()
        let target = activeCountdown?.target ?? .screen
        let screen = activeCountdown?.screen
        activeCountdown = nil
        hideAnimated { [weak self] in
            guard let self else { return }
            // Safety net: if the window-picker dismissed normally, isCursorHidden
            // is already false and this is a no-op. Guards against any edge case
            // where dismiss() was skipped.
            self.windowPickerOverlay.resetCursorState()
            self.executeCapture(target: target, screen: screen)
        }
    }

    func finishCountdown() {
        cancelCountdownTimer()
        let target = activeCountdown?.target ?? .screen
        let screen = activeCountdown?.screen
        activeCountdown = nil
        hideAnimated { [weak self] in
            guard let self else { return }
            // Same safety net as captureNowFromCountdown — see comment there.
            self.windowPickerOverlay.resetCursorState()
            self.executeCapture(target: target, screen: screen)
        }
    }

    func executeCapture(target: CaptureTarget, screen: NSScreen?) {
        switch target {
        case .screen:
            screenshot.capture(mode: .screen, delaySeconds: 0, preferredScreen: screen)
        case .rect(let cgRect):
            screenshot.captureRect(cgRect, preferredScreen: screen)
        case .windowID(let id):
            screenshot.captureWindowID(id, preferredScreen: screen)
        }
    }
}
